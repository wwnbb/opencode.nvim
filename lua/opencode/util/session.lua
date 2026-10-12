local M = {}

local NEW_SESSION_TITLE_PATTERN = "^(New session) %- %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$"
local CHILD_SESSION_TITLE_PATTERN = "^(Child session) %- %d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%d%.%d%d%dZ$"

---@param title any
---@return string|nil title Display-safe title
function M.displayTitle(title)
	if type(title) ~= "string" or title == "" then
		return nil
	end
	return title:match(NEW_SESSION_TITLE_PATTERN) or title:match(CHILD_SESSION_TITLE_PATTERN) or title
end

return M
