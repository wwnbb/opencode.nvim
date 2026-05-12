-- opencode.nvim - Session title helpers (mirrors OpenCode UI behavior)

local M = {}

local NEW_SESSION_TITLE_PATTERN = "^New session %- %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$"
local CHILD_SESSION_TITLE_PATTERN = "^Child session %- %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$"

---@param title any
---@return "New session"|"Child session"|nil label
function M.defaultTitleLabel(title)
	if type(title) ~= "string" then
		return nil
	end
	if title:match(NEW_SESSION_TITLE_PATTERN) then
		return "New session"
	end
	if title:match(CHILD_SESSION_TITLE_PATTERN) then
		return "Child session"
	end
	return nil
end

---@param title any
---@return boolean is_default Whether title is an OpenCode generated placeholder
function M.isDefaultTitle(title)
	return M.defaultTitleLabel(title) ~= nil
end

---@param title any
---@return string|nil title Display-safe title
function M.displayTitle(title)
	if type(title) ~= "string" or title == "" then
		return nil
	end
	return M.defaultTitleLabel(title) or title
end

return M
