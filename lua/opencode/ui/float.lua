-- opencode.nvim - Shared float utilities
-- Reusable floating window helpers

local M = {}

local Popup = require("opencode.ui.popup")
local float_context = require("opencode.ui.float_context")

-- Create a centered floating popup with standard styling
function M.create_centered_popup(opts)
	opts = opts or {}

	local function centered_layout()
		local screen_width = math.max(1, vim.o.columns)
		local screen_height = math.max(1, vim.o.lines - vim.o.cmdheight)
		local width = opts.width or math.min(60, screen_width - 10)
		local height = opts.height or math.min(20, screen_height - 6)
		return {
			position = {
				row = math.floor((screen_height - height) / 2),
				col = math.floor((screen_width - width) / 2),
			},
			size = { width = width, height = height },
		}
	end
	local layout = centered_layout()

	local popup = Popup.new({
		enter = opts.enter ~= false,
		focusable = opts.focusable ~= false,
		zindex = opts.zindex,
		buf_options = { filetype = "opencode_float" },
		focus_restore = opts.focus_restore == nil and "previous" or opts.focus_restore,
		close_on_leave = opts.close_on_leave,
		on_resize = opts.on_resize or function(current)
			current:resize(centered_layout())
		end,
		on_close = opts.on_close,
		border = {
			style = opts.border or "rounded",
			text = opts.title and {
				top = " " .. opts.title .. " ",
				top_align = "center",
			} or nil,
		},
		position = layout.position,
		size = layout.size,
	})

	return popup, popup.bufnr
end

-- Setup standard keymaps for a popup (q to close, Esc to close)
function M.setup_close_keymaps(bufnr, close_fn)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	vim.keymap.set("n", "q", close_fn, opts)
	vim.keymap.set("n", "<Esc>", close_fn, opts)
end

-- Create input popup for text entry (API keys, codes, etc.)
-- opts: { title?, prompt?, on_submit, on_cancel?, width?, password?, refocus_chat? }
function M.create_input_popup(opts)
	opts = opts or {}

	if opts.password then
		-- inputsecret does not echo or record text in input history or a buffer.
		vim.fn.inputsave()
		local ok, value = pcall(vim.fn.inputsecret, (opts.prompt or "Secret:") .. " ")
		vim.fn.inputrestore()
		if ok and value ~= "" then
			if opts.on_submit then opts.on_submit(value) end
		elseif opts.on_cancel then opts.on_cancel() end
		return { close = function() end }
	end

	local width = opts.width or 50

	local total_width = width + 2 -- border adds 2 to total width
	local total_height = 3
	local relative, row, col, zindex = float_context.resolve_centered_placement(total_width, total_height)

	local popup = Popup.new({
		input_only = true,
		focus_restore = opts.refocus_chat and "chat" or "previous",
		close_on_leave = true,
		on_resize = function(current)
			local next_relative, next_row, next_col = float_context.resolve_centered_placement(total_width, total_height)
			current:resize({ relative = next_relative, position = { row = next_row, col = next_col } })
		end,
		input = {
			relative = relative,
			position = { row = row, col = col },
			size = { width = width, height = 1 },
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
			prompt = opts.prompt and (opts.prompt .. " ") or "> ",
			default_value = opts.default or "",
		},
	})
	popup:mount()
	local input = popup.input

	local is_closed = false
	local function close()
		if is_closed then
			return
		end
		is_closed = true
		popup:close()
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

	-- Start in insert mode
	vim.cmd("startinsert!")

	return {
		close = close,
		input = input,
	}
end

return M
