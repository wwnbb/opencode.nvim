local M = {}

local Popup = require("nui.popup")

local state = require("opencode.ui.chat.state").state

function M.show(config)
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "NormalFloat", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBorder", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputInfo", { link = "Comment", default = true })

	config = config or state.config

	local todo_toggle = config
		and config.todo
		and config.todo.keymaps
		and config.todo.keymaps.toggle
		or "T"
	local close_session_key = config
		and config.keymaps
		and config.keymaps.close_session
		or "x"

	local lines = {
		"Chat Buffer Keymaps",
		"",
		"q          Close chat",
		"i          Focus input",
		"a          Toggle auto-scroll",
		"<C-c>      Stop generation",
		"<C-p>      Command palette",
		"N          Start new session",
		string.format("%-10s Close current session tab", close_session_key),
		"gt         Next session",
		"Ngt        Go to session N",
		"0gt        Go to first session",
		"gT         Previous session",
		"<C-u>      Scroll up",
		"<C-d>      Scroll down",
		"gg         Go to top",
		"G          Go to bottom",
		"?          Show this help",
		"",
		"Input Mode",
		"<C-g>      Send message",
		"<C-v>      Paste clipboard",
		"<Esc>      Cancel",
		"↑/↓        Navigate history",
		"<C-s>      Stash input",
		"<C-r>      Restore input",
		"",
		"Tool Calls",
		"O          Toggle task expand (tool I/O in subagent view only)",
		"<CR>       Toggle details",
		"gd         Enter subagent output",
		"<BS>       Go back to parent",
		"gD         View diff",
		"",
		"Todos",
		string.format("%-10s Toggle todo window", todo_toggle),
		"",
		"Question Tool",
		"1-9        Select option by number",
		"↑/↓ j/k    Move cursor (selection follows)",
		"Space      Toggle multi-select",
		"c          Custom input",
		"<CR>       Confirm selection",
		"<Esc>      Cancel question",
		"<Tab>      Next question tab",
		"<S-Tab>    Previous question tab",
		"",
		"Permissions",
		"1-3        Select option by number",
		"↑/↓ j/k    Move cursor (selection follows)",
		"<CR>       Confirm permission",
		"<Esc>      Reject permission",
		"",
		"Edit Review",
		"<C-a>      Accept selected file",
		"<C-x>      Reject selected file",
		"<C-m>      Resolve file manually",
		"=          Toggle inline diff",
		"dt         Open diff in new tab",
		"dv         Open diff vsplit",
		"A          Accept all files",
		"X          Reject all files",
		"M          Resolve all manually",
		"<CR>       Open file in editor",
		"1-9        Jump to file N",
		"",
		"Press any key to close",
	}

	local width = 42
	local height = #lines

	local chat_winid = vim.api.nvim_get_current_win()
	local chat_pos = vim.api.nvim_win_get_position(chat_winid)
	local chat_win_width = vim.api.nvim_win_get_width(chat_winid)
	local chat_win_height = vim.api.nvim_win_get_height(chat_winid)

	local row = chat_pos[1] + math.floor((chat_win_height - height) / 2)
	local col = chat_pos[2] + math.floor((chat_win_width - width) / 2)

	local popup = Popup({
		enter = true,
		focusable = true,
		border = { style = { "", "", "", "", "", "", "", "┃" } },
		position = { row = row, col = col },
		size = { width = width - 1, height = height },
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg,FloatBorder:OpenCodeInputBorder",
		},
	})

	popup:mount()
	vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
	vim.bo[popup.bufnr].modifiable = false

	local ns = vim.api.nvim_create_namespace("opencode_help")
	local section_headers = {
		["Chat Buffer Keymaps"] = true,
		["Input Mode"] = true,
		["Tool Calls"] = true,
		["Todos"] = true,
		["Question Tool"] = true,
		["Permissions"] = true,
		["Edit Review"] = true,
	}
	for i, line in ipairs(lines) do
		if section_headers[line] then
			vim.api.nvim_buf_set_extmark(
				popup.bufnr,
				ns,
				i - 1,
				0,
				{ end_col = #line, hl_group = "OpenCodeInputBorder" }
			)
		elseif line == "Press any key to close" then
			vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, 0, { end_col = #line, hl_group = "OpenCodeInputInfo" })
		elseif line ~= "" then
			local key_end = line:find("  ")
			if key_end then
				vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, 0, { end_col = key_end - 1, hl_group = "Normal" })
				vim.api.nvim_buf_set_extmark(
					popup.bufnr,
					ns,
					i - 1,
					key_end - 1,
					{ end_col = #line, hl_group = "OpenCodeInputInfo" }
				)
			end
		end
	end

	local close_keys = { "q", "<Esc>", "<CR>", "<Space>" }
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, function()
			popup:unmount()
		end, { buffer = popup.bufnr, noremap = true, silent = true })
	end

	for i = 32, 126 do
		local char = string.char(i)
		if not char:match("[qQ]") then
			pcall(function()
				vim.keymap.set("n", char, function()
					popup:unmount()
				end, { buffer = popup.bufnr, noremap = true, silent = true, nowait = true })
			end)
		end
	end

	return popup
end

return M
