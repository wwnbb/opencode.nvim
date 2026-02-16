-- opencode.nvim - Locale utility functions (mirrors TUI's util/locale.ts)
local M = {}

---Convert string to titlecase (first letter of each word uppercase)
---@param str string
---@return string
function M.titlecase(str)
	local result = str:gsub("%b%w", function(c)
		return c:upper()
	end)
	return result
end

---Format duration in milliseconds to human readable string
---Matches TUI's Locale.duration()
---@param ms number Duration in milliseconds
---@return string
function M.duration(ms)
	if ms < 1000 then
		return string.format("%dms", ms)
	end
	if ms < 60000 then
		return string.format("%.1fs", ms / 1000)
	end
	if ms < 3600000 then
		local minutes = math.floor(ms / 60000)
		local seconds = math.floor((ms % 60000) / 1000)
		return string.format("%dm %ds", minutes, seconds)
	end
	if ms < 86400000 then
		local hours = math.floor(ms / 3600000)
		local minutes = math.floor((ms % 3600000) / 60000)
		return string.format("%dh %dm", hours, minutes)
	end
	local days = math.floor(ms / 86400000)
	local hours = math.floor((ms % 86400000) / 3600000)
	return string.format("%dd %dh", days, hours)
end

return M
