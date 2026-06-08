-- opencode.nvim - Shared float utilities
-- Reusable floating window helpers

local M = {}

local Popup = require("nui.popup")
local float_context = require("opencode.ui.float_context")
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
		zindex = opts.zindex,
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

-- Create input popup for text entry (API keys, codes, etc.)
-- opts: { title?, prompt?, on_submit, on_cancel?, width?, password?, refocus_chat? }
function M.create_input_popup(opts)
	opts = opts or {}

	local NuiInput = require("nui.input")
	local event = require("nui.utils.autocmd").event

	local width = opts.width or 50

	local total_width = width + 2 -- border adds 2 to total width
	local total_height = 3
	local relative, row, col, zindex = float_context.resolve_centered_placement(total_width, total_height)

	local input = NuiInput({
		relative = relative,
		position = { row = row, col = col },
		size = { width = width },
		zindex = zindex,
		border = {
			style = "rounded",
			text = {
				top = opts.title or " Input ",
				top_align = "center",
				bottom = " ⏎:submit  esc:cancel ",
				bottom_align = "center",
			},
		},
		buf_options = {
			filetype = "opencode_float",
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
		pcall(function()
			input:unmount()
		end)
		if opts.refocus_chat then
			float_context.focus_chat_if_visible()
		end
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

return M
