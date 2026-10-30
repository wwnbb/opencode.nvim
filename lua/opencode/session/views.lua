-- The only core entry to the chat view registry. Core never loads chat UI: until
-- the chat is set up there are no views, so every accessor degrades to "none".
local M = {}

---@return table|nil registry opencode.ui.chat.state when it has been loaded
function M.registry()
	local views = package.loaded["opencode.ui.chat.state"]
	return views and type(views.all) == "function" and views or nil
end

---Views that are registered and either visible or parked in a hidden layout.
---@return table[]
function M.live()
	local views = M.registry()
	return views and views.live_views() or {}
end

---@param view table
---@return boolean
function M.is_live(view)
	return vim.tbl_contains(M.live(), view)
end

---Whether the tab workspace holds layouts, shown or parked.
---@return boolean
function M.has_layouts()
	local workspace = package.loaded["opencode.ui.chat.workspace"]
	return workspace ~= nil and #workspace.list() > 0
end

---@param view table
---@return string|nil
function M.root_session_id(view)
	local views = M.registry()
	return views and views.root_session_id(view)
end

return M
