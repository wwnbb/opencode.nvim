local M = {}

local NuiLine = require("nui.line")

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")
local render_state = require("opencode.ui.chat.render_state")
local widget_support = require("opencode.ui.chat.widget_support")
local sync = require("opencode.sync")

local Context = {}
Context.__index = Context

function M.new(opts)
	opts = opts or {}
	local metadata_provider_revision = sync.get_provider_revision()
	local metadata_agent_revision = sync.get_agent_revision()
	local content_highlights = {}
	content_highlights._opencode_signature = render_state.render_cache_key(
		"metadata",
		metadata_provider_revision,
		metadata_agent_revision
	)

	return setmetatable({
		current_session = opts.current_session or {},
		in_child_session_view = opts.in_child_session_view == true,
		chat_config = opts.chat_config or {},
		raw_lines = {},
		nui_lines = {},
		content_highlights = content_highlights,
		last_block_kind = nil,
		chat_width = render.get_chat_text_width(),
		metadata_provider_revision = metadata_provider_revision,
		metadata_agent_revision = metadata_agent_revision,
		next_stream_blocks = {},
		message_render_parts_cache = {},
	}, Context)
end

function Context:render_cache_key(...)
	return render_state.render_cache_key(...)
end

function Context:cached_nui_lines(key, build)
	local cached = key and render_state.render_cache_get(key)
	if cached and cached.nui_lines then
		return cached.nui_lines
	end
	local lines = build()
	if key then
		render_state.render_cache_put(key, { nui_lines = lines })
	end
	return lines
end

function Context:cached_render_result(key, build)
	local cached = key and render_state.render_cache_get(key)
	if cached and cached.result then
		return cached.result
	end
	local result = build()
	if key then
		render_state.render_cache_put(key, { result = result })
	end
	return result
end

function Context:cached_nui_line(key, build)
	local lines = self:cached_nui_lines(key, function()
		return { build() }
	end)
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
	table.insert(self.nui_lines, nui_line)
	table.insert(self.raw_lines, text)
end

function Context:ensure_single_blank_separator()
	while #self.raw_lines > 0 and self.raw_lines[#self.raw_lines] == "" do
		table.remove(self.raw_lines)
		table.remove(self.nui_lines)
	end
	local line = NuiLine()
	line:append("")
	self:push_line("", line)
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

function Context:add_line(nui_line, kind)
	local text = nui_line:content()
	local line_kind = kind or (text == "" and "blank" or "non_tool")
	self:normalize_block_transition(line_kind)
	self:push_line(text, nui_line)
end

function Context:add_raw_line(text, kind)
	local line = NuiLine()
	line:append(text)
	local line_kind = kind or (text == "" and "blank" or "non_tool")
	self:normalize_block_transition(line_kind)
	self:push_line(text, line)
end

function Context:append_relative_highlights(highlights, base_line)
	if type(highlights) ~= "table" or type(base_line) ~= "number" then
		return
	end
	for _, hl in ipairs(highlights) do
		if type(hl) == "table" then
			table.insert(self.content_highlights, vim.tbl_extend("force", {}, hl, {
				line = base_line + (hl.line or 0),
				end_line = hl.end_line and (base_line + hl.end_line) or nil,
			}))
		end
	end
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

function Context:prepare_widget_start()
	self:normalize_block_transition("non_tool")
	return #self.raw_lines
end

function Context:add_render_result(result, kind)
	self:normalize_block_transition(kind)
	local base_line = #self.raw_lines
	for _, text in ipairs(result.lines or {}) do
		local nl = NuiLine()
		nl:append(text)
		self:push_line(text, nl)
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
		chat_width = self.chat_width,
		text_length = #(part.text or ""),
	})
end

function Context:set_spinner_footer_line(line)
	state.spinner_footer_line = line
end

function Context:line_count()
	return #self.raw_lines
end

function Context:reset_tracking()
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.message_positions = {}
	state.tasks = {}
	state.tools = {}
	state.spinner_footer_line = nil
end

function Context:commit_stream_blocks()
	state.stream_blocks = self.next_stream_blocks
	local count = 0
	for _ in pairs(self.next_stream_blocks) do
		count = count + 1
	end
	return count
end

return M
