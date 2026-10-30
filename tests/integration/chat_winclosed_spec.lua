-- Split layouts once registered no WinClosed handler, leaving state.visible
-- true and animation timers mutating a buffer with no window.
describe("opencode chat window close", function()
	it("tears down and reopens split chat windows closed directly", function()
		local function wait_for(predicate, message)
			assert.is_truthy(vim.wait(500, predicate, 10), message)
		end
		vim.o.columns, vim.o.lines = 120, 36
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "vertical", position = "right", width = 40 } })
		local app_state = require("opencode.state")
		local chat = require("opencode.ui.chat")
		local chat_state = require("opencode.ui.chat.state").state
		require("opencode.sync").clear_all()
		app_state.reset()
		chat.create()
		require("opencode.session").set_active("winclosed-session", "WinClosed Session", { preserve_cache = true })

		chat.open()
		local winid = chat_state.winid
		assert.is_truthy(winid and vim.api.nvim_win_is_valid(winid), "split chat window should exist")
		vim.api.nvim_win_close(winid, true)
		wait_for(function() return chat_state.visible == false end, "WinClosed should clear chat visibility")
		assert.is_nil(chat_state.winid)

		chat.open()
		wait_for(function() return chat_state.visible == true end, "chat should reopen after a direct window close")
		assert.is_truthy(chat_state.winid and vim.api.nvim_win_is_valid(chat_state.winid))
		chat.close()
		assert.is_false(chat_state.visible)
		assert.is_nil(chat_state.winid)

		chat.open()
		vim.api.nvim_set_current_win(chat_state.winid)
		vim.cmd("only")
		chat.close()
		assert.is_false(chat_state.visible)
		assert.equals(1, #vim.api.nvim_tabpage_list_wins(0), "closing the last chat leaves an editor window")
	end)
end)
