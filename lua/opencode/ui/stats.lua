-- Usage statistics display. The caller supplies a normalized view model:
-- { total_tokens, sessions, daily = { ["YYYY-MM-DD"] = steps },
--   active_days?, best_streak?, start_date?, end_date? }

local M = {}

local active_popup

local function count(value)
	return math.max(0, math.floor(tonumber(value) or 0))
end

local function format_count(value)
	local digits = tostring(count(value))
	return digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

local function format_compact(value)
	local number = count(value)
	if number < 1000 then return tostring(number) end
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for _, unit in ipairs(units) do
		if number >= unit[1] then
			return string.format("%.1f%s", number / unit[1], unit[2])
		end
	end
	return tostring(number)
end

local function centered(text, width)
	local padding = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
	return string.rep(" ", padding) .. text
end

local function centered_cell(text, width)
	local used = vim.fn.strdisplaywidth(text)
	local before = math.max(0, math.floor((width - used) / 2))
	local after = math.max(0, width - used - before)
	return string.rep(" ", before) .. text .. string.rep(" ", after)
end

local function date_epoch(date)
	if type(date) ~= "string" then return nil end
	local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not year then return nil end
	local epoch = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
	if not epoch or os.date("%Y-%m-%d", epoch) ~= date then return nil end
	return epoch
end

local function date_at(epoch)
	return os.date("%Y-%m-%d", epoch)
end

local function date_range(view)
	local first, last = date_epoch(view.start_date), date_epoch(view.end_date)
	if not first or not last then return nil end
	if os.date("%Y-%m", first) == os.date("%Y-%m", last) then
		return os.date("%b %Y", last)
	end
	if os.date("%Y", first) == os.date("%Y", last) then
		return os.date("%b", first) .. " - " .. os.date("%b %Y", last)
	end
	return os.date("%b %Y", first) .. " - " .. os.date("%b %Y", last)
end

local function days_apart(first, second)
	return math.floor(os.difftime(second, first) / 86400 + 0.5)
end

local function derived_activity(daily)
	local dates = {}
	for date, steps in pairs(daily or {}) do
		if count(steps) > 0 and date_epoch(date) then
			table.insert(dates, date)
		end
	end
	table.sort(dates)

	local best, streak = 0, 0
	for i, date in ipairs(dates) do
		local consecutive = i > 1 and days_apart(date_epoch(dates[i - 1]), date_epoch(date)) == 1
		streak = consecutive and streak + 1 or 1
		best = math.max(best, streak)
	end
	return #dates, best
end

local function activity_level(steps, maximum)
	if steps == 0 then return "OpenCodeStatsInactive" end
	if maximum <= 1 then return "OpenCodeStatsLevel4" end
	local ratio = math.log(steps + 1) / math.log(maximum + 1)
	if ratio < 0.25 then return "OpenCodeStatsLevel1" end
	if ratio < 0.50 then return "OpenCodeStatsLevel2" end
	if ratio < 0.75 then return "OpenCodeStatsLevel3" end
	return "OpenCodeStatsLevel4"
end

local function calendar_end(view)
	return date_epoch(view.end_date) or os.time({
		year = tonumber(os.date("%Y")),
		month = tonumber(os.date("%m")),
		day = tonumber(os.date("%d")),
		hour = 12,
	})
end

--- Render a usage report for a given content width. Marks use zero-based line
--- and byte columns, ready for nvim_buf_set_extmark.
--- @param view table
--- @param width number
--- @return string[], table[]
function M.render(view, width)
	view = view or {}
	width = math.max(10, math.floor(tonumber(width) or 60))
	local lines, marks = {}, {}
	local function add_line(text, group)
		text = text or ""
		table.insert(lines, text)
		if group and text ~= "" then
			table.insert(marks, { line = #lines - 1, col = 0, end_col = #text, group = group })
		end
	end

	local heading, range = "opencode / stats", date_range(view)
	if range and #heading + #range + 2 <= width then
		add_line(heading .. string.rep(" ", width - #heading - #range) .. range, "Comment")
	else
		add_line(heading, "Comment")
		if range then add_line(range, "Comment") end
	end
	add_line("")
	add_line(centered("opencode", width), "Title")
	add_line("")
	add_line(centered(format_compact(view.total_tokens), width), "Number")
	add_line(centered("TOKENS", width), "Comment")
	add_line("")

	local max_weeks = math.max(1, math.min(52, math.floor((width - 4) / 2)))
	local finish = calendar_end(view)
	local monday_offset = (tonumber(os.date("%w", finish)) + 6) % 7
	local last_monday = finish - monday_offset * 86400
	local range_start = date_epoch(view.start_date)
	local weeks = max_weeks
	if range_start and range_start <= finish then
		local start_offset = (tonumber(os.date("%w", range_start)) + 6) % 7
		local start_monday = range_start - start_offset * 86400
		weeks = math.min(max_weeks, math.floor(days_apart(start_monday, last_monday) / 7) + 1)
	end
	local first_monday = last_monday - (weeks - 1) * 7 * 86400
	local calendar_indent = math.max(0, math.floor((width - (4 + weeks * 2)) / 2))
	local maximum = 0
	for _, steps in pairs(view.daily or {}) do maximum = math.max(maximum, count(steps)) end

	local month_header = string.rep(" ", calendar_indent + 4 + weeks * 2)
	local last_label_end = 0
	for week = 1, weeks do
		local week_epoch = first_monday + (week - 1) * 7 * 86400
		local month = os.date("%m", week_epoch + 6 * 86400)
		local previous_month = os.date("%m", week_epoch - 86400)
		if week == 1 or month ~= previous_month then
			local label = os.date("%b", week_epoch + 6 * 86400)
			local col = calendar_indent + 4 + (week - 1) * 2
			if col >= last_label_end and col + #label <= #month_header then
				month_header = month_header:sub(1, col) .. label .. month_header:sub(col + #label + 1)
				last_label_end = col + #label + 1
			end
		end
	end
	add_line(month_header:gsub("%s+$", ""), "Comment")

	local day_names = { "M", "T", "W", "T", "F", "S", "S" }
	for day = 1, 7 do
		local line = string.rep(" ", calendar_indent) .. day_names[day] .. "   "
		local row = #lines
		for week = 1, weeks do
			local epoch = first_monday + ((week - 1) * 7 + day - 1) * 86400
			if days_apart(finish, epoch) > 0 or (range_start and days_apart(epoch, range_start) > 0) then
				line = line .. "  "
			else
				local steps = count((view.daily or {})[date_at(epoch)])
				local start_col = #line
				local symbol = steps > 0 and "■" or "·"
				line = line .. symbol .. " "
				table.insert(marks, {
					line = row, col = start_col, end_col = start_col + #symbol,
					group = activity_level(steps, maximum),
				})
			end
		end
		add_line(line:gsub("%s+$", ""))
	end

	add_line("")
	local active_days, best_streak = derived_activity(view.daily)
	active_days = count(view.active_days or active_days)
	best_streak = count(view.best_streak or best_streak)
	local summary = {
		{ "BEST STREAK", format_count(best_streak) .. (best_streak == 1 and " day" or " days") },
		{ "ACTIVE DAYS", format_count(active_days) },
		{ "SESSIONS", format_count(view.sessions) },
	}
	if width >= 54 then
		local column_width = math.floor(width / 3)
		local headings, values = "", ""
		for _, item in ipairs(summary) do
			headings = headings .. centered_cell(item[1], column_width)
			values = values .. centered_cell(item[2], column_width)
		end
		add_line(values:gsub("%s+$", ""), "Number")
		add_line(headings:gsub("%s+$", ""), "Comment")
	else
		for _, item in ipairs(summary) do
			add_line(centered(item[2] .. "  " .. item[1], width))
		end
	end
	add_line("")
	add_line(centered("q / Esc  close", width), "Comment")
	return lines, marks
end

local function define_highlights()
	local links = {
		OpenCodeStatsInactive = "Comment",
		OpenCodeStatsLevel1 = "DiagnosticInfo",
		OpenCodeStatsLevel2 = "Identifier",
		OpenCodeStatsLevel3 = "String",
		OpenCodeStatsLevel4 = "DiagnosticOk",
	}
	for name, link in pairs(links) do
		vim.api.nvim_set_hl(0, name, { default = true, link = link })
	end
end

local function dimensions(view)
	local width = math.max(10, math.min(96, vim.o.columns - 6))
	local lines = M.render(view, width)
	local height = math.max(1, math.min(#lines, vim.o.lines - 4))
	local row = math.max(0, math.floor((vim.o.lines - height) / 2))
	local col = math.max(0, math.floor((vim.o.columns - width) / 2))
	return width, height, row, col
end

function M.close()
	local current = active_popup
	if not current then return end
	active_popup = nil
	if current.resize_autocmd then pcall(vim.api.nvim_del_autocmd, current.resize_autocmd) end
	if current.close_autocmd then pcall(vim.api.nvim_del_autocmd, current.close_autocmd) end
	pcall(function() current.popup:unmount() end)
end

--- Show the normalized usage report in a centered, scrollable popup.
--- @param view table
function M.show(view)
	M.close()
	view = view or {}
	define_highlights()
	local width, height = dimensions(view)
	local float = require("opencode.ui.float")
	local popup, bufnr = float.create_centered_popup({
		width = width, height = height, title = "Usage Statistics",
	})
	popup:mount()
	local current = { popup = popup, bufnr = bufnr, view = view }
	active_popup = current
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].filetype = "opencode_stats"
	vim.wo[popup.winid].wrap = false
	local namespace = vim.api.nvim_create_namespace("opencode_stats")

	local function redraw(content_width)
		if active_popup ~= current or not vim.api.nvim_buf_is_valid(bufnr) then return end
		local lines, marks = M.render(view, content_width)
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
		for _, mark in ipairs(marks) do
			vim.api.nvim_buf_set_extmark(bufnr, namespace, mark.line, mark.col, {
				end_col = mark.end_col, hl_group = mark.group,
			})
		end
		vim.bo[bufnr].modifiable = false
	end
	redraw(width)
	float.setup_close_keymaps(bufnr, M.close)
	current.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
		callback = function()
			if active_popup ~= current then return end
			local next_width, next_height, row, col = dimensions(view)
			popup:update_layout({
				position = { row = row, col = col },
				size = { width = next_width, height = next_height },
			})
			redraw(next_width)
		end,
	})
	current.close_autocmd = vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(popup.winid),
		callback = function()
			if active_popup == current then M.close() end
		end,
	})
	return popup
end

return M
