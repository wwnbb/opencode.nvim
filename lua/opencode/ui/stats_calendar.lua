-- Activity calendar used by the /stats screen. The layout and activity levels
-- follow OpenCode's TUI calendar: Monday-first weeks, Thursday month labels,
-- and quartiles of the distinct positive daily step counts.

local M = {}

local month_lengths = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
local month_names = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local day_names = { "M", "T", "W", "T", "F", "S", "S" }

local function leap_year(year)
	return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

local function days_before_year(year)
	local previous = year - 1
	return previous * 365 + math.floor(previous / 4) - math.floor(previous / 100) + math.floor(previous / 400)
end

local function date_ordinal(date)
	if type(date) ~= "string" then return nil end
	local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	if not year or year < 1 or month < 1 or month > 12 then return nil end
	local days_in_month = month_lengths[month] + (month == 2 and leap_year(year) and 1 or 0)
	if day < 1 or day > days_in_month then return nil end
	local ordinal = days_before_year(year) + day
	for previous_month = 1, month - 1 do
		ordinal = ordinal + month_lengths[previous_month]
	end
	if month > 2 and leap_year(year) then ordinal = ordinal + 1 end
	return ordinal
end

local function ordinal_date(ordinal)
	local low, high = 1, 9999
	while low < high do
		local middle = math.floor((low + high + 1) / 2)
		if days_before_year(middle) < ordinal then low = middle else high = middle - 1 end
	end
	local year = low
	local day = ordinal - days_before_year(year)
	local month = 1
	while month < 12 do
		local length = month_lengths[month] + (month == 2 and leap_year(year) and 1 or 0)
		if day <= length then break end
		day = day - length
		month = month + 1
	end
	return string.format("%04d-%02d-%02d", year, month, day), month
end

local function steps_for_date(daily, date)
	local steps = tonumber(daily[date]) or 0
	return steps > 0 and steps or 0
end

local function activity_levels(daily)
	local unique, sorted = {}, {}
	for _, value in pairs(daily) do
		local steps = tonumber(value)
		if steps and steps > 0 and not unique[steps] then
			unique[steps] = true
			table.insert(sorted, steps)
		end
	end
	table.sort(sorted)
	local levels = {}
	for index, steps in ipairs(sorted) do
		levels[steps] = math.ceil(index / #sorted * 4)
	end
	return levels
end

local function current_date()
	return os.date("%Y-%m-%d")
end

--- Render a calendar at the requested content width. The view's end_date is
--- inclusive; absent dates default to January 1 through today. Marks use
--- zero-based line numbers and byte columns for nvim_buf_set_extmark.
--- @param view table
--- @param width number
--- @return string[], table[]
function M.render(view, width)
	view = view or {}
	width = math.max(10, math.floor(tonumber(width) or 60))
	local daily = type(view.daily) == "table" and view.daily or {}
	local end_date = date_ordinal(view.end_date) and view.end_date or current_date()
	local finish = date_ordinal(end_date)
	local start_date = view.start_date
	if not date_ordinal(start_date) then start_date = end_date:sub(1, 4) .. "-01-01" end
	local first = date_ordinal(start_date)
	if first > finish then first = finish end

	-- January 1, year 1 was a Monday in the proleptic Gregorian calendar.
	local first_monday = first - ((first - 1) % 7)
	local total_weeks = math.floor((finish - first_monday) / 7) + 1
	local max_weeks = math.max(1, math.floor((width - 4) / 2))
	local weeks = math.min(total_weeks, 53, max_weeks)
	local calendar_start = first_monday + math.max(0, total_weeks - weeks) * 7
	local calendar_width = 4 + weeks * 2
	local indent = math.max(0, math.floor((width - calendar_width) / 2))
	local prefix = string.rep(" ", indent)
	local levels = activity_levels(daily)
	local lines, marks = {}, {}

	-- The TUI chooses each week's month from Thursday, clamped into the
	-- requested date range. A label starts at the first week of each month.
	local labels, previous_month = {}, nil
	for week = 0, weeks - 1 do
		local midpoint = math.max(first, math.min(finish, calendar_start + week * 7 + 3))
		local _, month = ordinal_date(midpoint)
		if week == 0 or month ~= previous_month then
			table.insert(labels, { week = week, text = month_names[month] })
		end
		previous_month = month
	end
	local header = prefix .. "    "
	for index, label in ipairs(labels) do
		local next_week = labels[index + 1] and labels[index + 1].week or weeks
		local span = (next_week - label.week) * 2
		local text = #label.text <= span and label.text or ""
		if text ~= "" then
			local col = #header
			table.insert(marks, { line = 0, col = col, end_col = col + #text, group = "OpenCodeStatsMuted" })
		end
		header = header .. text .. string.rep(" ", span - #text)
	end
	header = header:gsub("%s+$", "")
	lines[1] = header

	for day = 0, 6 do
		local line = prefix .. day_names[day + 1] .. "   "
		table.insert(marks, {
			line = day + 1, col = indent, end_col = indent + 1, group = "OpenCodeStatsMuted",
		})
		for week = 0, weeks - 1 do
			local ordinal = calendar_start + week * 7 + day
			if ordinal < first or ordinal > finish then
				line = line .. "  "
			else
				local date = ordinal_date(ordinal)
				local steps = steps_for_date(daily, date)
				local symbol = steps > 0 and "■" or "·"
				local group = steps > 0 and ("OpenCodeStatsLevel" .. levels[steps]) or "OpenCodeStatsInactive"
				local col = #line
				line = line .. symbol .. " "
				table.insert(marks, {
					line = day + 1, col = col, end_col = col + #symbol, group = group,
				})
			end
		end
		lines[day + 2] = line:gsub("%s+$", "")
	end

	if weeks < total_weeks then
		local note = string.format("Your last %d weeks", weeks)
		local col = math.max(0, math.floor((width - #note) / 2))
		lines[9] = string.rep(" ", col) .. note
		table.insert(marks, { line = 8, col = col, end_col = col + #note, group = "OpenCodeStatsMuted" })
	end
	return lines, marks
end

return M
