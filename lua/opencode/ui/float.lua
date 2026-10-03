-- opencode.nvim - Shared float utilities
-- Reusable floating window helpers

local M = {}

local Popup = require("opencode.ui.popup")
local float_context = require("opencode.ui.float_context")

require("opencode.ui.highlights").register("opencode.ui.float", function()
	local normal = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
	vim.api.nvim_set_hl(0, "OpenCodeInputPopupTitle", { fg = normal.fg, bold = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputPopupBackdrop", { bg = "#000000" })
end)

-- Create a centered floating popup with standard styling
function M.create_centered_popup(opts)
	opts = opts or {}

	local function centered_size()
		local screen_width = math.max(1, vim.o.columns)
		local screen_height = math.max(1, vim.o.lines - vim.o.cmdheight)
		local width = opts.width or math.min(60, screen_width - 10)
		local height = opts.height or math.min(20, screen_height - 6)
		return { width = width, height = height }
	end

	local popup = Popup.new({
		enter = opts.enter ~= false,
		focusable = opts.focusable ~= false,
		zindex = opts.zindex,
		buf_options = { filetype = "opencode_float" },
		focus_restore = opts.focus_restore == nil and "previous" or opts.focus_restore,
		close_on_leave = opts.close_on_leave,
		on_resize = opts.on_resize or function(current)
			current:resize({ size = centered_size() })
		end,
		on_close = opts.on_close,
		border = {
			style = opts.border or "rounded",
			text = opts.title and {
				top = " " .. opts.title .. " ",
				top_align = "center",
			} or nil,
		},
		size = centered_size(),
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

	local width = opts.width or (opts.password and 60 or 50)

	local border_width, border_height = 0, 0
	if not opts.password then border_width, border_height = Popup.outer_insets() end
	local total_width = width + border_width
	local total_height = (opts.password and 7 or 1) + border_height
	local function placement()
		if opts.password then
			local visible_width = math.min(width, math.max(1, vim.o.columns - 2))
			return "editor", math.floor((vim.o.lines - vim.o.cmdheight) / 4),
				math.max(0, math.floor((vim.o.columns - visible_width) / 2)), 80
		end
		return float_context.resolve_centered_placement(total_width, total_height)
	end
	local relative, row, col, zindex = placement()
	local prompt = opts.prompt and (opts.prompt .. " ") or "> "
	local previous_paste, secret_paste, reading_secret, draw_secret

	local popup_opts = {
		input_only = not opts.password,
		outer_border_style = opts.password and "none" or nil,
		focus_restore = opts.refocus_chat and "chat" or "previous",
		close_on_leave = true,
		on_close = function()
			if secret_paste and vim.paste == secret_paste then vim.paste = previous_paste end
			if reading_secret then vim.api.nvim_input("\27") end
		end,
		on_resize = function(current)
			local next_relative, next_row, next_col = placement()
			if opts.password then
				current:resize({
					frame = { size = { width = vim.o.columns, height = vim.o.lines - vim.o.cmdheight } },
					content = { relative = next_relative, position = { row = next_row, col = next_col },
						size = { width = math.min(width, math.max(1, vim.o.columns - 2)), height = 7 } },
				})
			else current:resize({ relative = next_relative, position = { row = next_row, col = next_col } }) end
			if draw_secret then draw_secret() end
		end,
	}
	if opts.password then
		popup_opts.frame = {
			relative = "editor", position = { row = 0, col = 0 },
			size = { width = vim.o.columns, height = vim.o.lines - vim.o.cmdheight },
			zindex = zindex - 1, border = "none", focusable = false,
			win_options = {
				winhighlight = "Normal:OpenCodeInputPopupBackdrop,NormalNC:OpenCodeInputPopupBackdrop,EndOfBuffer:OpenCodeInputPopupBackdrop",
				winblend = 40,
			},
		}
		popup_opts.content = {
			enter = true,
			relative = relative,
			position = { row = row, col = col },
			size = { width = math.min(width, math.max(1, vim.o.columns - 2)), height = 7 },
			zindex = zindex,
			border = "none",
			buf_options = { filetype = "opencode_float" },
			win_options = {
				winhighlight = "Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat",
				winblend = 0,
				wrap = false,
				sidescrolloff = 0,
				scrolloff = 0,
			},
		}
	else
		popup_opts.input = {
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
			prompt = prompt,
			default_value = opts.default or "",
		}
	end
	local popup = Popup.new(popup_opts)
	popup:mount()
	local input = popup.input or popup.content

	local is_closed = false
	local function close()
		if is_closed then
			return
		end
		is_closed = true
		popup:close()
	end
	if opts.password then
		local secret = ""
		vim.bo[input.bufnr].swapfile = false
		vim.bo[input.bufnr].undofile = false
		vim.bo[input.bufnr].undolevels = -1
		vim.bo[input.bufnr].modifiable = false
		local function draw()
			local count = vim.fn.strchars(secret)
			local current_width = vim.api.nvim_win_get_width(input.winid)
			local title = vim.fn.strcharpart(vim.trim(opts.title or "Input"), 0, math.max(0, current_width - 9))
			local header = "  " .. title
				.. string.rep(" ", math.max(1, current_width - vim.fn.strdisplaywidth(title) - 7)) .. "esc  "
			local value = count > 0 and secret or (opts.prompt or "Input")
			-- Scroll only the field; moving the window's leftcol also hides the header/footer.
			local field_width = math.max(0, current_width - 5)
			value = vim.fn.strcharpart(value, math.max(0, vim.fn.strchars(value) - field_width))
			while vim.fn.strdisplaywidth(value) > field_width do value = vim.fn.strcharpart(value, 1) end
			popup:render({ "", header, "", "  " .. value .. " ", "", "  enter submit", "" }, {
				{ line = 1, col = 2, end_col = 2 + #title, hl_group = "OpenCodeInputPopupTitle" },
				{ line = 1, col = #header - 5, end_col = #header - 2, hl_group = "Comment" },
				{ line = 3, col = 2, end_col = 2 + #value, hl_group = count > 0 and "NormalFloat" or "Comment" },
				{ line = 5, col = 2, end_col = 7, hl_group = "NormalFloat" },
				{ line = 5, col = 8, end_col = 14, hl_group = "Comment" },
			})
			vim.api.nvim_win_set_cursor(input.winid, { 4, count > 0 and 2 + #value or 2 })
			vim.fn.winrestview({ leftcol = 0 })
			vim.cmd("redraw")
		end
		draw_secret = draw
		previous_paste = vim.paste
		local pasted_line_done = false
		secret_paste = function(lines, phase)
			if vim.api.nvim_get_current_win() ~= input.winid then return previous_paste(lines, phase) end
			if phase == -1 or phase == 1 then pasted_line_done = false end
			if not pasted_line_done then
				local pasted = table.concat(lines, "\n")
				secret = secret .. pasted:match("^[^\r\n]*")
				pasted_line_done = pasted:find("[\r\n]") ~= nil
				draw()
			end
			if phase == -1 or phase == 3 then pasted_line_done = false end
			return true
		end
		vim.paste = secret_paste
		local submitted
		reading_secret = true
		-- ponytail: edit at the end; add cursor editing if in-place corrections become necessary.
		local ok, err = pcall(function()
			draw()
			while not popup.closed do
				local key = vim.fn.getcharstr()
				local name = vim.fn.keytrans(key)
				if name == "<CR>" or name == "<NL>" then submitted = secret; break
				elseif name == "<Esc>" or name == "<C-C>" then break
				elseif name == "<BS>" or name == "<C-H>" or name == "<Del>" or name == "^?" then
					secret = vim.fn.strcharpart(secret, 0, math.max(0, vim.fn.strchars(secret) - 1))
					draw()
				elseif name == "<C-U>" then secret = ""; draw()
				-- getcharstr() bypasses mappings, including the user's Cmd+V mapping.
				elseif name == "<D-v>" then secret_paste({ vim.fn.getreg("+") }, -1)
				elseif key:byte(1) and key:byte(1) >= 32 and key:byte(1) ~= 127
					and (name:sub(1, 1) ~= "<" or name == "<lt>" or name == "<Space>") then
					secret = secret .. key
					draw()
				end
			end
		end)
		reading_secret = false
		close()
		if not ok and not tostring(err):find("Interrupt", 1, true) then error(err) end
		if submitted and submitted ~= "" then
			if opts.on_submit then opts.on_submit(submitted) end
		elseif opts.on_cancel then opts.on_cancel() end
		return { close = close }
	end

	-- Setup keymaps
	local input_bufnr = input.bufnr
	local keymap_opts = { buffer = input_bufnr, noremap = true, silent = true }

	vim.keymap.set("i", "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false)
		local value = lines[1] or ""
		if value:sub(1, #prompt) == prompt then value = value:sub(#prompt + 1) end
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
