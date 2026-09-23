local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

local RENDER_CACHE_MAX_BLOCKS = 1000
local TASK_SUMMARY_CACHE_MAX_ENTRIES = 100
local CODE_CACHE_MAX_ENTRIES = 128
local CODE_CACHE_MAX_BYTES = 8 * 1024 * 1024
local code_cache = { entries = {}, order = {}, bytes = 0 }

function M.clear_code_cache()
	code_cache = { entries = {}, order = {}, bytes = 0 }
end

function M.code_cache_stats()
	return { entries = #code_cache.order, bytes = code_cache.bytes,
		max_entries = CODE_CACHE_MAX_ENTRIES, max_bytes = CODE_CACHE_MAX_BYTES }
end

---Cache source coordinates, not width-dependent layout. A growing block
---replaces its entry instead of retaining every streamed revision.
function M.code_highlighter(owner)
	local syntax = require("opencode.ui.syntax")
	local config_signature = vim.inspect(syntax.get_config()) .. ":" .. syntax.get_generation()
	return function(text, lang, opts, block)
		local key = M.render_cache_key(owner, block.open_line, lang)
		local signature = M.render_cache_key(config_signature, opts.scope, opts.min_bytes, opts.max_bytes, opts.max_lines)
		local entry = code_cache.entries[key]
		if entry and entry.text == text and entry.signature == signature then
			return entry.highlights
		end
		local captures = syntax.highlight_text(text, lang, opts)
		if entry then
			code_cache.bytes = code_cache.bytes - entry.bytes
			code_cache.entries[key] = nil
			for index, cached_key in ipairs(code_cache.order) do
				if cached_key == key then table.remove(code_cache.order, index); break end
			end
		end
		-- Do not permanently cache missing parsers, queries or parse failures.
		if #captures == 0 then return captures end
		-- Conservative accounting includes table storage and capture strings.
		local bytes = 512 + #key + #signature + #text
		for _, capture in ipairs(captures) do bytes = bytes + 384 + #(capture.hl_group or "") end
		if bytes > CODE_CACHE_MAX_BYTES then return captures end
		while #code_cache.order >= CODE_CACHE_MAX_ENTRIES or code_cache.bytes + bytes > CODE_CACHE_MAX_BYTES do
			local oldest = table.remove(code_cache.order, 1)
			code_cache.bytes = code_cache.bytes - code_cache.entries[oldest].bytes
			code_cache.entries[oldest] = nil
		end
		code_cache.entries[key] = { text = text, signature = signature, highlights = captures, bytes = bytes }
		code_cache.order[#code_cache.order + 1] = key
		code_cache.bytes = code_cache.bytes + bytes
		return captures
	end
end

function M.ensure_render_cache()
	if type(state.render_cache) ~= "table" then
		state.render_cache = { blocks = {}, order = {} }
	end
	state.render_cache.blocks = state.render_cache.blocks or {}
	state.render_cache.order = state.render_cache.order or {}
	return state.render_cache
end

function M.clear_render_cache()
	state.render_cache = { blocks = {}, order = {} }
	state.last_render_highlight_signature = nil
end

local function ensure_task_summary_cache()
	if type(state.task_summary_cache) ~= "table" then
		state.task_summary_cache = { entries = {}, order = {} }
	end
	state.task_summary_cache.entries = state.task_summary_cache.entries or {}
	state.task_summary_cache.order = state.task_summary_cache.order or {}
	return state.task_summary_cache
end

---@param child_session_id string
---@param revision number
---@return table|nil summary
---@return string|nil prompt
---@return boolean found
function M.task_summary_cache_get(child_session_id, revision)
	local entry = ensure_task_summary_cache().entries[child_session_id]
	if entry and entry.revision == revision then
		return entry.summary, entry.prompt, true
	end
	return nil, nil, false
end

---@param child_session_id string
---@param revision number
---@param summary table
---@param prompt string|nil
function M.task_summary_cache_put(child_session_id, revision, summary, prompt)
	local cache = ensure_task_summary_cache()
	if cache.entries[child_session_id] == nil then
		table.insert(cache.order, child_session_id)
	end
	cache.entries[child_session_id] = {
		revision = revision,
		summary = summary,
		prompt = prompt,
	}
	while #cache.order > TASK_SUMMARY_CACHE_MAX_ENTRIES do
		local oldest = table.remove(cache.order, 1)
		cache.entries[oldest] = nil
	end
end

local function normalize_line(line)
	line = tonumber(line) or 0
	return math.max(0, math.floor(line))
end

function M.invalidate_render_highlights(start_line)
	state.last_render_highlight_signature = nil
	if start_line ~= nil then
		local dirty_start = normalize_line(start_line)
		local current_dirty = tonumber(state.render_highlights_dirty_start)
		if not current_dirty or dirty_start < current_dirty then
			state.render_highlights_dirty_start = dirty_start
		end
	end
end

---@param bufnr number|nil
---@param start_line number|nil
---@param end_line number|nil
function M.clear_chat_highlights(bufnr, start_line, end_line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local clear_start = normalize_line(start_line)
	vim.api.nvim_buf_clear_namespace(bufnr, cs.chat_hl_ns, clear_start, end_line or -1)
	M.invalidate_render_highlights(clear_start)
end

---Replace a rendered half-open line range without clearing extmarks that shift
---from the following block. Highlights owned by the old range are always
---removed before the buffer mutation.
---@param opts table { bufnr: number, start_line: number, end_line: number, lines: string[], clear_animation?: boolean, apply_highlights?: function }
---@return boolean updated
---@return any error
function M.replace_chat_range(opts)
	opts = opts or {}
	local bufnr = opts.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false, "invalid buffer"
	end
	local start_line = normalize_line(opts.start_line)
	local end_line = normalize_line(opts.end_line)
	if end_line < start_line then
		return false, "invalid line range"
	end

	local ok, err = xpcall(function()
		vim.bo[bufnr].modifiable = true
		if opts.clear_animation then
			vim.api.nvim_buf_clear_namespace(bufnr, cs.chat_anim_ns, start_line, end_line)
		end
		M.clear_chat_highlights(bufnr, start_line, end_line)
		vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, opts.lines or {})
		if type(opts.apply_highlights) == "function" then
			opts.apply_highlights()
		end
	end, debug.traceback)

	pcall(function()
		vim.bo[bufnr].modifiable = false
	end)
	if not ok then
		state.force_full_render = true
		return false, err
	end
	return true
end

---@param opts? table { reset_expansions?: boolean, preserve_render_cache?: boolean, force_full_render?: boolean }
function M.reset_chat_surface(opts)
	opts = opts or {}
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.message_positions = {}
	state.pending_inputs = {}
	state.tasks = {}
	state.task_child_cache = {}
	state.task_child_loading = {}
	state.task_summary_cache = { entries = {}, order = {} }
	state.tools = {}
	state.todo_dock_signature = nil
	if opts.reset_expansions then
		state.expanded_tasks = {}
		state.expanded_tools = {}
	end
	state.stream_blocks = {}
	state.spinner_footer_line = nil
	state.render_in_progress = false
	state.render_highlights_dirty_start = nil
	if opts.force_full_render ~= false then
		state.force_full_render = true
	end
	if not opts.preserve_render_cache then
		M.clear_render_cache()
		M.clear_code_cache()
	end
end

---@param ... any
function M.render_cache_key(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...) or "")
	end
	return table.concat(parts, "\0")
end

---@param session_id string|nil
---@param message_id string|nil
---@param part_id string|nil
---@param kind string|nil
---@return string|nil
function M.stream_block_key(session_id, message_id, part_id, kind)
	if not session_id or not message_id or not part_id or not kind then
		return nil
	end
	return M.render_cache_key("stream", session_id, message_id, part_id, kind)
end

---@param key string|nil
function M.render_cache_get(key)
	local cache = M.ensure_render_cache()
	local value = cache.blocks[key]
	return value
end

---@param key string|nil
---@param value any
function M.render_cache_put(key, value)
	if not key or not value then
		return value
	end
	local cache = M.ensure_render_cache()
	if cache.blocks[key] == nil then
		table.insert(cache.order, key)
	end
	cache.blocks[key] = value
	while #cache.order > RENDER_CACHE_MAX_BLOCKS do
		local oldest = table.remove(cache.order, 1)
		cache.blocks[oldest] = nil
	end
	return value
end

---@param parts string[]
---@param highlights table|nil
---@param start_line number|nil
local function append_highlight_signature(parts, highlights, start_line)
	if type(highlights) ~= "table" then
		return
	end
	start_line = start_line or 0
	for _, hl in ipairs(highlights) do
		if type(hl) == "table" and hl.hl_group then
			local line = start_line + (hl.line or 0)
			local end_line = hl.end_line and (start_line + hl.end_line) or line
			table.insert(
				parts,
				table.concat({
					tostring(line),
					tostring(end_line),
					tostring(hl.col_start or 0),
					tostring(hl.col_end or hl.end_col or ""),
					tostring(hl.hl_group or ""),
					tostring(hl.priority or ""),
					tostring(hl.hl_eol or ""),
				}, ":")
			)
		end
	end
end

---@param content_highlights table|nil
---@return string
function M.render_highlight_signature(content_highlights)
	local parts = {}
	if type(content_highlights) == "table" and content_highlights._opencode_signature then
		table.insert(parts, tostring(content_highlights._opencode_signature))
	end
	append_highlight_signature(parts, content_highlights, 0)

	local function append_line_map(line_map)
		local keys = {}
		for key in pairs(line_map or {}) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			local pos = line_map[key]
			append_highlight_signature(parts, pos and pos.highlights, pos and pos.start_line or 0)
		end
	end

	for _, line_map in ipairs({ state.questions, state.permissions, state.edits, state.tasks, state.tools }) do
		append_line_map(line_map)
	end
	local result = table.concat(parts, "|")
	return result
end

---@param changed_start number|nil
---@param content_highlights table|nil
---@return number
function M.highlight_clear_start(changed_start, content_highlights)
	local clear_start = normalize_line(changed_start)
	local function consider(highlights, start_line)
		local moved = false
		if type(highlights) ~= "table" then
			return moved
		end
		start_line = start_line or 0
		for _, hl in ipairs(highlights) do
			if type(hl) == "table" then
				local line = start_line + (hl.line or 0)
				local end_line = hl.end_line and (start_line + hl.end_line) or line
				if line < clear_start and end_line >= clear_start then
					clear_start = line
					moved = true
				end
			end
		end
		return moved
	end
	local function consider_widget_range(pos)
		if type(pos) ~= "table" then
			return false
		end
		local start_line = tonumber(pos.start_line)
		local end_line = tonumber(pos.end_line)
		if not start_line or not end_line then
			return false
		end
		if start_line < clear_start and end_line >= clear_start then
			clear_start = normalize_line(start_line)
			return true
		end
		return false
	end

	local moved = true
	while moved do
		moved = consider(content_highlights, 0)
		for _, line_map in ipairs({ state.questions, state.permissions, state.edits, state.tasks, state.tools }) do
			for _, pos in pairs(line_map or {}) do
				moved = consider_widget_range(pos) or moved
				moved = consider(pos.highlights, pos.start_line or 0) or moved
			end
		end
	end
	local result = math.max(0, clear_start)
	return result
end

return M
