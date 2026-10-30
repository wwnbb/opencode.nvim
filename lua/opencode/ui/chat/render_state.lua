local cs = require("opencode.ui.chat.state")
return cs.factory("render_state", function(view)
local M = {}

local state = view
local memo = require("opencode.util.memo")

local RENDER_CACHE_MAX_BLOCKS = 1000
local TASK_SUMMARY_CACHE_MAX_ENTRIES = 100
local suffix = view == cs.state and "" or ":" .. view.id
local render_pool_name, task_summary_pool_name = "render" .. suffix, "task_summary" .. suffix
local render_pool = memo.new(render_pool_name, { max_entries = RENDER_CACHE_MAX_BLOCKS })
local task_summary_pool = memo.new(task_summary_pool_name, { max_entries = TASK_SUMMARY_CACHE_MAX_ENTRIES })
local render_identity, task_summary_identity
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
	return function(text, lang, opts, block)
		opts = opts or {}
		local key = M.render_cache_key(owner, block.open_line, lang)
		local signature = syntax.cache_signature(lang, opts)
		local entry = code_cache.entries[key]
		if entry and entry.text == text and entry.signature == signature then
			return entry.highlights, entry.status
		end
		local captures, status = syntax.highlight_text(text, lang, opts)
		if entry then
			code_cache.bytes = code_cache.bytes - entry.bytes
			code_cache.entries[key] = nil
			for index, cached_key in ipairs(code_cache.order) do
				if cached_key == key then table.remove(code_cache.order, index); break end
			end
		end
		-- Do not permanently cache missing parsers, queries or parse failures.
		if syntax.needs_retry(captures, status) then return captures, status end
		-- Conservative accounting includes table storage and capture strings.
		local bytes = 512 + #key + #signature + #text
		for _, capture in ipairs(captures) do bytes = bytes + 384 + #(capture.hl_group or "") end
		if bytes > CODE_CACHE_MAX_BYTES then return captures, status end
		while #code_cache.order >= CODE_CACHE_MAX_ENTRIES or code_cache.bytes + bytes > CODE_CACHE_MAX_BYTES do
			local oldest = table.remove(code_cache.order, 1)
			code_cache.bytes = code_cache.bytes - code_cache.entries[oldest].bytes
			code_cache.entries[oldest] = nil
		end
		code_cache.entries[key] = { text = text, signature = signature, highlights = captures, status = status, bytes = bytes }
		code_cache.order[#code_cache.order + 1] = key
		code_cache.bytes = code_cache.bytes + bytes
		return captures, status
	end
end

-- State fields are identity sentinels only. Keeping values there as well as in
-- the pool would let an inspection table retain entries after shared eviction.
local function ensure_render_pool()
	if type(state.render_cache) ~= "table" or state.render_cache ~= render_identity then
		render_pool:clear()
		state.render_cache = { blocks = {}, order = {} }
		render_identity = state.render_cache
	end
	return render_pool
end

local function ensure_task_summary_pool()
	if type(state.task_summary_cache) ~= "table" or state.task_summary_cache ~= task_summary_identity then
		task_summary_pool:clear()
		state.task_summary_cache = { entries = {}, order = {} }
		task_summary_identity = state.task_summary_cache
	end
	return task_summary_pool
end

---Return an inspection snapshot without retaining a second copy in state.
function M.ensure_render_cache()
	local pool = ensure_render_pool()
	local snapshot = { blocks = {}, order = {} }
	local entry = pool.first
	while entry do
		snapshot.blocks[entry.signature] = entry.value
		snapshot.order[#snapshot.order + 1] = entry.signature
		entry = entry.pool_next
	end
	return snapshot
end

function M.clear_render_cache()
	render_pool:clear()
	state.render_cache = { blocks = {}, order = {} }
	render_identity = state.render_cache
	state.last_render_highlight_signature = nil
end

function M.render_cache_stats()
	return ensure_render_pool():stats()
end

function M.clear_task_summary_cache()
	task_summary_pool:clear()
	state.task_summary_cache = { entries = {}, order = {} }
	task_summary_identity = state.task_summary_cache
end

function M.task_summary_cache_stats()
	return ensure_task_summary_pool():stats()
end

function M.dispose()
	M.clear_render_cache()
	M.clear_task_summary_cache()
	M.clear_code_cache()
	if view ~= cs.state then
		memo.remove(render_pool_name)
		memo.remove(task_summary_pool_name)
	end
end

---@param child_session_id string
---@param revision number
---@return table|nil summary
---@return string|nil prompt
---@return boolean found
function M.task_summary_cache_get(child_session_id, revision)
	local pool = ensure_task_summary_pool()
	local entry = pool:get(child_session_id, revision)
	if entry then return entry.summary, entry.prompt, true end
	pool:delete(child_session_id)
	return nil, nil, false
end

---@param child_session_id string
---@param revision number
---@param summary table
---@param prompt string|nil
function M.task_summary_cache_put(child_session_id, revision, summary, prompt)
	ensure_task_summary_pool():put(child_session_id, revision, { summary = summary, prompt = prompt })
end

---Drop only the bounded cached entries owned by this session.
function M.clear_session(session_id)
	if type(session_id) ~= "string" or session_id == "" then return end
	local pool = ensure_render_pool()
	local session_field = session_id .. "\0"
	for owner in pairs(pool.entries) do
		if type(owner) == "string" then
			local separator = owner:find("\0", 1, true)
			if separator and owner:sub(separator + 1, separator + #session_field) == session_field then
				pool:delete(owner)
			end
		end
	end
	ensure_task_summary_pool():delete(session_id)
	for index = #code_cache.order, 1, -1 do
		local key = code_cache.order[index]
		if key:sub(1, #session_field) == session_field then
			code_cache.bytes = code_cache.bytes - code_cache.entries[key].bytes
			code_cache.entries[key] = nil
			table.remove(code_cache.order, index)
		end
	end
end

local function normalize_line(line)
	line = tonumber(line) or 0
	return math.max(0, math.floor(line))
end

-- last_render_highlight_signature holds the applied highlight frame (see
-- highlight_frame); any direct buffer or extmark change drops it.
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
	local details = package.loaded["opencode.ui.chat.execute_details"]
	if details then cs.module(view, details).close({ restore_focus = false }) end
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.message_positions = {}
	state.pending_inputs = {}
	state.tasks = {}
	state.task_child_cache = {}
	state.task_child_loading = {}
	M.clear_task_summary_cache()
	state.tools = {}
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
	-- Shared memo pools serve every view; only global invalidations clear them.
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

---@param key string|nil Exact computation signature.
---@param owner string|nil Stable owner; defaults to key for older callers.
function M.render_cache_get(key, owner)
	local pool = ensure_render_pool()
	owner = owner or key
	if not key then pool:delete(owner); return nil end
	local value = pool:get(owner, key)
	if value == nil then pool:delete(owner) end
	return value
end

---@param owner string|nil
function M.render_cache_delete(owner)
	ensure_render_pool():delete(owner)
end

---@param key string|nil Exact computation signature.
---@param value any
---@param owner string|nil Stable owner; defaults to key for older callers.
function M.render_cache_put(key, value, owner)
	local pool = ensure_render_pool()
	owner = owner or key
	if not key or not value then pool:delete(owner); return value end
	pool:put(owner, key, value)
	return value
end

---@param old_lines string[]
---@param new_lines string[]
---@return integer start 0-based first differing line
---@return integer old_end exclusive end of the replaced old range
---@return integer new_end exclusive end of the replacement new range
function M.diff_lines(old_lines, new_lines)
	local old_count, new_count = #old_lines, #new_lines
	local limit = math.min(old_count, new_count)
	local start = 0
	while start < limit and old_lines[start + 1] == new_lines[start + 1] do
		start = start + 1
	end
	local suffix = 0
	while suffix < limit - start and old_lines[old_count - suffix] == new_lines[new_count - suffix] do
		suffix = suffix + 1
	end
	return start, old_count - suffix, new_count - suffix
end

local WIDGET_MAPS = { "questions", "permissions", "edits", "tasks", "tools" }

---Highlight sources of one rendered frame, kept by reference so the next frame
---can be compared without building signatures.
---@param content_highlights table|nil
---@param nui_lines NuiLine[]|nil
function M.highlight_frame(content_highlights, nui_lines)
	local maps = {}
	for index, name in ipairs(WIDGET_MAPS) do maps[index] = state[name] or {} end
	return { content = content_highlights or {}, nui_lines = nui_lines or {}, maps = maps }
end

local function highlight_bounds(hl, base)
	local line = base + (hl.line or 0)
	return line, hl.end_line and (base + hl.end_line) or line
end

---Grow [start, finish) until no highlight or widget range crosses an edge.
---A nil finish leaves the range open to the end of the buffer.
---@param frame table
---@param start number
---@param finish number|nil
---@return number start
---@return number|nil finish
function M.extend_highlight_range(frame, start, finish)
	start = normalize_line(start)
	local function cross(line, end_line)
		local moved = false
		if line < start and end_line >= start then
			start, moved = line, true
		end
		if finish and line < finish and end_line >= finish then
			finish, moved = end_line + 1, true
		end
		return moved
	end
	local function scan(highlights, base)
		local moved = false
		if type(highlights) ~= "table" then return false end
		for _, hl in ipairs(highlights) do
			if type(hl) == "table" and cross(highlight_bounds(hl, base)) then moved = true end
		end
		return moved
	end
	local moved = true
	while moved do
		moved = scan(frame.content, 0)
		for _, map in ipairs(frame.maps) do
			for _, pos in pairs(map) do
				if type(pos) == "table" then
					local first, last = tonumber(pos.start_line), tonumber(pos.end_line)
					if first and last and cross(normalize_line(first), last) then moved = true end
					if scan(pos.highlights, pos.start_line or 0) then moved = true end
				end
			end
		end
	end
	return math.max(0, start), finish
end

---@param changed_start number|nil
---@param content_highlights table|nil
---@return number
function M.highlight_clear_start(changed_start, content_highlights)
	return (M.extend_highlight_range(M.highlight_frame(content_highlights), changed_start))
end

local function same_highlight(a, a_base, b, b_base)
	local a_line, a_end = highlight_bounds(a, a_base)
	local b_line, b_end = highlight_bounds(b, b_base)
	return a_line == b_line and a_end == b_end
		and (a.col_start or 0) == (b.col_start or 0)
		and (a.col_end or a.end_col) == (b.col_end or b.end_col)
		and a.hl_group == b.hl_group and a.priority == b.priority and a.hl_eol == b.hl_eol
end

-- Next highlight that apply_extmark_highlights would place at or after from.
local function next_applied(highlights, index, base, from)
	while true do
		index = index + 1
		local hl = highlights[index]
		if hl == nil then return index, nil end
		if type(hl) == "table" and hl.hl_group and base + (hl.line or 0) >= from then return index, hl end
	end
end

local function same_highlight_list(a, a_base, b, b_base, from)
	a, b = type(a) == "table" and a or {}, type(b) == "table" and b or {}
	local i, j, x, y = 0, 0, nil, nil
	repeat
		i, x = next_applied(a, i, a_base, from)
		j, y = next_applied(b, j, b_base, from)
		if (x == nil) ~= (y == nil) then return false end
		if x and not same_highlight(x, a_base, y, b_base) then return false end
	until x == nil
	return true
end

local function has_text_highlight(line)
	for _, text in ipairs(line and line._texts or {}) do
		if text.extmark then return true end
	end
	return false
end

---Whether the extmark highlights previous applied from old_from are exactly
---those frame applies from new_from. NuiText reuses its extmark id, so with
---check_lines a highlighted line must also keep its NuiLine: applying a moved
---line elsewhere would move the mark that the unchanged tail still relies on.
---@param previous table
---@param frame table
---@param old_from number
---@param new_from number
---@param check_lines boolean|nil
---@return boolean
function M.same_frame_highlights(previous, frame, old_from, new_from, check_lines)
	if previous.content._opencode_signature ~= frame.content._opencode_signature then return false end
	local shift = new_from - old_from
	if not same_highlight_list(previous.content, shift, frame.content, 0, new_from) then return false end
	for index, map in ipairs(frame.maps) do
		local old_map = previous.maps[index] or {}
		for id, pos in pairs(map) do
			local old = old_map[id]
			if not same_highlight_list(old and old.highlights, (old and old.start_line or 0) + shift,
				pos.highlights, pos.start_line or 0, new_from) then
				return false
			end
		end
		for id, old in pairs(old_map) do
			if map[id] == nil and not same_highlight_list(old.highlights, (old.start_line or 0) + shift, nil, 0, new_from) then
				return false
			end
		end
	end
	if check_lines then
		local lines, old_lines = frame.nui_lines, previous.nui_lines
		for row = new_from + 1, #lines do
			local old, line = old_lines[row - shift], lines[row]
			if old ~= line and (has_text_highlight(old) or has_text_highlight(line)) then return false end
		end
	end
	return true
end

return M

end)
