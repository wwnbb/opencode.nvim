-- opencode.nvim - Shared float utilities
-- Reusable floating window helpers

local M = {}

local Popup = require("nui.popup")
local hl_ns = vim.api.nvim_create_namespace("opencode_float")

-- Create a centered floating popup with standard styling
function M.create_centered_popup(opts)
	opts = opts or {}

	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }

	local width = opts.width or math.min(60, ui.width - 10)
	local height = opts.height or math.min(20, ui.height - 6)
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

	local popup = Popup({
		enter = opts.enter ~= false,
		focusable = opts.focusable ~= false,
		border = {
			style = opts.border or "rounded",
			text = opts.title and {
				top = " " .. opts.title .. " ",
				top_align = "center",
			} or nil,
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
	})

	return popup, popup.bufnr
end

-- Create a popup at specific position
function M.create_popup_at(position, size, opts)
	opts = opts or {}

	local popup = Popup({
		enter = opts.enter ~= false,
		focusable = opts.focusable ~= false,
		border = {
			style = opts.border or "single",
			text = opts.title and {
				top = " " .. opts.title .. " ",
				top_align = "center",
			} or nil,
		},
		position = position,
		size = size,
	})

	return popup, popup.bufnr
end

-- Setup standard keymaps for a popup (q to close, Esc to close)
function M.setup_close_keymaps(bufnr, close_fn)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	vim.keymap.set("n", "q", close_fn, opts)
	vim.keymap.set("n", "<Esc>", close_fn, opts)
end

-- Create loading spinner popup
function M.show_loading(message, opts)
	opts = opts or {}

	local popup, bufnr = M.create_centered_popup({
		width = opts.width or 40,
		height = 3,
		border = "rounded",
		title = " Loading ",
	})

	popup:mount()

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"",
		"  " .. (message or "Loading..."),
		"",
	})

	vim.bo[bufnr].modifiable = false

	-- Return close function
	return function()
		popup:unmount()
	end
end

-- Show notification popup (auto-closing)
function M.show_notification(message, level, timeout)
	level = level or vim.log.levels.INFO
	timeout = timeout or 3000

	local width = math.min(50, #message + 10)
	local height = 3

	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }

	local row = 1 -- Top of screen
	local col = ui.width - width - 2 -- Right aligned

	local popup = Popup({
		enter = false,
		focusable = false,
		border = "rounded",
		position = { row = row, col = col },
		size = { width = width, height = height },
	})

	popup:mount()

	local bufnr = popup.bufnr
	local hl_group = "Normal"
	if level == vim.log.levels.ERROR then
		hl_group = "ErrorMsg"
	elseif level == vim.log.levels.WARN then
		hl_group = "WarningMsg"
	elseif level == vim.log.levels.INFO then
		hl_group = "MoreMsg"
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"",
		"  " .. message,
		"",
	})

	local msg_text = vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1] or ""
	vim.api.nvim_buf_set_extmark(bufnr, hl_ns, 1, 0, { end_col = #msg_text, hl_group = hl_group })
	vim.bo[bufnr].modifiable = false

	-- Auto close
	vim.defer_fn(function()
		pcall(function()
			popup:unmount()
		end)
	end, timeout)

	return popup
end

-- Create menu/selection popup (basic version for backwards compatibility)
function M.create_menu(items, on_select, opts)
	opts = opts or {}

	local width = opts.width or 40
	local height = math.min(#items + 2, 20)

	local popup, bufnr = M.create_centered_popup({
		width = width,
		height = height,
		border = "rounded",
		title = opts.title or " Select ",
	})

	-- Set content
	local lines = {}
	for i, item in ipairs(items) do
		table.insert(lines, string.format("  %d. %s", i, item.label or item))
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false

	-- Setup keymaps
	local opts_map = { buffer = bufnr, noremap = true, silent = true }

	vim.keymap.set("n", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local idx = cursor[1]
		if items[idx] then
			on_select(items[idx], idx)
			popup:unmount()
		end
	end, opts_map)

	vim.keymap.set("n", "q", function()
		popup:unmount()
	end, opts_map)

	vim.keymap.set("n", "<Esc>", function()
		popup:unmount()
	end, opts_map)

	-- Number shortcuts
	for i = 1, math.min(9, #items) do
		vim.keymap.set("n", tostring(i), function()
			on_select(items[i], i)
			popup:unmount()
		end, opts_map)
	end

	popup:mount()

	return popup
end

-- Helper to get the OpenCode chat window ID
local function get_chat_winid()
	-- Try to get the chat window from the chat module
	local ok, chat = pcall(require, "opencode.ui.chat")
	if ok and chat.get_bufnr then
		local bufnr = chat.get_bufnr()
		if bufnr then
			-- Find window displaying this buffer
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_buf(win) == bufnr then
					return win
				end
			end
		end
	end
	return nil
end

-- Create input popup for text entry (API keys, codes, etc.)
-- opts: { title?, prompt?, on_submit, on_cancel?, width?, password? }
function M.create_input_popup(opts)
	opts = opts or {}

	local NuiInput = require("nui.input")
	local event = require("nui.utils.autocmd").event

	local width = opts.width or 50

	-- Try to get the OpenCode chat window, fall back to current window
	local target_win = get_chat_winid() or vim.api.nvim_get_current_win()

	-- Get target window dimensions for centering
	local win_width = vim.api.nvim_win_get_width(target_win)
	local win_height = vim.api.nvim_win_get_height(target_win)
	local total_width = width + 2 -- border adds 2 to total width
	local row = math.floor((win_height - 3) / 2)
	local col = math.max(0, math.floor((win_width - total_width) / 2))

	local input = NuiInput({
		relative = { type = "win", winid = target_win },
		position = { row = row, col = col },
		size = { width = width },
		border = {
			style = "rounded",
			text = {
				top = opts.title or " Input ",
				top_align = "center",
				bottom = " ⏎:submit  esc:cancel ",
				bottom_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
	}, {
		prompt = opts.prompt and (opts.prompt .. " ") or "> ",
		default_value = opts.default or "",
	})

	input:mount()

	local is_closed = false
	local function close()
		if is_closed then
			return
		end
		is_closed = true
		input:unmount()
	end

	-- Setup keymaps
	local input_bufnr = input.bufnr
	local keymap_opts = { buffer = input_bufnr, noremap = true, silent = true }

	vim.keymap.set("i", "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false)
		local value = lines[1] or ""
		-- Remove prompt prefix if present
		if opts.prompt then
			value = value:gsub("^" .. vim.pesc(opts.prompt) .. "%s*", "")
		end
		value = value:gsub("^>%s*", "")
		close()
		if opts.on_submit then
			opts.on_submit(value)
		end
	end, keymap_opts)

	vim.keymap.set("i", "<Esc>", function()
		close()
		if opts.on_cancel then
			opts.on_cancel()
		end
	end, keymap_opts)

	vim.keymap.set("i", "<C-c>", function()
		close()
		if opts.on_cancel then
			opts.on_cancel()
		end
	end, keymap_opts)

	-- Close on buffer leave
	input:on(event.BufLeave, function()
		vim.defer_fn(close, 100)
	end)

	-- Start in insert mode
	vim.cmd("startinsert!")

	return {
		close = close,
		input = input,
	}
end

-- Create interactive searchable menu with fuzzy filtering
-- items: array of { label, value, description?, group?, priority? }
-- on_select: function(item) called when item is selected
-- on_key: function(key, item) called when a custom key is pressed, return true to keep menu open
-- opts: { title?, width?, placeholder?, groups?, on_key? }
function M.create_searchable_menu(items, on_select, opts)
	opts = opts or {}

	local NuiLayout = require("nui.layout")
	local NuiInput = require("nui.input")
	local event = require("nui.utils.autocmd").event

	local width = opts.width or 60
	local list_height = math.min(#items + 2, 15)

	-- Try to get the OpenCode chat window, fall back to current window
	local target_win = get_chat_winid() or vim.api.nvim_get_current_win()

	-- Get target window dimensions for centering
	local win_width = vim.api.nvim_win_get_width(target_win)
	local win_height = vim.api.nvim_win_get_height(target_win)
	local total_height = list_height + 5
	local total_width = width + 2 -- border adds 2 to total width
	local row = math.floor((win_height - total_height) / 2)
	local col = math.max(0, math.floor((win_width - total_width) / 2))

	-- Track state
	local filtered_items = vim.deepcopy(items)
	local selected_idx = 1
	local search_text = ""
	local is_closed = false

	-- Create input popup for search
	local input_popup = NuiInput({
		relative = { type = "win", winid = target_win },
		position = { row = row, col = col },
		size = { width = width },
		border = {
			style = "rounded",
			text = {
				top = opts.title or " Search ",
				top_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
	}, {
		prompt = " ",
		default_value = "",
	})

	-- Create list popup for results
	local list_popup = Popup({
		relative = { type = "win", winid = target_win },
		position = { row = row + 3, col = col },
		size = { width = width, height = list_height },
		border = {
			style = "rounded",
			text = {
				bottom = opts.on_key and " ↑↓/j,k:nav  ⏎:select  f:fav  esc:close "
					or " ↑↓/j,k:navigate  ⏎:select  esc:close ",
				bottom_align = "center",
			},
		},
		win_options = {
			cursorline = true,
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:PmenuSel",
		},
	})
	local list_bufnr = list_popup.bufnr

	-- Create layout combining both
	local layout = NuiLayout(
		{
			relative = { type = "win", winid = target_win },
			position = { row = row, col = col },
			size = {
				width = width + 2,
				height = list_height + 5,
			},
		},
		NuiLayout.Box({
			NuiLayout.Box(input_popup, { size = { height = 3 } }),
			NuiLayout.Box(list_popup, { size = { height = list_height } }),
		}, { dir = "col" })
	)

	-- Filter function
	local function filter_items()
		filtered_items = {}
		local query = search_text:lower()

		for _, item in ipairs(items) do
			local label = (item.label or ""):lower()
			local desc = (item.description or ""):lower()

			if query == "" or label:find(query, 1, true) or desc:find(query, 1, true) then
				table.insert(filtered_items, item)
			end
		end

		-- Sort: prioritized items first, then alphabetically
		table.sort(filtered_items, function(a, b)
			local a_priority = a.priority or 0
			local b_priority = b.priority or 0
			if a_priority ~= b_priority then
				return a_priority > b_priority
			end
			return (a.label or "") < (b.label or "")
		end)

		return filtered_items
	end

	-- Render list
	local function render_list()
		filtered_items = filter_items()

		local lines = {}
		local highlights = {}

		if #filtered_items == 0 then
			table.insert(lines, "  No matches found")
		else
			for i, item in ipairs(filtered_items) do
				local prefix = i == selected_idx and "▸ " or "  "
				local label = item.label or tostring(item.value)
				local line = prefix .. label

				-- Add description if present
				if item.description then
					local desc_space = width - #line - #item.description - 4
					if desc_space > 0 then
						line = line .. string.rep(" ", desc_space) .. item.description
					end
				end

				table.insert(lines, line)

				-- Highlight connected/priority items
				if item.priority and item.priority > 0 then
					table.insert(highlights, { line = i, hl = "String" })
				end
			end
		end

		vim.bo[list_bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(list_bufnr, 0, -1, false, lines)
		vim.bo[list_bufnr].modifiable = false

		-- Apply highlights
		for _, hl in ipairs(highlights) do
			local line_text = vim.api.nvim_buf_get_lines(list_bufnr, hl.line - 1, hl.line, false)[1] or ""
			vim.api.nvim_buf_set_extmark(list_bufnr, hl_ns, hl.line - 1, 0, { end_col = #line_text, hl_group = hl.hl })
		end

		-- Position cursor
		if #filtered_items > 0 and list_popup.winid and vim.api.nvim_win_is_valid(list_popup.winid) then
			vim.api.nvim_win_set_cursor(list_popup.winid, { math.min(selected_idx, #filtered_items), 0 })
		end
	end

	-- Close function
	local function close()
		if is_closed then
			return
		end
		is_closed = true
		layout:unmount()
	end

	-- Select current item
	local function select_current()
		if #filtered_items > 0 and filtered_items[selected_idx] then
			local item = filtered_items[selected_idx]
			close()
			on_select(item)
		end
	end

	-- Move selection
	local function move_selection(delta)
		if #filtered_items == 0 then
			return
		end
		selected_idx = selected_idx + delta
		if selected_idx < 1 then
			selected_idx = #filtered_items
		elseif selected_idx > #filtered_items then
			selected_idx = 1
		end
		render_list()
	end

	-- Mount layout
	layout:mount()

	-- Initial render
	render_list()

	-- Setup keymaps on input
	local input_bufnr = input_popup.bufnr
	local keymap_opts = { buffer = input_bufnr, noremap = true, silent = true }

	vim.keymap.set("i", "<CR>", select_current, keymap_opts)
	vim.keymap.set("i", "<C-c>", close, keymap_opts)
	vim.keymap.set("i", "<Up>", function()
		move_selection(-1)
	end, keymap_opts)
	vim.keymap.set("i", "<Down>", function()
		move_selection(1)
	end, keymap_opts)
	vim.keymap.set("i", "<C-p>", function()
		move_selection(-1)
	end, keymap_opts)
	vim.keymap.set("i", "<C-n>", function()
		move_selection(1)
	end, keymap_opts)
	vim.keymap.set("i", "<C-k>", function()
		move_selection(-1)
	end, keymap_opts)
	vim.keymap.set("i", "<C-j>", function()
		move_selection(1)
	end, keymap_opts)

	-- Normal mode keymaps
	vim.keymap.set("n", "<CR>", select_current, keymap_opts)
	vim.keymap.set("n", "<Esc>", close, keymap_opts)
	vim.keymap.set("n", "q", close, keymap_opts)
	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, keymap_opts)
	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, keymap_opts)
	vim.keymap.set("n", "<Up>", function()
		move_selection(-1)
	end, keymap_opts)
	vim.keymap.set("n", "<Down>", function()
		move_selection(1)
	end, keymap_opts)

	-- Custom key handler
	if opts.on_key then
		vim.keymap.set("n", "f", function()
			if #filtered_items > 0 and filtered_items[selected_idx] then
				local keep_open = opts.on_key("f", filtered_items[selected_idx])
				if not keep_open then
					close()
				else
					-- Re-render to show updated state
					render_list()
				end
			end
		end, keymap_opts)
	end

	-- Update on text change
	input_popup:on(event.TextChangedI, function()
		local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false)
		search_text = lines[1] or ""
		selected_idx = 1
		render_list()
	end)

	-- Close on buffer leave
	input_popup:on(event.BufLeave, function()
		vim.defer_fn(close, 100)
	end)

	-- Start in insert mode
	vim.cmd("startinsert!")

	return {
		close = close,
		layout = layout,
	}
end

-- Format relative time (like TUI)
-- Shows "2m ago", "1h ago", "Yesterday", "Jan 15", etc.
local function format_relative_time(timestamp)
	if not timestamp then
		return ""
	end

	local now = os.time()
	local diff = now - timestamp

	if diff < 60 then
		return "just now"
	elseif diff < 3600 then
		local mins = math.floor(diff / 60)
		return mins .. "m ago"
	elseif diff < 7200 then
		return "1h ago"
	elseif diff < 86400 then
		local hours = math.floor(diff / 3600)
		return hours .. "h ago"
	elseif diff < 172800 then
		return "Yesterday"
	else
		return os.date("%b %d", timestamp)
	end
end

-- Create a dedicated session list dialog (like TUI's DialogSessionList)
-- sessions: array of { id, title, time.updated, messageCount }
-- on_select: function(session) called when session is selected
-- on_delete: function(session, callback) called when session is deleted (optional)
-- on_rename: function(session, new_title, callback) called when session is renamed (optional)
-- opts: { title?, width?, current_session_id? }
function M.create_session_list(sessions, on_select, on_delete, on_rename, opts)
	opts = opts or {}

	-- Sort sessions by update time (most recent first, like TUI)
	table.sort(sessions, function(a, b)
		local a_time = a.time and a.time.updated or 0
		local b_time = b.time and b.time.updated or 0
		return a_time > b_time
	end)

	local width = opts.width or 70
	local height = math.min(#sessions + 4, 20)

	-- Try to get the OpenCode chat window
	local target_win = get_chat_winid() or vim.api.nvim_get_current_win()

	-- Get target window dimensions
	local win_width = vim.api.nvim_win_get_width(target_win)
	local win_height = vim.api.nvim_win_get_height(target_win)
	local total_width = width + 2
	local row = math.floor((win_height - height) / 2)
	local col = math.max(0, math.floor((win_width - total_width) / 2))

	local popup = Popup({
		relative = { type = "win", winid = target_win },
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = opts.title or " Sessions ",
				top_align = "center",
				bottom = " ⏎:open d:delete r:rename esc:close ",
				bottom_align = "center",
			},
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
		win_options = {
			cursorline = true,
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:PmenuSel",
		},
	})
	local bufnr = popup.bufnr

	-- Track state
	local selected_idx = 1
	local is_closed = false

	-- Helper to check if session is current
	local function is_current(session)
		return opts.current_session_id and session.id == opts.current_session_id
	end

	-- Render sessions
	local function render()
		local lines = {}
		local highlights = {}

		for i, session in ipairs(sessions) do
			local title = session.title or "Untitled"
			local time_str = format_relative_time(session.time and session.time.updated)
			local msg_count = session.messageCount or 0

			-- Format: "● Title (5 msgs)           2h ago"
			local current_marker = is_current(session) and "● " or "  "
			local msg_str = msg_count > 0 and "(" .. msg_count .. " msgs)" or ""
			local left = current_marker .. title .. " " .. msg_str

			-- Pad to right-align time
			local padding = width - #left - #time_str - 4
			if padding < 1 then
				-- Truncate title if too long
				local max_title = width - #current_marker - #msg_str - #time_str - 8
				if max_title > 10 then
					title = title:sub(1, max_title) .. "..."
					left = current_marker .. title .. " " .. msg_str
					padding = width - #left - #time_str - 4
				else
					padding = 1
				end
			end

			local line = left .. string.rep(" ", padding) .. time_str
			table.insert(lines, line)

			-- Highlight current session
			if is_current(session) then
				table.insert(highlights, { line = i, hl = "String" })
			end
		end

		if #sessions == 0 then
			table.insert(lines, "  No sessions found")
		end

		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false

		-- Apply highlights
		for _, hl in ipairs(highlights) do
			local line_text = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.line, false)[1] or ""
			vim.api.nvim_buf_set_extmark(bufnr, hl_ns, hl.line - 1, 0, { end_col = #line_text, hl_group = hl.hl })
		end

		-- Position cursor
		if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
			vim.api.nvim_win_set_cursor(popup.winid, { selected_idx, 0 })
		end
	end

	-- Close function
	local function close()
		if is_closed then
			return
		end
		is_closed = true
		pcall(function()
			popup:unmount()
		end)
	end

	-- Select current session
	local function select_current()
		if #sessions > 0 and sessions[selected_idx] then
			close()
			on_select(sessions[selected_idx])
		end
	end

	-- Delete current session
	local function delete_current()
		if not on_delete or #sessions == 0 then
			return
		end
		local session = sessions[selected_idx]
		if session then
			vim.ui.select({ "Yes", "No" }, {
				prompt = "Delete session '" .. (session.title or "Untitled") .. "'?",
			}, function(choice)
				if choice == "Yes" then
					on_delete(session, function()
						-- Remove from list and re-render
						table.remove(sessions, selected_idx)
						if selected_idx > #sessions then
							selected_idx = math.max(1, #sessions)
						end
						if not is_closed then
							render()
						end
					end)
				end
			end)
		end
	end

	-- Rename current session
	local function rename_current()
		if not on_rename or #sessions == 0 then
			return
		end
		local session = sessions[selected_idx]
		if session then
			M.create_input_popup({
				title = " Rename Session ",
				prompt = "New title:",
				default = session.title or "",
				on_submit = function(new_title)
					if new_title and new_title ~= "" then
						on_rename(session, new_title, function()
							session.title = new_title
							if not is_closed then
								render()
							end
						end)
					end
				end,
			})
		end
	end

	-- Move selection
	local function move_selection(delta)
		if #sessions == 0 then
			return
		end
		selected_idx = selected_idx + delta
		if selected_idx < 1 then
			selected_idx = #sessions
		elseif selected_idx > #sessions then
			selected_idx = 1
		end
		render()
	end

	-- Mount and render
	popup:mount()
	render()

	-- Setup keymaps
	local keymap_opts = { buffer = bufnr, noremap = true, silent = true }

	vim.keymap.set("n", "<CR>", select_current, keymap_opts)
	vim.keymap.set("n", "<Esc>", close, keymap_opts)
	vim.keymap.set("n", "q", close, keymap_opts)
	vim.keymap.set("n", "j", function()
		move_selection(1)
	end, keymap_opts)
	vim.keymap.set("n", "k", function()
		move_selection(-1)
	end, keymap_opts)
	vim.keymap.set("n", "<Down>", function()
		move_selection(1)
	end, keymap_opts)
	vim.keymap.set("n", "<Up>", function()
		move_selection(-1)
	end, keymap_opts)
	vim.keymap.set("n", "d", delete_current, keymap_opts)
	vim.keymap.set("n", "r", rename_current, keymap_opts)

	-- Close on buffer leave
	local event = require("nui.utils.autocmd").event
	popup:on(event.BufLeave, function()
		vim.defer_fn(close, 100)
	end)

	return {
		close = close,
		popup = popup,
	}
end

return M
