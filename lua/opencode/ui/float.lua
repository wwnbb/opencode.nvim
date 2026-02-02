-- opencode.nvim - Shared float utilities
-- Reusable floating window helpers

local M = {}

local Popup = require("nui.popup")

-- Create a centered floating popup with standard styling
function M.create_centered_popup(opts)
	opts = opts or {}
	
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	
	local width = opts.width or math.min(60, ui.width - 10)
	local height = opts.height or math.min(20, ui.height - 6)
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)
	
	local bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
	
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
		bufnr = bufnr,
	})
	
	return popup, bufnr
end

-- Create a popup at specific position
function M.create_popup_at(position, size, opts)
	opts = opts or {}
	
	local bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
	
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
		bufnr = bufnr,
	})
	
	return popup, bufnr
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
	
	local row = 1  -- Top of screen
	local col = ui.width - width - 2  -- Right aligned
	
	local bufnr = vim.api.nvim_create_buf(false, true)
	local popup = Popup({
		enter = false,
		focusable = false,
		border = "rounded",
		position = { row = row, col = col },
		size = { width = width, height = height },
		bufnr = bufnr,
	})
	
	popup:mount()
	
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
	
	vim.api.nvim_buf_add_highlight(bufnr, -1, hl_group, 1, 0, -1)
	vim.bo[bufnr].modifiable = false
	
	-- Auto close
	vim.defer_fn(function()
		pcall(function()
			popup:unmount()
		end)
	end, timeout)
	
	return popup
end

-- Create menu/selection popup
function M.create_menu(items, on_select, opts)
	opts = opts or {}
	
	local width = opts.width or 40
	local height = math.min(#items + 2, 20)
	
	local bufnr = vim.api.nvim_create_buf(false, true)
	local popup, bufnr = M.create_centered_popup({
		width = width,
		height = height,
		border = "rounded",
		title = opts.title or " Select ",
		bufnr = bufnr,
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

return M
