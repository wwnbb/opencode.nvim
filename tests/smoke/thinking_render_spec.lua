describe("v2 Thought rendering", function()
	it("uses current config and renders collapsed and expanded reasoning", function()
		local thinking = require("opencode.ui.thinking")
		local activity = require("opencode.ui.chat.activity")
		local app_state = require("opencode.state")
		local previous = app_state.get_config()
		local ok, err = xpcall(function()
			app_state.set_config({ thinking = { enabled = false } })
			assert.is_false(thinking.is_enabled())
			assert.is_nil(activity.kind({ type = "reasoning", text = "hidden" }))

			app_state.set_config({ thinking = { enabled = true, highlight = "String", header_highlight = "ErrorMsg" } })
			assert.is_true(thinking.is_enabled())
			local part = { id = "reason", type = "reasoning", text = "**Plan**\n\nfirst line\nsecond line",
				time = { created = 100, completed = 316 } }
			local group = { id = part.id, kind = "thought", completed = true,
				refs = { { part = part, message = { id = "message" } } } }
			local collapsed = activity.render(group, false).lines
			assert.equals("+ Thought: Plan · 216ms", vim.trim(collapsed[1]))
			assert.equals(2, #collapsed)
			local expanded = activity.render(group, true).lines
			assert.equals("- Thought · 216ms", vim.trim(expanded[1]))
			assert.is_truthy(table.concat(expanded, "\n"):find("▏  second line", 1, true))
		end, debug.traceback)
		app_state.set_config(previous)
		if not ok then error(err, 0) end
	end)

	it("uses the chat buffer tabstop when wrapping panel content", function()
		local render = require("opencode.ui.chat.render")
		local chat_state = require("opencode.ui.chat.state").state
		local previous_bufnr, previous_winid = chat_state.bufnr, chat_state.winid
		local winid = vim.api.nvim_get_current_win()
		local previous_buf = vim.api.nvim_win_get_buf(winid)
		local chat_bufnr = vim.api.nvim_create_buf(false, true)
		local foreign_bufnr = vim.api.nvim_create_buf(false, true)
		local ok, err = xpcall(function()
			vim.api.nvim_win_set_buf(winid, foreign_bufnr)
			chat_state.bufnr, chat_state.winid = chat_bufnr, winid
			vim.bo[chat_bufnr].tabstop = 2
			vim.bo[foreign_bufnr].tabstop = 8
			assert.equals(1, #render.wrap_text_with_ranges("a\tb", 4))
			chat_state.bufnr = nil
			local initial_col = render.wrap_text_with_ranges("\tX", 5, { initial_col = 3 })
			assert.equals(2, #initial_col)
			assert.equals(1, initial_col[1].byte_end)
		end, debug.traceback)
		chat_state.bufnr, chat_state.winid = previous_bufnr, previous_winid
		vim.api.nvim_win_set_buf(winid, previous_buf)
		vim.api.nvim_buf_delete(chat_bufnr, { force = true })
		vim.api.nvim_buf_delete(foreign_bufnr, { force = true })
		if not ok then error(err, 0) end
	end)
end)
