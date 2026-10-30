local M = {}

---Convert string to titlecase (first letter of each word uppercase)
---@param str string
---@return string
function M.titlecase(str)
	if type(str) ~= "string" then
		return ""
	end
	local result = str:gsub("(%S)(%S*)", function(first, rest)
		return first:upper() .. rest
	end)
	return result
end

---A count in compact form, the one spelling every view uses: "950", "1.2K", "12K", "1.5M".
---@param value number|nil
---@return string
function M.compact_number(value)
	local number = math.max(0, math.floor((tonumber(value) or 0) + 0.5))
	if number < 1000 then return tostring(number) end
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for index, unit in ipairs(units) do
		if number >= unit[1] then
			local amount = tonumber(string.format("%.1f", number / unit[1]))
			-- 999.95K rounds up to the next unit.
			if amount >= 1000 and index > 1 then
				unit = units[index - 1]
				amount = tonumber(string.format("%.1f", number / unit[1]))
			end
			return (tostring(amount):gsub("%.0$", "")) .. unit[2]
		end
	end
	return tostring(number)
end

---Format duration in milliseconds to human readable string
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
