-- Usage statistics display. The caller supplies a normalized view model:
-- { total_tokens, sessions, daily = { ["YYYY-MM-DD"] = steps },
--   active_days?, best_streak?, start_date?, end_date? }

local M = {}

local active_popup
local calendar = require("opencode.ui.stats_calendar")

local logo = {
	left = {
		"                   ",
		"█▀▀█ █▀▀█ █▀▀█ █▀▀▄",
		"█__█ █__█ █^^^ █__█",
		"▀▀▀▀ █▀▀▀ ▀▀▀▀ ▀~~▀",
	},
	right = {
		"             ▄     ",
		"█▀▀▀ █▀▀█ █▀▀█ █▀▀█",
		"█___ █__█ █__█ █^^^",
		"▀▀▀▀ ▀▀▀▀ ▀▀▀▀ ▀▀▀▀",
	},
}

local glyphs = {
	["0"] = { "111", "101", "101", "101", "111" },
	["1"] = { "010", "110", "010", "010", "111" },
	["2"] = { "111", "001", "111", "100", "111" },
	["3"] = { "111", "001", "111", "001", "111" },
	["4"] = { "101", "101", "111", "001", "001" },
	["5"] = { "111", "100", "111", "001", "111" },
	["6"] = { "111", "100", "111", "101", "111" },
	["7"] = { "111", "001", "010", "010", "010" },
	["8"] = { "111", "101", "111", "101", "111" },
	["9"] = { "111", "101", "111", "001", "111" },
	["."] = { "0", "0", "0", "0", "1" },
	["K"] = { "101", "110", "100", "110", "101" },
	["M"] = { "10001", "11011", "10101", "10001", "10001" },
	["B"] = { "110", "101", "110", "101", "110" },
	["T"] = { "111", "010", "010", "010", "010" },
}

local function count(value)
	return math.max(0, math.floor(tonumber(value) or 0))
end

local function format_compact(value)
	local number = count(value)
	if number < 1000 then return tostring(number) end
	local units = { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }
	for index, unit in ipairs(units) do
		if number >= unit[1] then
			local amount = tonumber(string.format("%.1f", number / unit[1]))
			if amount >= 1000 and index > 1 then
				unit = units[index - 1]
				amount = tonumber(string.format("%.1f", number / unit[1]))
			end
			return tostring(amount):gsub("%.0$", "") .. unit[2]
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

local function clipped(text, width)
	if vim.fn.strdisplaywidth(text) <= width then return text end
	local chars = vim.fn.split(text, "\\zs")
	local result, used = {}, 0
	for _, char in ipairs(chars) do
		local char_width = vim.fn.strdisplaywidth(char)
		if used + char_width > width then break end
		result[#result + 1], used = char, used + char_width
	end
	return table.concat(result)
end

local function date_epoch(date)
	if type(date) ~= "string" then return nil end
	local year, month, day = date:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if not year then return nil end
	local epoch = os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
	if not epoch or os.date("%Y-%m-%d", epoch) ~= date then return nil end
	return epoch
end

local function date_range(view)
	local first, last = date_epoch(view.start_date), date_epoch(view.end_date)
	if not first or not last then return nil end
	if os.date("%Y-%m", first) == os.date("%Y-%m", last) then
		return os.date("%b %Y", last)
	end
	if os.date("%Y", first) == os.date("%Y", last) then
		return os.date("%b", first) .. " – " .. os.date("%b %Y", last)
	end
	return os.date("%b %Y", first) .. " – " .. os.date("%b %Y", last)
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

local function pixel_art(value)
	local rows = { "", "", "", "", "" }
	for index = 1, #value do
		local glyph = glyphs[value:sub(index, index)]
		if not glyph then return nil end
		for row = 1, 5 do
			local blocks = glyph[row]:gsub("1", "██"):gsub("0", "  ")
			rows[row] = rows[row] .. (index > 1 and "  " or "") .. blocks
		end
	end
	return rows
end

local function logo_rows(width)
	local rows = {}
	if width >= 44 then
		for row = 1, 4 do
			rows[#rows + 1] = { { logo.left[row], false }, { " ", false }, { logo.right[row], true } }
		end
	elseif width >= 22 then
		for row = 2, 4 do rows[#rows + 1] = { { logo.left[row], false } } end
		for row = 1, 4 do rows[#rows + 1] = { { logo.right[row], true } } end
	else
		for row = 2, 4 do rows[#rows + 1] = { { logo.right[row], true } } end
	end
	return rows
end

--- Render a usage report for a given content width. Marks use zero-based line
--- and byte columns, ready for nvim_buf_set_extmark.
--- @param view table
--- @param width number
--- @param opts? { height?: number }
--- @return string[], table[]
function M.render(view, width, opts)
	view = view or {}
	opts = opts or {}
	width = math.max(1, math.floor(tonumber(width) or 60))
	local height = tonumber(opts.height) or 50
	local gap = height < 38 and 1 or 2
	local lines, marks = {}, {}
	local function add_line(text, group)
		text = clipped(text or "", width)
		table.insert(lines, text)
		if group and text ~= "" then
			table.insert(marks, { line = #lines - 1, col = 0, end_col = #text, group = group })
		end
	end
	local function add_mark(line, col, length, group)
		local text = lines[line + 1]
		if not text or col >= #text or length <= 0 then return end
		marks[#marks + 1] = { line = line, col = col, end_col = math.min(#text, col + length), group = group }
	end
	local function add_gap()
		for _ = 1, gap do add_line("") end
	end

	local heading, range = "opencode / stats", date_range(view)
	if width >= 44 and range and vim.fn.strdisplaywidth(heading) + vim.fn.strdisplaywidth(range) + 2 <= width then
		local spaces = string.rep(" ", width - vim.fn.strdisplaywidth(heading) - vim.fn.strdisplaywidth(range))
		add_line(heading .. spaces .. range)
		add_mark(#lines - 1, 0, #heading, "OpenCodeStatsText")
		add_mark(#lines - 1, #heading + #spaces, #range, "OpenCodeStatsMuted")
	else
		add_line(heading, "OpenCodeStatsText")
		if range then add_line(range, "OpenCodeStatsMuted") end
	end
	if height >= 38 and width >= 19 then
		add_gap()
		for _, sections in ipairs(logo_rows(width)) do
			local raw = ""
			for _, section in ipairs(sections) do raw = raw .. section[1] end
			local pad = string.rep(" ", math.max(0, math.floor((width - vim.fn.strdisplaywidth(raw)) / 2)))
			local rendered, logo_marks = pad, {}
			for _, section in ipairs(sections) do
				local normal = section[2] and "OpenCodeStatsLogoMain" or "OpenCodeStatsLogoMuted"
				local shadow = section[2] and "OpenCodeStatsLogoMainShadow" or "OpenCodeStatsLogoMutedShadow"
				local shadow_bg = section[2] and "OpenCodeStatsLogoMainShadowBg" or "OpenCodeStatsLogoMutedShadowBg"
				for _, char in ipairs(vim.fn.split(section[1], "\\zs")) do
					local glyph, group = char, normal
					if char == "_" then glyph, group = " ", shadow_bg end
					if char == "^" then glyph, group = "▀", shadow_bg end
					if char == "~" then glyph, group = "▀", shadow end
					if char == "," then glyph, group = "▄", shadow end
					if char == " " then group = nil end
					if group then logo_marks[#logo_marks + 1] = { #rendered, #glyph, group } end
					rendered = rendered .. glyph
				end
			end
			add_line(rendered)
			for _, mark in ipairs(logo_marks) do add_mark(#lines - 1, mark[1], mark[2], mark[3]) end
		end
	end
	add_gap()
	local token_text = format_compact(view.total_tokens)
	local art = pixel_art(token_text)
	if art and vim.fn.strdisplaywidth(art[1]) <= width then
		for _, row in ipairs(art) do add_line(centered(row, width), "OpenCodeStatsNumber") end
	else
		add_line(centered(token_text, width), "OpenCodeStatsNumber")
	end
	add_line("")
	add_line(centered("TOKENS", width), "OpenCodeStatsMuted")
	add_gap()
	local calendar_lines, calendar_marks = calendar.render(view, width)
	local calendar_start = #lines
	for _, line in ipairs(calendar_lines) do add_line(line) end
	for _, mark in ipairs(calendar_marks) do
		add_mark(calendar_start + mark.line, mark.col, mark.end_col - mark.col, mark.group)
	end
	add_gap()
	local active_days, best_streak = derived_activity(view.daily)
	active_days = count(view.active_days or active_days)
	best_streak = count(view.best_streak or best_streak)
	local summary = {
		{ "best streak", format_compact(best_streak) .. " days" },
		{ "active days", format_compact(active_days) },
		{ "sessions", format_compact(view.sessions) },
	}
	if width >= 54 then
		local item_widths, total = {}, 0
		for index, item in ipairs(summary) do
			item_widths[index] = math.max(vim.fn.strdisplaywidth(item[1]), vim.fn.strdisplaywidth(item[2]))
			total = total + item_widths[index]
		end
		local free = math.max(0, width - total)
		local labels, values = string.rep(" ", width), string.rep(" ", width)
		local cursor = free / 6
		for index, item in ipairs(summary) do
			local start = math.floor(cursor + 0.5)
			local item_width = item_widths[index]
			local value = centered_cell(item[2], item_width)
			local label = centered_cell(item[1], item_width)
			values = values:sub(1, start) .. value .. values:sub(start + #value + 1)
			labels = labels:sub(1, start) .. label .. labels:sub(start + #label + 1)
			cursor = cursor + item_width + free / 3
		end
		add_line(values:gsub("%s+$", ""), "OpenCodeStatsValue")
		add_line(labels:gsub("%s+$", ""), "OpenCodeStatsMuted")
	else
		for _, item in ipairs(summary) do
			add_line(centered(item[2] .. "  " .. item[1], width), "OpenCodeStatsValue")
		end
	end
	add_gap()
	local footer = "opencode.ai"
	add_line(string.rep(" ", math.max(0, width - #footer)) .. footer, "OpenCodeStatsText")
	return lines, marks
end

local function color_parts(color)
	return math.floor(color / 65536) % 256, math.floor(color / 256) % 256, color % 256
end

local function blend(background, foreground, alpha)
	local br, bg, bb = color_parts(background)
	local fr, fg, fb = color_parts(foreground)
	return math.floor(br + (fr - br) * alpha + 0.5) * 65536
		+ math.floor(bg + (fg - bg) * alpha + 0.5) * 256
		+ math.floor(bb + (fb - bb) * alpha + 0.5)
end

local function define_highlights()
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	local comment = vim.api.nvim_get_hl(0, { name = "Comment", link = false })
	local light = vim.o.background == "light"
	local background = normal.bg or (light and 0xfdf6e3 or 0x002b36)
	local primary = normal.fg or (light and 0x657b83 or 0x93a1a1)
	local muted = comment.fg or blend(background, primary, 0.65)
	local blue = light and 0x268bd2 or 0x268bd2
	local set = function(name, opts) vim.api.nvim_set_hl(0, name, opts) end
	set("OpenCodeStatsBackground", { fg = primary, bg = background })
	set("OpenCodeStatsText", { fg = primary, bg = background, bold = true, italic = false })
	set("OpenCodeStatsMuted", { fg = muted, bg = background, italic = false })
	set("OpenCodeStatsValue", { fg = primary, bg = background, bold = true, italic = false })
	set("OpenCodeStatsNumber", { fg = primary, bg = background, bold = true, italic = false })
	set("OpenCodeStatsLogoMain", { fg = primary, bg = background, bold = true, italic = false })
	set("OpenCodeStatsLogoMuted", { fg = muted, bg = background, bold = true, italic = false })
	set("OpenCodeStatsLogoMainShadow", { fg = blend(background, primary, 0.25), bg = background, bold = true })
	set("OpenCodeStatsLogoMutedShadow", { fg = blend(background, muted, 0.25), bg = background })
	set("OpenCodeStatsLogoMainShadowBg", { fg = primary, bg = blend(background, primary, 0.25), bold = true })
	set("OpenCodeStatsLogoMutedShadowBg", { fg = muted, bg = blend(background, muted, 0.25) })
	set("OpenCodeStatsInactive", { fg = muted, bg = background })
	for level, alpha in ipairs({ 0.3, 0.5, 0.75, 1 }) do
		set("OpenCodeStatsLevel" .. level, { fg = blend(background, blue, alpha), bg = background })
	end
end

local function dimensions()
	return math.max(1, vim.o.columns), math.max(1, vim.o.lines - vim.o.cmdheight)
end

local function page(view, width, height)
	local content_width = math.max(1, math.min(110, width - 8))
	local content, marks = M.render(view, content_width, { height = height })
	local left = math.max(0, math.floor((width - content_width) / 2))
	local top = math.max(0, math.floor((height - #content) / 2))
	local lines = {}
	for _ = 1, math.max(height, top + #content) do lines[#lines + 1] = "" end
	local prefix = string.rep(" ", left)
	for index, line in ipairs(content) do lines[top + index] = prefix .. line end
	for _, mark in ipairs(marks) do
		mark.line = mark.line + top
		mark.col = mark.col + left
		mark.end_col = mark.end_col + left
	end
	return lines, marks
end

function M.close()
	local current = active_popup
	if not current then return end
	active_popup = nil
	if current.resize_autocmd then pcall(vim.api.nvim_del_autocmd, current.resize_autocmd) end
	if current.close_autocmd then pcall(vim.api.nvim_del_autocmd, current.close_autocmd) end
	pcall(function() current.popup:unmount() end)
	if current.previous_win and vim.api.nvim_win_is_valid(current.previous_win)
		and vim.api.nvim_win_get_tabpage(current.previous_win) == vim.api.nvim_get_current_tabpage() then
		pcall(vim.api.nvim_set_current_win, current.previous_win)
	end
end

--- Show the normalized usage report over the full Neovim screen.
--- @param view table
function M.show(view)
	M.close()
	view = view or {}
	define_highlights()
	local width, height = dimensions()
	local previous_win = vim.api.nvim_get_current_win()
	local popup = require("nui.popup")({
		relative = "editor",
		position = { row = 0, col = 0 },
		size = { width = width, height = height },
		border = "none",
		zindex = 150,
		enter = true,
		focusable = true,
		buf_options = {
			buftype = "nofile",
			bufhidden = "wipe",
			swapfile = false,
			filetype = "opencode_stats",
		},
		win_options = {
			winblend = 0,
			winhighlight = "Normal:OpenCodeStatsBackground,NormalNC:OpenCodeStatsBackground,EndOfBuffer:OpenCodeStatsBackground,Cursor:OpenCodeHiddenCursor,lCursor:OpenCodeHiddenCursor",
			fillchars = "eob: ",
			wrap = false,
			number = false,
			relativenumber = false,
			signcolumn = "no",
			cursorline = false,
			scrolloff = 0,
		},
	})
	popup:mount()
	local bufnr = popup.bufnr
	local current = { popup = popup, bufnr = bufnr, view = view, previous_win = previous_win }
	active_popup = current
	local namespace = vim.api.nvim_create_namespace("opencode_stats")

	local function redraw(screen_width, screen_height)
		if active_popup ~= current or not vim.api.nvim_buf_is_valid(bufnr) then return end
		local lines, marks = page(view, screen_width, screen_height)
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
		for _, mark in ipairs(marks) do
			vim.api.nvim_buf_set_extmark(bufnr, namespace, mark.line, mark.col, {
				end_col = mark.end_col, hl_group = mark.group,
			})
		end
		vim.bo[bufnr].modifiable = false
		if vim.api.nvim_win_is_valid(popup.winid) then
			vim.api.nvim_win_set_cursor(popup.winid, { #lines <= screen_height and #lines or 1, 0 })
		end
	end
	redraw(width, height)
	require("opencode.ui.float").setup_close_keymaps(bufnr, M.close)
	current.resize_autocmd = vim.api.nvim_create_autocmd("VimResized", {
		callback = function()
			if active_popup ~= current then return end
			local next_width, next_height = dimensions()
			popup:update_layout({
				position = { row = 0, col = 0 },
				size = { width = next_width, height = next_height },
			})
			redraw(next_width, next_height)
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
