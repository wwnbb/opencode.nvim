-- Capture a Visual selection from the live editor buffer without reading disk.
local M = {}

local function normalize(path)
	return vim.fs.normalize(vim.fn.fnamemodify(path, ":p")):gsub("/$", "")
end

local function within(path, root)
	return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function visual_mode(mode)
	return mode == "v" or mode == "V" or mode == "\022"
end

local function position_in_buffer(pos, bufnr)
	return type(pos) == "table" and pos[2] > 0 and pos[3] > 0
		and (pos[1] == 0 or pos[1] == bufnr)
end

---Capture the active Visual region, or the last Visual region after leaving it.
---The returned lines are selected fragments in physical source-line order. In
---blockwise mode, getregion() preserves the visual columns (including padding).
---@return table|nil snapshot
---@return string|nil error
function M.capture()
	local bufnr, winid = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
	if not vim.api.nvim_buf_is_loaded(bufnr) then return nil, "Selection needs a loaded buffer" end

	local mode = vim.api.nvim_get_mode().mode
	local active = visual_mode(mode)
	local first = vim.fn.getpos(active and "v" or "'<")
	local last = vim.fn.getpos(active and "." or "'>")
	if not active then mode = vim.fn.visualmode() end
	if not visual_mode(mode) or not position_in_buffer(first, bufnr) or not position_in_buffer(last, bufnr) then
		return nil, "No Visual selection found"
	end

	local ok, selected = pcall(vim.fn.getregion, first, last, { type = mode })
	if not ok or type(selected) ~= "table" or #selected == 0 then
		return nil, "Selected range is empty"
	end
	local text = table.concat(selected, "\n")
	if text == "" then return nil, "Selected range is empty" end

	local path = vim.api.nvim_buf_get_name(bufnr)
	path = path ~= "" and normalize(path) or ""
	local cwd = normalize(vim.fn.getcwd())
	local directory = path ~= "" and vim.fs.dirname(path) or cwd
	local root = vim.fs.root(directory, ".git")
	root = root and normalize(root) or (within(directory, cwd) and cwd or directory)
	local start_line = math.min(first[2], last[2])

	return {
		bufnr = bufnr,
		winid = winid,
		changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
		path = path,
		root = root,
		filetype = vim.bo[bufnr].filetype,
		mode = mode,
		start_line = start_line,
		end_line = start_line + #selected - 1,
		lines = selected,
		text = text,
	}
end

return M
