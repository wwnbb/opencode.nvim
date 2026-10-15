local M = {}
local keymaps = require("opencode.util.keymap")

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
	local function key(name) return keymaps.label("chat", name, config.keymaps) end
	local function input_key(name) return keymaps.label("input", name) end
	local function numbers(first, last) return keymaps.number_labels("chat", first, last, config.keymaps) end
	local configured = keymaps.get("chat", config.keymaps)
	local confirm_keys, overlapping = keymaps.keys(configured.confirm), 0
	for _, lhs in ipairs(confirm_keys) do
		if keymaps.matches(configured.resolve_edit, lhs) then overlapping = overlapping + 1 end
	end
	local edit_confirm = overlapping == 0 and "Open file in editor"
		or (overlapping == #confirm_keys and "Resolve file manually (shared key)" or "Open file; shared resolve key resolves")
	local pending = {}
	for _, command in ipairs(require("opencode.ui.chat.pending_inputs").commands) do
		table.insert(pending, { key(command.name .. "_pending"), command.description })
	end
	return {
		{
			"Chat",
			{
				{ key("close"), "Close chat" },
				{ key("focus_input"), "Focus input" },
				{ key("toggle_auto_scroll"), "Toggle auto-scroll" },
				{ key("abort"), "Stop generation" },
				{ key("command_palette"), "Command palette" },
				{ key("help"), "Show this help" },
			},
		},
		{
			"Sessions",
			{
				{ key("new_session"), "Start new session" },
				{ key("close_session"), "Close current session tab" },
				{ key("next_session"), "Next session" },
				{ "N + " .. key("next_session"), "Go to session N" },
				{ key("select_0") .. " + " .. key("next_session"), "Go to first session" },
				{ key("prev_session"), "Previous session" },
			},
		},
		{
			"Navigation",
			{
				{ key("scroll_up"), "Scroll up" },
				{ key("scroll_down"), "Scroll down" },
				{ key("goto_top"), "Go to top" },
				{ key("goto_bottom"), "Go to bottom" },
				{ key("prev_user_message") .. " / " .. key("next_user_message"), "Prev/next user message" },
				{ key("prev_message") .. " / " .. key("next_message"), "Prev/next message or widget" },
				{ key("prev_permission") .. " / " .. key("next_permission"), "Prev/next pending permission" },
				{ key("timeline"), "Choose a historical user turn" },
				{ key("message_actions"), "Actions for user message at cursor" },
			},
		},
		{ "Pending Input", pending },
		{
			"Input Mode",
			{
				{ input_key("send"), "Send to queue" },
				{ input_key("send_steer"), "Steer active agent" },
				{ input_key("cancel"), "Cancel" },
				{ input_key("history_prev") .. " / " .. input_key("history_next"), "Navigate history" },
				{ input_key("history_search"), "Search prompt history in input" },
			},
		},
		{
			"Tool Calls",
			{
				{ key("toggle_tool"), "Expand/collapse tool or activity" },
				{ key("confirm"), "Expand/collapse Thought or Explore" },
				{ key("confirm"), "Execute: expand group/call or inspect MCP calls" },
				{ table.concat({ keymaps.label("execute_details", "result"), keymaps.label("execute_details", "raw"),
					keymaps.label("execute_details", "code"), keymaps.label("execute_details", "calls") }, " / "),
					"Execute details: Result / Raw / Code / Calls" },
				{ key("enter_subagent"), "Enter subagent output" },
				{ key("leave_subagent"), "Go back to parent" },
			},
		},
		{
			"Question Tool",
			{
				{ numbers(1, 9), "Select option by number" },
				{ key("widget_prev") .. " / " .. key("widget_next"), "Move cursor (selection follows)" },
				{ key("toggle_selection"), "Toggle multi-select" },
				{ key("custom_input"), "Custom input" },
				{ key("confirm"), "Confirm selection" },
				{ key("cancel_question"), "Cancel question (with confirmation)" },
				{ key("back"), "Return from confirmation to answers" },
				{ key("next_question"), "Next question tab" },
				{ key("prev_question"), "Previous question tab" },
			},
		},
		{
			"Permissions",
			{
				{ numbers(1, 3), "Select option by number" },
				{ key("widget_prev") .. " / " .. key("widget_next"), "Move cursor (selection follows)" },
				{ key("confirm"), "Confirm permission" },
				{ key("back"), "Reject permission" },
			},
		},
		{
			"Edit Review",
			{
				{ key("accept_edit"), "Accept selected file" },
				{ key("reject_edit"), "Reject selected file" },
				{ key("resolve_edit"), "Resolve file manually" },
				{ key("toggle_diff"), "Toggle inline diff" },
				{ key("diff_tab"), "Open diff in new tab" },
				{ key("diff_split"), "Open diff vsplit" },
				{ key("accept_all_edits"), "Accept all files" },
				{ key("reject_all_edits"), "Reject all files" },
				{ key("resolve_all_edits"), "Resolve all manually" },
				{ key("confirm"), edit_confirm },
				{ numbers(1, 9), "Jump to file N" },
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
	local border_width, border_height = Popup.outer_insets()
	if vim.o.lines - vim.o.cmdheight < 8 + border_height or vim.o.columns < 12 + border_width then
		vim.notify("Not enough room to show OpenCode help", vim.log.levels.WARN)
		return
	end
	if active_popup then
		if active_popup.winid and vim.api.nvim_win_is_valid(active_popup.winid)
			and vim.api.nvim_win_get_tabpage(active_popup.winid) == vim.api.nvim_get_current_tabpage() then
			vim.api.nvim_set_current_win(active_popup.winid)
			return active_popup
		end
		active_popup:close(false)
	end
	config = config or state.config or require("opencode.config").defaults.chat
	local groups = sections(config)
	local target_win = require("opencode.ui.float_context").get_chat_context()
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
		local width = math.max(12, math.min(76, anchor_width - 4, screen_width - border_width))
		local height = math.max(8, math.min(32, anchor_height - 4, screen_height - border_height))
		local outer_width, outer_height = width + border_width, height + border_height
		local row = math.max(0, math.min(pos[1] + math.floor((anchor_height - outer_height) / 2), screen_height - outer_height))
		local col = math.max(0, math.min(pos[2] + math.floor((anchor_width - outer_width) / 2), screen_width - outer_width))
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
				position = { row = 3, col = 1 },
				size = { width = next_width - 2, height = next_height - 6 },
			},
		})
		local inset = next_width >= 20 and 4 or 1
		local padding = string.rep(" ", inset)
		local lines = { "", padding .. "Help" }
		for _ = 3, next_height do
			table.insert(lines, "")
		end
		local footer = keymaps.label("help", "close") .. " close"
		local navigation = keymaps.label("help", "up") .. " / " .. keymaps.label("help", "down") .. " scroll"
		if vim.fn.strdisplaywidth(footer .. "   " .. navigation) <= next_width - 2 * inset then
			footer = footer .. "   " .. navigation
		end
		lines[next_height - 1] = padding .. wrap(footer, next_width - 2 * inset)[1]
		popup:render(lines, {
			{ row = 1, col = inset, opts = { end_col = inset + 4, hl_group = "OpenCodeInputBorder" } },
			{
				row = next_height - 2, col = inset,
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
			zindex = 81,
			border = "none",
			position = { row = 3, col = 1 },
			size = { width = width - 2, height = height - 6 },
			buf_options = { filetype = "opencode_help" },
			win_options = win_options,
		},
		focus_restore = "previous",
		close_on_leave = true,
		on_close = function() active_popup = nil end,
		on_resize = function()
			if vim.o.lines - vim.o.cmdheight < 8 + border_height or vim.o.columns < 12 + border_width then
				popup:close()
			else
				redraw()
			end
		end,
	})
	popup:mount()
	active_popup = popup
	local map, apply = keymaps.mapper("help", popup.bufnr)
	map("n", "close", function() popup:close() end)
	for action, movement in pairs({ down = "j", up = "k", half_page_up = "<C-u>", half_page_down = "<C-d>",
		page_up = "<C-b>", page_down = "<C-f>", top = "gg", bottom = "G" }) do
		map("n", action, movement)
	end
	apply()
	redraw()

	return popup
end

return M
