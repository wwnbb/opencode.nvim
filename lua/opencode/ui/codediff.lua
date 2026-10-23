-- opencode.nvim - codediff.nvim review backend
-- Opens the proposed content LEFT of the actual file with `:CodeDiff file`,
-- in codediff's own tab. codediff only diffs files on disk, so the proposed
-- content goes through a temp file. Returns the same windows/buffers as
-- diff_pair so native_diff keeps owning keymaps, review actions and teardown.

local M = {}

local warned = false

---@return boolean
function M.available()
	return vim.fn.exists(":CodeDiff") == 2
end

---True when the review tab should use codediff; warns once when the user
---asked for it but the plugin is missing.
---@return boolean
function M.enabled()
	local config = require("opencode.state").get_config() or {}
	if (config.diff or {}).provider ~= "codediff" then return false end
	if M.available() then return true end
	if not warned then
		warned = true
		vim.notify("opencode.nvim: diff.provider = \"codediff\" but codediff.nvim is not installed; using the native diff",
			vim.log.levels.WARN)
	end
	return false
end

---Whether `:CodeDiff file` can open this file. It takes whitespace-separated
---paths and treats a missing path as a git revision.
---@param filepath string
---@return boolean
function M.supports(filepath)
	return not filepath:find("%s") and vim.fn.filereadable(filepath) == 1
end

local function real(path)
	return vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
end

---Open a codediff view of `after` (LEFT, readonly) against `filepath` (RIGHT).
---@param filepath string Actual file on disk
---@param after string Proposed content
---@return { tab_page: integer, original_win: integer, original_buf: integer, proposed_win: integer, proposed_buf: integer, cleanup: fun() }|nil view
---@return string? err
function M.open(filepath, after)
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	local proposed_path = dir .. "/" .. vim.fn.fnamemodify(filepath, ":t")
	local function remove_temp() vim.fn.delete(dir, "rf") end
	local fd = io.open(proposed_path, "wb")
	if not fd then
		remove_temp()
		return nil, "could not write proposed content"
	end
	fd:write(after or "")
	fd:close()

	local previous_tab = vim.api.nvim_get_current_tabpage()
	local ok, err = pcall(vim.cmd, { cmd = "CodeDiff", args = { "file", proposed_path, filepath } })
	local tab = vim.api.nvim_get_current_tabpage()
	if not ok or tab == previous_tab then
		remove_temp()
		return nil, ok and "CodeDiff did not open a view" or tostring(err)
	end

	local view = { tab_page = tab }
	local proposed_name, actual_name = real(proposed_path), real(filepath)
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
		local buf = vim.api.nvim_win_get_buf(win)
		local name = real(vim.api.nvim_buf_get_name(buf))
		if name == proposed_name then
			view.proposed_win, view.proposed_buf = win, buf
		elseif name == actual_name then
			view.original_win, view.original_buf = win, buf
		end
	end
	if not view.proposed_buf or not view.original_buf then
		pcall(vim.cmd, vim.api.nvim_tabpage_get_number(tab) .. "tabclose")
		remove_temp()
		return nil, "CodeDiff view has no proposed/actual window"
	end

	vim.bo[view.proposed_buf].modifiable = false
	vim.bo[view.proposed_buf].readonly = true
	vim.bo[view.proposed_buf].buflisted = false
	local proposed_buf = view.proposed_buf
	view.cleanup = function()
		if vim.api.nvim_buf_is_valid(proposed_buf) then
			pcall(vim.api.nvim_buf_delete, proposed_buf, { force = true })
		end
		remove_temp()
	end
	return view
end

return M
