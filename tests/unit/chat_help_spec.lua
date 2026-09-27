describe("opencode chat help", function()
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
