describe("opencode chat help", function()
	for _, cancel_key in ipairs({ false, "<leader>qc" }) do
		it("shows the configured question cancel key " .. tostring(cancel_key), function()
			local popup = require("opencode.ui.chat.help").show({ keymaps = { cancel_question = cancel_key } })
			local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
			popup:unmount()
			local cancel_line
			for _, line in ipairs(lines) do
				if line:find("Cancel question", 1, true) then cancel_line = line end
			end
			assert.is_truthy(cancel_line)
			assert.is_truthy(cancel_line:find(cancel_key or "(disabled)", 1, true))
		end)
	end

	it("fits the viewport, scrolls to the last section, and cleans up both windows", function()
		local previous = vim.api.nvim_get_current_win()
		local help = require("opencode.ui.chat.help")
		local popup = help.show()
		local frame_win, content_win = popup.frame.winid, popup.winid
		assert.equals(content_win, popup.content.winid)
		assert(vim.bo[popup.bufnr].filetype == "opencode_help", "help must be recognized by float focus handling")
		for _, win in ipairs({ frame_win, content_win }) do
			local pos = vim.api.nvim_win_get_position(win)
			assert(pos[1] >= 0 and pos[2] >= 0)
			assert(pos[1] + vim.api.nvim_win_get_height(win) <= vim.o.lines - vim.o.cmdheight)
			assert(pos[2] + vim.api.nvim_win_get_width(win) <= vim.o.columns)
		end
		assert(help.show() == popup, "reopening must reuse the current help")
		vim.api.nvim_feedkeys("G", "xt", false)
		assert(vim.api.nvim_win_is_valid(content_win), "navigation must not close the help")
		assert(vim.api.nvim_win_get_cursor(content_win)[1] == vim.api.nvim_buf_line_count(popup.bufnr))
		assert(vim.api.nvim_buf_get_lines(popup.bufnr, -2, -1, false)[1]:find("Jump to file N", 1, true))
		popup:unmount()
		assert(not vim.api.nvim_win_is_valid(frame_win) and not vim.api.nvim_win_is_valid(content_win))
		assert(vim.api.nvim_get_current_win() == previous)
		local reopened = help.show()
		assert(reopened ~= popup, "a closed help creates a fresh popup")
		assert(vim.api.nvim_win_is_valid(reopened.frame.winid))
		assert(vim.api.nvim_win_is_valid(reopened.winid))
		reopened:close()
		vim.wait(20)
	end)

	it("opens help in the current pane when the previous help and chat belong to another tab", function()
		local help = require("opencode.ui.chat.help")
		local state = require("opencode.ui.chat.state").state
		local saved = { visible = state.visible, winid = state.winid, tabpage = state.tabpage }
		local previous, columns = vim.api.nvim_get_current_win(), vim.o.columns
		local next_tab, first, second
		local ok, err = xpcall(function()
			vim.o.columns = 100
			state.visible, state.winid, state.tabpage = true, previous, vim.api.nvim_get_current_tabpage()
			first = help.show()
			local first_frame, first_content = first.frame.winid, first.winid
			vim.cmd("tabnew")
			vim.cmd("vsplit")
			next_tab = vim.api.nvim_get_current_tabpage()
			local pane = vim.api.nvim_get_current_win()
			second = help.show()
			assert.equals(next_tab, vim.api.nvim_get_current_tabpage())
			assert.is_true(first ~= second)
			assert.is_false(vim.api.nvim_win_is_valid(first_frame))
			assert.is_false(vim.api.nvim_win_is_valid(first_content))
			assert.is_true(vim.api.nvim_win_get_width(second.frame.winid) <= vim.api.nvim_win_get_width(pane))
			assert.equals(second, help.show())
		end, debug.traceback)
		if second then second:close(false) end
		if first then first:close(false) end
		state.visible, state.winid, state.tabpage = saved.visible, saved.winid, saved.tabpage
		if next_tab and vim.api.nvim_tabpage_is_valid(next_tab) then
			vim.api.nvim_set_current_tabpage(next_tab)
			vim.cmd("tabclose!")
		end
		vim.api.nvim_set_current_win(previous)
		vim.o.columns = columns
		assert.is_true(ok, err)
	end)

	it("wraps long configured keys and descriptions when resized", function()
		local popup = require("opencode.ui.chat.help").show({
			keymaps = { close_session = "<leader>оченьдлиннаяклавиша", cancel_pending = false },
		})
		local previous_columns = vim.o.columns
		vim.o.columns = 36
		vim.api.nvim_exec_autocmds("VimResized", {})
		for _, part in ipairs({ popup, popup.frame }) do
			local width = vim.api.nvim_win_get_width(part.winid)
			for _, line in ipairs(vim.api.nvim_buf_get_lines(part.bufnr, 0, -1, false)) do
				assert(vim.fn.strdisplaywidth(line) <= width, "help text exceeds the window: " .. line)
			end
		end
		popup:unmount()
		vim.o.columns = previous_columns
		vim.wait(20)
	end)
end)
