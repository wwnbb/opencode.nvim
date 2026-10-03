describe("shared popup owner", function()
	local original_columns, original_lines
	local original_win

	before_each(function()
		original_columns, original_lines = vim.o.columns, vim.o.lines
		original_win = vim.api.nvim_get_current_win()
	end)

	after_each(function()
		vim.o.columns, vim.o.lines = original_columns, original_lines
		if vim.api.nvim_win_is_valid(original_win) then vim.api.nvim_set_current_win(original_win) end
	end)

	it("renders content and highlights, replacing only its own marks", function()
		local popup = require("opencode.ui.popup").new({
			relative = "editor",
			size = { width = 32, height = 5 },
			border = "rounded",
			enter = true,
		})
		popup:mount()
		local bufnr = popup.bufnr
		vim.bo[bufnr].modifiable = false
		popup:render({ "heading", "body" }, { { line = 0, col = 0, end_col = 7, hl_group = "Title" } })
		assert.same({ "heading", "body" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.is_false(vim.bo[bufnr].modifiable)
		local marks = vim.api.nvim_buf_get_extmarks(bufnr, popup.namespaces.content, 0, -1, { details = true })
		assert.equals(1, #marks)
		assert.equals("Title", marks[1][4].hl_group)
		popup:render(nil, { { row = 1, col = 0, opts = { line_hl_group = "Comment" } } })
		assert.same({ "heading", "body" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		marks = vim.api.nvim_buf_get_extmarks(bufnr, popup.namespaces.content, 0, -1, { details = true })
		assert.equals(1, #marks)
		assert.equals(1, marks[1][2])
		assert.equals("Comment", marks[1][4].line_hl_group)
		popup:close()
		assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
	end)

	it("clamps framed layers on mount and after a screen resize", function()
		vim.o.columns, vim.o.lines = 42, 20
		local popup = require("opencode.ui.popup").new({
			frame = {
				relative = "editor",
				position = { row = 100, col = 100 },
				size = { width = 100, height = 100 },
				border = "none",
				focusable = false,
			},
			content = {
				position = { row = 3, col = 1 },
				size = { width = 80, height = 80 },
				border = "none",
				enter = true,
			},
			input = {
				kind = "popup",
				position = { row = 2, col = 2 },
				size = { width = 60, height = 1 },
				border = "none",
			},
			focus_restore = "previous",
		})
		popup:mount()
		local frame_config = vim.api.nvim_win_get_config(popup.frame.winid)
		assert.equals(40, frame_config.width)
		assert.equals(0, frame_config.row)
		assert.equals(0, frame_config.col)
		assert.equals(popup.frame.winid, vim.api.nvim_win_get_config(popup.content.winid).win)
		popup:render({ "frame" }, {}, "frame")
		popup:render({ "content" })
		popup:render({ "input" }, {}, "input")
		assert.equals("content", vim.api.nvim_buf_get_lines(popup.bufnr, 0, 1, false)[1])
		vim.o.columns, vim.o.lines = 30, 14
		vim.api.nvim_exec_autocmds("VimResized", {})
		frame_config = vim.api.nvim_win_get_config(popup.frame.winid)
		assert.equals(28, frame_config.width)
		assert.is_true(frame_config.height <= vim.o.lines - vim.o.cmdheight)
		assert.is_true(vim.api.nvim_win_get_width(popup.content.winid) <= frame_config.width)
		popup:resize({ frame = { size = { width = 18, height = 8 } }, content = { size = { width = 16, height = 4 } } })
		assert.equals(18, vim.api.nvim_win_get_width(popup.frame.winid))
		assert.equals(16, vim.api.nvim_win_get_width(popup.content.winid))
		local wins = { popup.frame.winid, popup.content.winid, popup.input.winid }
		local bufs = { popup.frame.bufnr, popup.content.bufnr, popup.input.bufnr }
		popup:close()
		popup:close()
		for _, win in ipairs(wins) do assert.is_false(vim.api.nvim_win_is_valid(win)) end
		for _, buf in ipairs(bufs) do assert.is_false(vim.api.nvim_buf_is_valid(buf)) end
	end)

	it("keeps a titled border inside the screen at both edges", function()
		vim.o.columns, vim.o.lines = 24, 10
		local popup = require("opencode.ui.popup").new({
			relative = "editor",
			position = { row = 0, col = 0 },
			size = { width = 30, height = 12 },
			border = { style = "rounded", text = { top = " Details " } },
		})
		popup:mount()
		local function assert_border_inside_screen()
			local config = vim.api.nvim_win_get_config(popup.content.border.winid)
			assert.is_true(config.row >= 0)
			assert.is_true(config.col >= 0)
			assert.is_true(config.row + config.height <= vim.o.lines - vim.o.cmdheight)
			assert.is_true(config.col + config.width <= vim.o.columns)
		end
		assert_border_inside_screen()
		popup:resize({ position = { row = 100, col = 100 } })
		assert_border_inside_screen()
		vim.o.columns, vim.o.lines = 20, 8
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert_border_inside_screen()
		popup:close()
	end)

	it("restores focus and closes every layer when a child window is closed", function()
		local popup = require("opencode.ui.popup").new({
			frame = { relative = "editor", size = { width = 36, height = 9 }, border = "none", focusable = false },
			content = { position = { row = 1, col = 1 }, size = { width = 34, height = 7 }, border = "none", enter = true },
			input = { kind = "popup", position = { row = 2, col = 2 }, size = { width = 20, height = 1 }, border = "none", enter = true },
			focus_restore = "previous",
		})
		popup:mount()
		assert.equals(popup.input.winid, vim.api.nvim_get_current_win())
		local frame_win, content_win, input_win = popup.frame.winid, popup.content.winid, popup.input.winid
		vim.api.nvim_win_close(content_win, true)
		vim.wait(100, function() return popup.closed end)
		assert.is_true(popup.closed)
		assert.is_false(vim.api.nvim_win_is_valid(frame_win))
		assert.is_false(vim.api.nvim_win_is_valid(input_win))
		assert.equals(original_win, vim.api.nvim_get_current_win())
	end)

	it("closes after focus leaves an owned window", function()
		local popup = require("opencode.ui.popup").new({
			relative = "editor", size = { width = 20, height = 4 }, border = "none", enter = true,
			close_on_leave = true, focus_restore = "previous",
		})
		popup:mount()
		local popup_win = popup.winid
		vim.api.nvim_set_current_win(original_win)
		assert(vim.wait(250, function() return popup.closed end, 10))
		assert.is_false(vim.api.nvim_win_is_valid(popup_win))
		assert.equals(original_win, vim.api.nvim_get_current_win())
	end)

	for _, kind in ipairs({ "automatic", "explicit" }) do
		it("keeps the newly selected tab during " .. kind .. " popup close", function()
			local popup = require("opencode.ui.popup").new({
				relative = "editor", size = { width = 20, height = 4 }, enter = true,
				close_on_leave = true, focus_restore = kind == "automatic" and "chat" or "previous",
			})
			popup:mount()
			vim.cmd("tabnew")
			local selected_tab, selected_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
			local ok, err = pcall(function()
				if kind == "explicit" then popup:close({ force_focus = true }) end
				assert.is_true(vim.wait(250, function() return popup.closed end, 5))
				assert.equals(selected_tab, vim.api.nvim_get_current_tabpage())
				assert.equals(selected_win, vim.api.nvim_get_current_win())
			end)
			popup:close({ restore_focus = false })
			if vim.api.nvim_tabpage_is_valid(selected_tab) then
				vim.api.nvim_set_current_tabpage(selected_tab)
				vim.cmd("tabclose")
			end
			if not ok then error(err) end
		end)
	end

	it("restores the previous window when closed without options", function()
		local popup = require("opencode.ui.popup").new({
			relative = "editor", size = { width = 20, height = 4 }, border = "none", enter = true,
			focus_restore = "previous",
		})
		popup:mount()
		assert.equals(popup.winid, vim.api.nvim_get_current_win())
		popup:close()
		assert.equals(original_win, vim.api.nvim_get_current_win())
	end)

	it("cleans buffers if closed before mounting", function()
		local popup = require("opencode.ui.popup").new({
			frame = { relative = "editor", size = { width = 20, height = 5 }, border = "none" },
			content = { position = { row = 1, col = 1 }, size = { width = 18, height = 3 }, border = "none" },
		})
		local frame_buf, content_buf = popup.frame.bufnr, popup.content.bufnr
		popup:close()
		popup:close()
		assert.is_false(vim.api.nvim_buf_is_valid(frame_buf))
		assert.is_false(vim.api.nvim_buf_is_valid(content_buf))
	end)

	it("cleans a titled border buffer if closed before mounting", function()
		local popup = require("opencode.ui.popup").new({
			relative = "editor",
			size = { width = 20, height = 5 },
			border = { style = "rounded", text = { top = " Details " } },
		})
		local content_buf = popup.content.bufnr
		local border_buf = popup.content.border.bufnr
		assert.is_true(vim.api.nvim_buf_is_valid(border_buf))
		popup:close()
		popup:close()
		assert.is_false(vim.api.nvim_buf_is_valid(content_buf))
		assert.is_false(vim.api.nvim_buf_is_valid(border_buf))
	end)

	it("keeps the centered and input popup compatibility interfaces", function()
		local float = require("opencode.ui.float")
		local popup, bufnr = float.create_centered_popup({ title = " Details ", width = 24, height = 4 })
		assert.equals(bufnr, popup.bufnr)
		popup:mount()
		assert.equals("opencode_float", vim.bo[bufnr].filetype)
		popup:render({ "detail" }, { { line = 0, col = 0, end_col = 6, hl_group = "Title" } })
		assert.equals("detail", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
		popup:unmount()

		local submitted
		local field = float.create_input_popup({
			title = " Label ", prompt = "Account:", default = "existing",
			on_submit = function(value) submitted = value end,
		})
		local input_buf = field.input.bufnr
		assert.equals("Account: existing", vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)[1])
		local callback
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(input_buf, "i")) do
			if map.lhs == "<CR>" then callback = map.callback end
		end
		assert.is_function(callback)
		callback()
		assert.equals("existing", submitted)
		assert.is_false(vim.api.nvim_buf_is_valid(input_buf))
	end)

	it("pastes and scrolls a long key with Cmd+V while keeping the TUI dialog intact", function()
		local observed, submitted = {}, nil
		local key = string.rep("public-test-key-", 8) .. "tail"
		local original_paste = vim.paste
		local getreg = require("luassert.stub")(vim.fn, "getreg", function(register)
			assert.equals("+", register)
			return key .. "\r\nignored"
		end)
		vim.defer_fn(function()
			observed.bufnr = vim.api.nvim_get_current_buf()
			vim.api.nvim_input("prefix-<D-v>")
			vim.defer_fn(function()
				observed.layout = vim.api.nvim_buf_get_lines(observed.bufnr, 0, -1, false)
				observed.cursor = vim.api.nvim_win_get_cursor(0)
				observed.view = vim.fn.winsaveview()
				observed.config = vim.api.nvim_win_get_config(0)
				observed.modifiable = vim.bo[observed.bufnr].modifiable
				observed.pending = submitted == nil
				vim.api.nvim_input("\r")
			end, 30)
		end, 30)
		local ok, err = pcall(require("opencode.ui.float").create_input_popup, {
			title = " Connect OpenRouter ", password = true, on_submit = function(value) submitted = value end,
		})
		getreg:revert()
		assert.is_true(ok, tostring(err))
		assert.equals("prefix-" .. key, submitted)
		assert.equals("  " .. submitted:sub(-55) .. " ", observed.layout[4])
		assert.is_truthy(observed.layout[2]:find("Connect OpenRouter", 1, true))
		assert.equals("  enter submit", observed.layout[6])
		assert.same({ 4, 57 }, observed.cursor)
		assert.equals(0, observed.view.leftcol)
		assert.equals("editor", observed.config.relative)
		assert.equals(math.floor((vim.o.lines - vim.o.cmdheight) / 4), observed.config.row)
		assert.is_false(observed.modifiable)
		assert.is_true(observed.pending)
		assert.is_false(vim.api.nvim_buf_is_valid(observed.bufnr))
		assert.equals(original_paste, vim.paste)
		assert.equals(original_win, vim.api.nvim_get_current_win())
	end)

	it("shows typed and pasted credentials like TUI and deletes the buffer on close", function()
		local float = require("opencode.ui.float")
		local observed, submitted = {}, nil
		local original_paste = vim.paste
		vim.defer_fn(function()
			observed.bufnr = vim.api.nvim_get_current_buf()
			observed.relative = vim.api.nvim_win_get_config(0).relative
			observed.width = vim.api.nvim_win_get_width(0)
			observed.height = vim.api.nvim_win_get_height(0)
			observed.winhighlight = vim.wo.winhighlight
			observed.layout = vim.api.nvim_buf_get_lines(observed.bufnr, 0, -1, false)
			observed.initial = observed.layout[4]
			vim.api.nvim_input(">secrex\bt")
			vim.defer_fn(function()
				observed.mask = vim.api.nvim_buf_get_lines(observed.bufnr, 3, 4, false)[1]
				vim.api.nvim_input("\r")
			end, 30)
		end, 30)
		float.create_input_popup({ title = " Connect OpenRouter ", prompt = "API key", password = true,
			on_submit = function(value)
				submitted = value
				observed.closed_on_submit = not vim.api.nvim_buf_is_valid(observed.bufnr)
			end })
		assert.not_equals("", observed.relative)
		assert.equals(60, observed.width)
		assert.equals(7, observed.height)
		assert.is_truthy(observed.winhighlight:find("Normal:NormalFloat", 1, true))
		assert.is_truthy(observed.layout[2]:find("Connect OpenRouter", 1, true))
		assert.is_truthy(observed.layout[2]:find("esc", 1, true))
		assert.equals("  enter submit", observed.layout[6])
		assert.equals("  API key ", observed.initial)
		assert.equals("  >secret ", observed.mask)
		assert.equals(">secret", submitted)
		assert.is_true(observed.closed_on_submit)
		assert.equals(original_paste, vim.paste)
		assert.equals(original_win, vim.api.nvim_get_current_win())

		local cancelled
		vim.defer_fn(function()
			observed.bufnr = vim.api.nvim_get_current_buf()
			vim.api.nvim_paste("pasted-key\nignored", false, -1)
			observed.pasted_mask = vim.api.nvim_buf_get_lines(observed.bufnr, 3, 4, false)[1]
			vim.api.nvim_input("\27")
		end, 30)
		float.create_input_popup({ password = true,
			on_submit = function() submitted = "unexpected" end,
			on_cancel = function() cancelled = true end })
		assert.equals("  pasted-key ", observed.pasted_mask)
		assert.is_true(cancelled)
		assert.equals(">secret", submitted)
		assert.is_false(vim.api.nvim_buf_is_valid(observed.bufnr))
		assert.equals(original_paste, vim.paste)

		cancelled = nil
		vim.defer_fn(function() vim.api.nvim_set_current_win(original_win) end, 30)
		float.create_input_popup({ password = true, on_cancel = function() cancelled = true end })
		assert.is_true(cancelled)
		assert.equals(original_paste, vim.paste)
	end)
end)
