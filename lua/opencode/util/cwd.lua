-- Resolve the directory the user is working in for new sessions and other
-- location-scoped requests.
--
-- A bare vim.fn.getcwd() is wrong while focus is inside OpenCode: the "tab"
-- layout keeps chat in its own tabpage, and split layouts copy the source
-- window's :lcd into the chat window. Tab-local (:tcd, e.g. telescope-project)
-- and window-local (:lcd, e.g. nvim-tree) directory changes made in the editor
-- therefore never reach the chat side. Resolve from the editor window instead.
local M = {}

---@param win integer
---@return boolean
local function is_opencode_window(win)
	if not vim.api.nvim_win_is_valid(win) then return true end
	if vim.api.nvim_win_get_config(win).relative ~= "" then return true end
	local cs = require("opencode.session.views").registry()
	if cs and cs.for_window and cs.for_window(win) then return true end
	local input = package.loaded["opencode.ui.input"]
	if input and input.get_winids and vim.tbl_contains(input.get_winids(), win) then return true end
	local workspace = cs and cs.workspace
	return workspace ~= nil and workspace.tabpage ~= nil and vim.api.nvim_win_get_tabpage(win) == workspace.tabpage
end

---@param win integer
---@return string
local function window_cwd(win)
	local position = vim.fn.win_id2tabwin(win)
	return vim.fn.getcwd(position[2], position[1])
end

--- The editor window OpenCode was entered from, if it can still be found.
---@return integer|nil
function M.editor_window()
	local current = vim.api.nvim_get_current_win()
	if not is_opencode_window(current) then return current end
	local cs = require("opencode.session.views").registry()
	local workspace = cs and cs.workspace
	local candidate = workspace and workspace.return_winid
	if candidate and vim.api.nvim_win_is_valid(candidate) and not is_opencode_window(candidate) then
		return candidate
	end
	-- Split layouts: the previous window in this tab is the editor pane.
	local previous = vim.fn.win_getid(vim.fn.winnr("#"))
	if previous ~= 0 and not is_opencode_window(previous) then return previous end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if not is_opencode_window(win) then return win end
	end
	-- Tab layout with a lost return window: any other tab's focused window.
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		local win = vim.api.nvim_tabpage_get_win(tab)
		if not is_opencode_window(win) then return win end
	end
end

--- Working directory of the editor context (never a stale chat-side cwd).
---@return string
function M.get()
	local win = M.editor_window()
	if win then return window_cwd(win) end
	return vim.fn.getcwd()
end

return M
