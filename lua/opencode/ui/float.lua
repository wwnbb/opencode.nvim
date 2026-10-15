-- opencode.nvim - Shared float utilities
-- Reusable floating window helpers

local M = {}

local Popup = require("opencode.ui.popup")
local float_context = require("opencode.ui.float_context")
local keymaps = require("opencode.util.keymap")

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

-- Shared close controls for read-only popups.
function M.setup_close_keymaps(bufnr, close_fn)
	local map, apply = keymaps.mapper("popup", bufnr)
	map("n", "close", close_fn)
	apply()
end

-- Create input popup for text entry (API keys, codes, etc.)
-- opts: { title?, prompt?, on_submit, on_cancel?, width?, password?, refocus_chat? }
function M.create_input_popup(opts)
	opts = opts or {}

	local width = opts.width or (opts.password and 60 or 50)
	local height = opts.password and 7 or 1
	local prompt = opts.prompt and (opts.prompt .. " ") or "> "
	local input_line = prompt .. (opts.default or "")
	local previous_win = vim.api.nvim_get_current_win()

	local border_width, border_height = 0, 0
	if not opts.password then border_width, border_height = Popup.outer_insets() end
	local function placement()
		if opts.password then
			local visible_width = math.min(width, math.max(1, vim.o.columns - 2))
			return "editor", math.floor((vim.o.lines - vim.o.cmdheight) / 4),
				math.max(0, math.floor((vim.o.columns - visible_width) / 2)), 80
		end
		local target_win, float_dims = float_context.get_chat_context()
		local available_width = vim.o.columns
		local available_height = vim.o.lines - vim.o.cmdheight
		if not float_dims and target_win and vim.api.nvim_win_is_valid(target_win) then
			available_width = math.min(available_width, vim.api.nvim_win_get_width(target_win))
			available_height = math.min(available_height, vim.api.nvim_win_get_height(target_win))
		end
		local text_width = vim.fn.strdisplaywidth(input_line) + 1
		width = math.min(opts.width or math.max(50, text_width), math.max(1, available_width - border_width))
		height = math.min(math.ceil(text_width / width), math.max(1, available_height - border_height))
		return float_context.resolve_centered_placement(width + border_width, height + border_height)
	end
	local relative, row, col, zindex = placement()
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
			local next_placement = vim.api.nvim_win_is_valid(previous_win)
				and vim.api.nvim_win_call(previous_win, function() return { placement() } end) or { placement() }
			local next_relative, next_row, next_col = unpack(next_placement)
			if opts.password then
				current:resize({
					frame = { size = { width = vim.o.columns, height = vim.o.lines - vim.o.cmdheight } },
					content = { relative = next_relative, position = { row = next_row, col = next_col },
						size = { width = math.min(width, math.max(1, vim.o.columns - 2)), height = 7 } },
				})
			else current:resize({ relative = next_relative, position = { row = next_row, col = next_col },
				size = { width = width, height = height } }) end
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
			size = { width = width, height = height },
			zindex = zindex,
			border = {
				style = "rounded",
				text = {
					top = opts.title or " Input ",
					top_align = "center",
					bottom = " " .. keymaps.label("popup", "submit") .. ":submit  " .. keymaps.label("popup", "cancel") .. ":cancel ",
					bottom_align = "center",
				},
			},
			buf_options = {
				filetype = "opencode_float",
			},
			win_options = {
				winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
				wrap = true, linebreak = false, breakindent = false, showbreak = "",
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
		local bindings, customized = keymaps.resolve("password")
		local commands = {}
		for _, action in ipairs({ "submit", "cancel", "backspace", "clear", "paste" }) do
			for _, lhs in ipairs(keymaps.keys(bindings[action])) do
				local code, previous = keymaps.code(lhs), commands[keymaps.code(lhs)]
				if previous and previous.custom and customized[action] and previous.action ~= action then
					close()
					error("opencode.nvim: conflicting password keymaps " .. previous.action .. " and " .. action .. " for " .. lhs)
				end
				if not previous or customized[action] or not previous.custom then
					commands[code] = { action = action, custom = customized[action] }
				end
			end
		end
		local function password_label(action)
			local labels = {}
			for _, lhs in ipairs(keymaps.keys(bindings[action])) do
				if commands[keymaps.code(lhs)].action == action then labels[#labels + 1] = lhs end
			end
			return #labels > 0 and table.concat(labels, " / ") or "(disabled)"
		end
		local secret = ""
		vim.bo[input.bufnr].swapfile = false
		vim.bo[input.bufnr].undofile = false
		vim.bo[input.bufnr].undolevels = -1
		vim.bo[input.bufnr].modifiable = false
		local function draw()
			local count = vim.fn.strchars(secret)
			local current_width = vim.api.nvim_win_get_width(input.winid)
			local title = vim.fn.strcharpart(vim.trim(opts.title or "Input"), 0, math.max(0, current_width - 9))
			local cancel_label, submit_label = password_label("cancel"), password_label("submit")
			local header = "  " .. title
				.. string.rep(" ", math.max(1, current_width - vim.fn.strdisplaywidth(title) - vim.fn.strdisplaywidth(cancel_label) - 4)) .. cancel_label .. "  "
			local footer = submit_label ~= "" and ("  " .. submit_label .. " submit") or ""
			local value = count > 0 and secret or (opts.prompt or "Input")
			-- Scroll only the field; moving the window's leftcol also hides the header/footer.
			local field_width = math.max(0, current_width - 5)
			value = vim.fn.strcharpart(value, math.max(0, vim.fn.strchars(value) - field_width))
			while vim.fn.strdisplaywidth(value) > field_width do value = vim.fn.strcharpart(value, 1) end
			popup:render({ "", header, "", "  " .. value .. " ", "", footer, "" }, {
				{ line = 1, col = 2, end_col = 2 + #title, hl_group = "OpenCodeInputPopupTitle" },
				{ line = 1, col = #header - #cancel_label - 2, end_col = #header - 2, hl_group = "Comment" },
				{ line = 3, col = 2, end_col = 2 + #value, hl_group = count > 0 and "NormalFloat" or "Comment" },
				{ line = 5, col = 0, end_col = #footer, hl_group = "Comment" },
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
		local function read_key(wait)
			local ok, key = pcall(vim.fn.getcharstr, wait)
			if ok then return key end
			if tostring(key):find("Interrupt", 1, true) then return "\3" end
			error(key)
		end
		-- ponytail: edit at the end; add cursor editing if in-place corrections become necessary.
		local ok, err = pcall(function()
			draw()
			local keys = {}
			while not popup.closed do
				if #keys == 0 then keys[1] = read_key() end
				local sequence = table.concat(vim.tbl_map(function(key) return key == string.char(127) and key or keymaps.code(vim.fn.keytrans(key)) end, keys))
				local command, prefix = commands[sequence], false
				for code in pairs(commands) do
					if #code > #sequence and code:sub(1, #sequence) == sequence then prefix = true; break end
				end
				local next_key
				if prefix then
					-- Match multi-key controls without storing credentials in an editor buffer.
					vim.wait(math.max(1, vim.o.timeoutlen), function()
						next_key = read_key(0)
						return next_key ~= "" or popup.closed
					end, 10)
				end
				if popup.closed then break end
				if next_key and next_key ~= "" then
					keys[#keys + 1] = next_key
				elseif command then
					keys = {}
					local action = command.action
					if action == "submit" then submitted = secret; break
					elseif action == "cancel" then break
					elseif action == "backspace" then
						secret = vim.fn.strcharpart(secret, 0, math.max(0, vim.fn.strchars(secret) - 1)); draw()
					elseif action == "clear" then secret = ""; draw()
					elseif action == "paste" then secret_paste({ vim.fn.getreg("+") }, -1) end
				else
					local key = table.remove(keys, 1)
					local name = vim.fn.keytrans(key)
					if key:byte(1) and key:byte(1) >= 32 and key:byte(1) ~= 127
						and (name:sub(1, 1) ~= "<" or name == "<lt>" or name == "<Space>") then
						secret = secret .. key; draw()
					end
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
	local map, apply = keymaps.mapper("popup", input_bufnr)
	popup:on({ "TextChanged", "TextChangedI" }, function()
		input_line = vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false)[1] or prompt
		popup.on_resize(popup)
	end, "input")

	map("i", "submit", function()
		local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false)
		local value = lines[1] or ""
		if value:sub(1, #prompt) == prompt then value = value:sub(#prompt + 1) end
		close()
		if opts.on_submit then
			opts.on_submit(value)
		end
	end)

	map("i", "cancel", function()
		close()
		if opts.on_cancel then opts.on_cancel() end
	end)
	apply()

	-- Start in insert mode
	vim.cmd("startinsert!")

	return {
		close = close,
		input = input,
	}
end

return M
