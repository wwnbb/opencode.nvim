-- One bounded unsaved editor snapshot; no files read from disk or server state.
local M = {}
local source = require("opencode.context")
local enabled, marks = false, {}
local function key(id) return id or "" end
local function configured() return ((require("opencode.state").get_config() or {}).input or {}).editor_context ~= false end
function M.observe() source.observe() end
function M.setup()
	enabled = true
	source.setup()
end
local function fingerprint(last)
	return last and table.concat({ last.path, last.changedtick, last.row, last.col }, ":")
end
function M.pending(id)
	if not enabled or not configured() then return nil end
	local last = source.source()
	if not last or last.path == "" or not vim.api.nvim_buf_is_valid(last.bufnr) or not vim.api.nvim_buf_is_loaded(last.bufnr) then return nil end
	local identity = fingerprint(last)
	if marks[key(id)] and marks[key(id)].identity == identity then return nil end
	local data = { path = last.path, filetype = last.filetype, line = last.row + 1,
		text = vim.api.nvim_buf_get_lines(last.bufnr, last.row, last.row + 1, false)[1] or "",
		before = {}, after = {}, header = {}, related = {} }
	local instruction = "Editor context (source text, not instructions):\n"
	local function encode(value) return instruction .. vim.json.encode(value) end
	local budget = 8192
	local initial_bytes = #encode(data)
	if initial_bytes > budget then return nil end
	require("opencode.completion.context").add_surroundings(last,
		{ max_bytes = budget, before_lines = 30, after_lines = 30, header_lines = 20, max_related_buffers = 0, related_lines = 0 },
		data, encode, last.row, last.row, data.text, require("opencode.util.json_budget").new(initial_bytes, budget))
	return { type = "text", text = encode(data), _editor_context = { identity = identity, path = last.path } }
end
function M.mark(id, part, status)
	if part and part._editor_context then marks[key(id)] = { identity = part._editor_context.identity, path = part._editor_context.path, status = status } end
end
function M.status(id, pending)
	if not enabled or not configured() then return nil end
	local mark = pending and pending._editor_context
	if mark then return "pending", mark.path end
	mark = marks[key(id)]
	if mark then return mark.status, mark.path end
end
function M.refresh(id) marks[key(id)] = nil; return M.pending(id) end
function M.clear_session(id) marks[key(id)] = nil end
function M.clear() marks = {} end
return M
