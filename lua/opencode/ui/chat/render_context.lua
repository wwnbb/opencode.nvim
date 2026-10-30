local cs = require("opencode.ui.chat.state")
return cs.factory("render_context", function(view)
local M = {}

local NuiLine = require("nui.line")

local state = view
local render = cs.module(view, require("opencode.ui.chat.render"))
local render_state = cs.module(view, require("opencode.ui.chat.render_state"))
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local render_blocks = require("opencode.ui.chat.render_blocks")
local sync = require("opencode.sync")
local app_state = require("opencode.state")
local syntax = require("opencode.ui.syntax")

local Context = {}
Context.__index = Context

function M.new(opts)
	opts = opts or {}
	local metadata_provider_revision = sync.get_provider_revision()
	local metadata_agent_revision = sync.get_agent_revision()

	return setmetatable({
		view = view,
		current_session = opts.current_session or cs.session(view),
		in_child_session_view = opts.in_child_session_view == true,
		chat_config = opts.chat_config or {},
		raw_lines = {},
		nui_lines = {},
		content_highlights = {},
		last_block_kind = nil,
		last_tool_name = nil,
		chat_width = render.get_chat_text_width(),
		metadata_provider_revision = metadata_provider_revision,
		metadata_agent_revision = metadata_agent_revision,
		syntax_generation = syntax.get_cache_generation(),
		-- Read once per frame; renderers that depend on it take it from here
		-- and put it in their cache keys.
		verbosity = ((app_state.read_config() or {}).session or {}).verbosity or "",
		config_generation = app_state.get_config_generation(),
		next_stream_blocks = {},
		message_render_parts_cache = {},
		-- Session chrome and any separator above the first keyed block.
		blocks = { { key = "head", kind = "head", start = 0, highlight_start = 1 } },
	}, Context)
end

function Context:code_highlighter(message_id, part_id)
	return render_state.code_highlighter(render_state.render_cache_key(self.current_session.id, message_id, part_id or "user"))
end

function Context:render_cache_key(...)
	return render_state.render_cache_key(...)
end

-- Owner shape is fixed and independent of revisions. Avoid a second temporary
-- vararg array for every cached block in an otherwise warm transcript.
function Context:render_owner_key(kind, message_id, part_id)
	return tostring(kind or "") .. "\0" .. tostring(self.current_session.id or "")
		.. "\0" .. tostring(message_id or "") .. "\0" .. tostring(part_id or "")
end

local function cached_value(self, key, build, owner, field)
	local cached = render_state.render_cache_get(key, owner)
	if cached and cached[field] and cached.syntax_generation == self.syntax_generation
		and cached.config_generation == self.config_generation then
		return cached[field]
	end
	if cached then render_state.render_cache_delete(owner or key) end
	local result = build()
	if key and not result._opencode_syntax_retry then
		render_state.render_cache_put(key, { [field] = result, syntax_generation = self.syntax_generation,
			config_generation = self.config_generation }, owner)
	end
	return result
end

function Context:cached_nui_lines(key, build, owner)
	return cached_value(self, key, build, owner, "nui_lines")
end

function Context:cached_render_result(key, build, owner)
	return cached_value(self, key, build, owner, "result")
end

function Context:cached_nui_line(key, build, owner)
	local lines = self:cached_nui_lines(key, function()
		return { build() }
	end, owner)
	return lines[1]
end

function Context:get_message_render_parts(message_id, opts)
	local cache_key = tostring(message_id or "") .. "\0"
		.. ((type(opts) == "table" and opts.include_synthetic == false) and "no_synthetic" or "default")
	local cached = self.message_render_parts_cache[cache_key]
	if cached then
		return cached
	end
	local result = sync.get_message_render_parts(message_id, opts)
	self.message_render_parts_cache[cache_key] = result
	return result
end

function Context:push_line(text, nui_line)
	local safe_text = render.sanitize_buffer_line(text)
	if safe_text ~= text then
		nui_line = NuiLine()
		nui_line:append(safe_text)
		text = safe_text
	end
	local count = #self.raw_lines + 1
	self.nui_lines[count] = nui_line
	self.raw_lines[count] = text
end

-- Frame lines are never mutated once pushed, so plain-text rows are shared
-- (across frames too, like cached NuiLines; marks are written without ids).
local plain_lines = setmetatable({}, { __mode = "v" })
local function plain_line(text)
	local line = plain_lines[text]
	if not line then
		line = NuiLine()
		line:append(text)
		plain_lines[text] = line
	end
	return line
end

local separator_line = NuiLine()
separator_line:append("")
-- Marks the row as a separator owned by the block above (see commit_stream_blocks).
separator_line._opencode_separator = true

function Context:ensure_single_blank_separator()
	local old_count = #self.raw_lines
	while #self.raw_lines > 0 and self.raw_lines[#self.raw_lines] == ""
		and not self.nui_lines[#self.nui_lines]._opencode_preserve_blank do
		table.remove(self.raw_lines)
		table.remove(self.nui_lines)
	end
	if #self.raw_lines ~= old_count then render_blocks.truncate(self.blocks, #self.raw_lines) end
	self:push_line("", separator_line)
	render_blocks.separator_pushed(self.blocks, #self.raw_lines)
end

function Context:normalize_block_transition(next_kind)
	if not next_kind or next_kind == "blank" then
		return
	end
	if self.last_block_kind and self.last_block_kind ~= next_kind then
		self:ensure_single_blank_separator()
	end
	self.last_block_kind = next_kind
end

-- NuiLine:content() without its per-call closure and tbl_map.
local function line_content(nui_line)
	local texts = nui_line._texts
	local count = #texts
	if count == 1 then return texts[1]:content() or "" end
	local parts = {}
	for i = 1, count do parts[i] = texts[i]:content() end
	return table.concat(parts)
end

function Context:add_line(nui_line, kind)
	local text = line_content(nui_line)
	local line_kind = kind or (text == "" and "blank" or "non_tool")
	self:normalize_block_transition(line_kind)
	self:push_line(text, nui_line)
end

function Context:add_raw_line(text, kind)
	local line = plain_line(text)
	local line_kind = kind or (text == "" and "blank" or "non_tool")
	self:normalize_block_transition(line_kind)
	self:push_line(text, line)
end

-- Shifted copies of a cached (immutable) highlight list, reused while the
-- list sits at the same base line, as it does in most frames.
local shifted_highlights = setmetatable({}, { __mode = "k" })

function Context:append_relative_highlights(highlights, base_line)
	if type(highlights) ~= "table" or type(base_line) ~= "number" then
		return
	end
	local out = self.content_highlights
	local memo = shifted_highlights[highlights]
	if not (memo and memo.base == base_line and memo.count == #highlights) then
		local copies = {}
		for _, hl in ipairs(highlights) do
			if type(hl) == "table" then
				local copy = {}
				for k, v in pairs(hl) do copy[k] = v end
				copy.line = base_line + (hl.line or 0)
				copy.end_line = hl.end_line and (base_line + hl.end_line) or nil
				copies[#copies + 1] = copy
			end
		end
		memo = { base = base_line, count = #highlights, copies = copies }
		shifted_highlights[highlights] = memo
	end
	local count = #out
	for i, copy in ipairs(memo.copies) do out[count + i] = copy end
end

function Context:add_nui_lines(lines, kind)
	local base_line = nil
	for _, nl in ipairs(lines) do
		self:add_line(nl, kind)
		if base_line == nil then
			base_line = #self.raw_lines - 1
		end
	end
	self:append_relative_highlights(lines._opencode_highlights, base_line)
end

---@param index integer 0-based line
---@return string|nil
function Context:line_text(index)
	return self.raw_lines[index + 1]
end

---Remove a trailing blank separator, so lines attached to the block above go
---before it; the caller adds the separator back after them.
---@return boolean removed
function Context:take_trailing_blank()
	local count = #self.raw_lines
	if count == 0 or self.raw_lines[count] ~= "" or self.nui_lines[count]._opencode_preserve_blank then
		return false
	end
	table.remove(self.raw_lines)
	table.remove(self.nui_lines)
	render_blocks.truncate(self.blocks, #self.raw_lines)
	return true
end

function Context:prepare_widget_start()
	if #self.raw_lines > 0 then self:ensure_single_blank_separator() end
	self.last_block_kind = "non_tool"
	return #self.raw_lines
end

function Context:add_render_result(result, kind)
	if #(result.lines or {}) > 0 then self:normalize_block_transition(kind) end
	local base_line = #self.raw_lines
	for _, text in ipairs(result.lines or {}) do
		self:push_line(text, plain_line(text))
	end
	return base_line
end

function Context:register_stream_block(message_id, part, kind, start_line)
	local session_id = self.current_session and self.current_session.id
	local part_id = part and part.id
	local block_key = render_state.stream_block_key(session_id, message_id, part_id, kind)
	if not block_key then
		return
	end
	self.next_stream_blocks[block_key] = widget_support.mark_render_generation({
		start_line = start_line,
		end_line = #self.raw_lines - 1,
		session_id = session_id,
		message_id = message_id,
		part_id = part_id,
		kind = kind,
	})
end

---Start the next keyed block at the current end of the frame.
---@param kind string
---@param id any
---@param signature string|nil Render-cache key that determines the block's content
function Context:begin_block(kind, id, signature)
	render_blocks.begin(self.blocks, kind, id, signature, #self.raw_lines, #self.content_highlights)
end

---The current block gained lines its signature does not describe.
function Context:unsign_block()
	self.blocks[#self.blocks].signature = nil
end

---Sign the current block once its content is known to follow from a cache key.
---@param signature string
function Context:sign_block(signature)
	self.blocks[#self.blocks].signature = signature
end

---@return OpenCodeRenderBlock[]
function Context:finish_blocks()
	local blocks = render_blocks.finish(self.blocks, #self.raw_lines, #self.content_highlights)
	blocks.syntax_generation = self.syntax_generation
	blocks.config_generation = self.config_generation
	return blocks
end

function Context:set_spinner_footer_line(line)
	state.spinner_footer = { start_line = line, end_line = line }
end

function Context:line_count()
	return #self.raw_lines
end

function Context:reset_tracking()
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.message_positions = {}
	state.pending_inputs = {}
	state.tasks = {}
	state.tools = {}
	state.spinner_footer = nil
end

---Streaming text ranges cover their part's content and, when the text block
---ends with a separator, that separator: replacing a part that ends in a
---newline would otherwise duplicate the row on every delta.
---@param blocks OpenCodeRenderBlock[] The finished frame's blocks
function Context:commit_stream_blocks(blocks)
	state.stream_blocks = self.next_stream_blocks
	if next(self.next_stream_blocks) == nil then return end
	local by_key = {}
	for _, block in ipairs(blocks) do by_key[block.key] = block end
	for _, pos in pairs(self.next_stream_blocks) do
		local block = by_key[render_blocks.key("text", pos.part_id)]
		local last = block and self.nui_lines[block.finish]
		if last and last._opencode_separator then
			pos.end_line = block.finish - 1
			pos.separator = true
		end
	end
end

return M

end)
