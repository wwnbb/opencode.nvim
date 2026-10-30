local cs = require("opencode.ui.chat.state")
return cs.factory("render_state", function(view)
local M = {}

local state = view
local memo = require("opencode.util.memo")
local render_blocks = require("opencode.ui.chat.render_blocks")
local positions = cs.module(view, require("opencode.ui.chat.positions"))

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
	state.applied_frame = nil
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

-- applied_frame describes the buffer as the last render left it (see
-- do_render); a direct buffer or extmark change it cannot account for drops it.
function M.drop_applied_frame()
	state.applied_frame = nil
end

---The applied frame when it still describes the buffer exactly.
---@return table|nil
function M.applied_frame()
	local applied = state.applied_frame
	local bufnr = state.bufnr
	if not applied or applied.bufnr ~= bufnr or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
	if applied.tick ~= vim.api.nvim_buf_get_changedtick(bufnr)
		or applied.line_count ~= vim.api.nvim_buf_line_count(bufnr) then
		return nil
	end
	return applied
end

---@param bufnr number|nil
---@param start_line number|nil
---@param end_line number|nil
function M.clear_chat_highlights(bufnr, start_line, end_line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, cs.chat_hl_ns, normalize_line(start_line), end_line or -1)
	M.drop_applied_frame()
end

---Replace a rendered half-open line range without clearing extmarks that shift
---from the following block. Highlights owned by the old range are always
---removed before the buffer mutation. A range inside one block of the applied
---frame marks that block rewritten; any other range drops the frame. The
---block row index takes the line count change, so tracked positions follow.
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
	local lines = opts.lines or {}
	local applied = bufnr == state.bufnr and M.applied_frame() or nil
	local block, _, block_count
	if applied then block, _, block_count = render_blocks.applied_block(applied, start_line, end_line) end

	local ok, err = xpcall(function()
		vim.bo[bufnr].modifiable = true
		if opts.clear_animation then
			vim.api.nvim_buf_clear_namespace(bufnr, cs.chat_anim_ns, start_line, end_line)
		end
		if end_line > start_line then
			vim.api.nvim_buf_clear_namespace(bufnr, cs.chat_hl_ns, start_line, end_line)
		end
		vim.api.nvim_buf_set_lines(bufnr, start_line, end_line, false, lines)
		if type(opts.apply_highlights) == "function" then
			opts.apply_highlights()
		end
	end, debug.traceback)

	pcall(function()
		vim.bo[bufnr].modifiable = false
	end)
	if ok and bufnr == state.bufnr then positions.shift(start_line, end_line, #lines) end
	if ok and block then
		render_blocks.replace(applied, block.key, block_count + #lines - (end_line - start_line),
			vim.api.nvim_buf_get_changedtick(bufnr))
	else
		M.drop_applied_frame()
	end
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
	state.spinner_footer = nil
	positions.clear()
	state.render_in_progress = false
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

return M

end)
