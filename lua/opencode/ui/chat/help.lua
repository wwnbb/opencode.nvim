local M = {}

local Popup = require("opencode.ui.popup")
local state = require("opencode.ui.chat.state").state
local highlights = require("opencode.ui.highlights")
local active_popup

highlights.register("opencode.ui.chat.help", function()
	highlights.setup_message_backgrounds()
	vim.api.nvim_set_hl(0, "OpenCodeInputBorder", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputInfo", { link = "Comment", default = true })
end)

local function sections(config)
	local keys = config.keymaps or {}
	local function key(name, fallback)
		local value = keys[name]
		if value == nil then
			return fallback
		end
		return type(value) == "string" and value ~= "" and value or "(disabled)"
	end
	local pending = {}
	for _, command in ipairs(require("opencode.ui.chat.pending_inputs").commands) do
		table.insert(pending, { key(command.name .. "_pending", "(disabled)"), command.description })
	end
	return {
		{
			"Chat",
			{
				{ key("close", "q"), "Close chat" },
				{ key("focus_input", "i"), "Focus input" },
				{ "a", "Toggle auto-scroll" },
				{ key("abort", "<C-c>"), "Stop generation" },
				{ "<C-p>", "Command palette" },
				{ "?", "Show this help" },
			},
		},
		{
			"Sessions",
			{
				{ "N", "Start new session" },
				{ key("close_session", "x"), "Close current session tab" },
				{ "gt", "Next session" },
				{ "Ngt", "Go to session N" },
				{ "0gt", "Go to first session" },
				{ "gT", "Previous session" },
			},
		},
		{
			"Navigation",
			{
				{ key("scroll_up", "<C-u>"), "Scroll up" },
				{ key("scroll_down", "<C-d>"), "Scroll down" },
				{ key("goto_top", "gg"), "Go to top" },
				{ key("goto_bottom", "G"), "Go to bottom" },
				{ "[a / ]a", "Prev/next user message" },
				{ "[m / ]m", "Prev/next message or widget" },
				{ "[p / ]p", "Prev/next pending permission" },
			},
		},
		{ "Pending Input", pending },
		{
			"Input Mode",
			{
				{ "<C-g>", "Send message" },
				{ "<Esc>", "Cancel" },
				{ "↑ / ↓", "Navigate history" },
			},
		},
		{
			"Tool Calls",
			{
				{ "O", "Expand/collapse tool or activity" },
				{ "<CR>", "Expand/collapse Thought or Explore" },
				{ "<CR>", "Execute: expand group/call or inspect MCP calls" },
				{ "1-4", "Execute details: Result / Raw / Code / Calls" },
				{ "gd", "Enter subagent output" },
				{ "<BS>", "Go back to parent" },
				{ "gD", "View diff" },
			},
		},
		{
			"Question Tool",
			{
				{ "1-9", "Select option by number" },
				{ "↑/↓ j/k", "Move cursor (selection follows)" },
				{ "Space", "Toggle multi-select" },
				{ "c", "Custom input" },
				{ "<CR>", "Confirm selection" },
				{ "<Esc>", "Cancel question" },
				{ "<Tab>", "Next question tab" },
				{ "<S-Tab>", "Previous question tab" },
			},
		},
		{
			"Permissions",
			{
				{ "1-3", "Select option by number" },
				{ "↑/↓ j/k", "Move cursor (selection follows)" },
				{ "<CR>", "Confirm permission" },
				{ "<Esc>", "Reject permission" },
			},
		},
		{
			"Edit Review",
			{
				{ "<C-a>", "Accept selected file" },
				{ "<C-x>", "Reject selected file" },
				{ "<C-m>", "Resolve file manually" },
				{ "=", "Toggle inline diff" },
				{ "dt", "Open diff in new tab" },
				{ "dv", "Open diff vsplit" },
				{ "A", "Accept all files" },
				{ "X", "Reject all files" },
				{ "M", "Resolve all manually" },
				{ "<CR>", "Open file in editor" },
				{ "1-9", "Jump to file N" },
			},
		},
	}
end

-- Wrap by display cells while keeping UTF-8 characters intact and descriptions
-- in their own column, including continuations on narrow screens.
local function wrap(text, width)
	local result = {}
	while vim.fn.strdisplaywidth(text) > width do
		local count = 0
		for i = 1, vim.fn.strchars(text) do
			if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, i)) > width then
				break
			end
			count = i
		end
		count = math.max(1, count)
		local chunk = vim.fn.strcharpart(text, 0, count)
		local space = chunk:match("^.*()%s")
		if space and space > 1 then
			table.insert(result, vim.trim(chunk:sub(1, space - 1)))
			text = vim.trim(text:sub(space + 1))
		else
			table.insert(result, chunk)
			text = vim.trim(vim.fn.strcharpart(text, count))
		end
	end
	table.insert(result, text)
	return result
end

local function content_lines(groups, width)
	local lines, marks = {}, {}
	local key_width = math.min(14, math.max(1, math.floor(width / 3)))
	local description_width = math.max(1, width - key_width - 2)
	for index, group in ipairs(groups) do
		if index > 1 then
			table.insert(lines, "")
		end
		for _, title in ipairs(wrap(group[1], width)) do
			table.insert(lines, "   " .. title)
			table.insert(marks, { #lines - 1, 3, #lines[#lines], "OpenCodeInputBorder" })
		end
		for _, entry in ipairs(group[2]) do
			local key_lines, description_lines = wrap(entry[1], key_width), wrap(entry[2], description_width)
			for i = 1, math.max(#key_lines, #description_lines) do
				local key_text, description = key_lines[i] or "", description_lines[i] or ""
				local left = "   " .. key_text .. string.rep(" ", key_width - vim.fn.strdisplaywidth(key_text) + 2)
				table.insert(lines, left .. description)
				table.insert(marks, { #lines - 1, 3, 3 + #key_text, "Normal" })
				table.insert(marks, { #lines - 1, #left, #lines[#lines], "OpenCodeInputInfo" })
			end
		end
	end
	local highlights = {}
	for _, mark in ipairs(marks) do
		highlights[#highlights + 1] = {
			row = mark[1], col = mark[2], opts = { end_col = mark[3], hl_group = mark[4] },
		}
	end
	return lines, highlights
end

function M.show(config)
	if vim.o.lines - vim.o.cmdheight < 8 then
		vim.notify("Not enough room to show OpenCode help", vim.log.levels.WARN)
		return
	end
	if active_popup and active_popup.winid and vim.api.nvim_win_is_valid(active_popup.winid) then
		vim.api.nvim_set_current_win(active_popup.winid)
		return active_popup
	end
	config = config or state.config or require("opencode.config").defaults.chat
	local groups = sections(config)
	local previous_win = vim.api.nvim_get_current_win()
	local target_win = state.winid and vim.api.nvim_win_is_valid(state.winid) and state.winid or previous_win
	local function dimensions()
		local screen_width, screen_height = vim.o.columns, vim.o.lines - vim.o.cmdheight
		local pos, anchor_width, anchor_height = { 0, 0 }, screen_width, screen_height
		if vim.api.nvim_win_is_valid(target_win) then
			pos = vim.api.nvim_win_get_position(target_win)
			anchor_width, anchor_height =
				vim.api.nvim_win_get_width(target_win), vim.api.nvim_win_get_height(target_win)
		end
		if anchor_width < 28 or anchor_height < 12 then
			pos, anchor_width, anchor_height = { 0, 0 }, screen_width, screen_height
		end
		local width = math.max(12, math.min(76, anchor_width - 4, screen_width - 2))
		local height = math.max(8, math.min(32, anchor_height - 4, screen_height - 2))
		local row = math.max(0, math.min(pos[1] + math.floor((anchor_height - height) / 2), screen_height - height))
		local col = math.max(0, math.min(pos[2] + math.floor((anchor_width - width) / 2), screen_width - width))
		return width, height, row, col
	end
	local width, height, row, col = dimensions()
	local win_options = {
		winhighlight = "Normal:OpenCodeInputBg,NormalNC:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg",
		wrap = false,
		cursorline = false,
		winblend = 0,
		scrolloff = 0,
	}
	local popup
	local function redraw()
		local next_width, next_height, next_row, next_col = dimensions()
		popup:resize({
			frame = {
				position = { row = next_row, col = next_col },
				size = { width = next_width, height = next_height },
			},
			content = {
				position = { row = next_row + 3, col = next_col + 1 },
				size = { width = next_width - 2, height = next_height - 6 },
			},
		})
		local inset = next_width >= 20 and 4 or 1
		local padding = string.rep(" ", inset)
		local lines = { "", padding .. "Help" .. string.rep(" ", next_width - 7 - 2 * inset) .. "esc" .. padding }
		for _ = 3, next_height do
			table.insert(lines, "")
		end
		local footer = next_width >= 54 and "j/k scroll   Ctrl-u/d page   q/esc close"
			or (next_width >= 30 and "j/k scroll  q/esc close" or "q close")
		lines[next_height - 1] = "    " .. footer
		popup:render(lines, {
			{ row = 1, col = inset, opts = { end_col = inset + 4, hl_group = "OpenCodeInputBorder" } },
			{ row = 1, col = next_width - 7, opts = { end_col = next_width - 4, hl_group = "OpenCodeInputInfo" } },
			{
				row = next_height - 2, col = 4,
				opts = { end_col = #lines[next_height - 1], hl_group = "OpenCodeInputInfo" },
			},
		}, "frame")
		local body_lines, body_marks = content_lines(groups, next_width - 8)
		popup:render(body_lines, body_marks)
	end
	popup = Popup.new({
		frame = {
			enter = false,
			focusable = false,
			relative = "editor",
			zindex = 80,
			border = "none",
			position = { row = row, col = col },
			size = { width = width, height = height },
			buf_options = { filetype = "opencode_help" },
			win_options = win_options,
		},
		content = {
			enter = true,
			focusable = true,
			relative = "editor",
			zindex = 81,
			border = "none",
			position = { row = row + 3, col = col + 1 },
			size = { width = width - 2, height = height - 6 },
			buf_options = { filetype = "opencode_help" },
			win_options = win_options,
		},
		focus_restore = "previous",
		close_on_leave = true,
		on_close = function() active_popup = nil end,
		on_resize = function()
			if vim.o.lines - vim.o.cmdheight < 8 then
				popup:close()
			else
				redraw()
			end
		end,
	})
	popup:mount()
	active_popup = popup
	redraw()
	for _, key in ipairs({ "q", "<Esc>", "<CR>", "<Space>" }) do
		vim.keymap.set("n", key, function()
			popup:close()
		end, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	-- Keep normal navigation available instead of closing on every printable key.
	for _, key in ipairs({ "j", "k", "<Up>", "<Down>", "<C-u>", "<C-d>", "<C-b>", "<C-f>", "gg", "G" }) do
		vim.keymap.set("n", key, key, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	return popup
end

return M
