describe("input resize", function()
	it("keeps draft, focus and both input surfaces inside a smaller parent", function()
		local app, chat, input = require("opencode"), require("opencode.ui.chat"), require("opencode.ui.input")
		local old_columns, old_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 120, 40
		app.setup({ server = { auto_start = false }, chat = { width = 80, close_on_focus_lost = false }, lualine = { enabled = false } })
		chat.open(); chat.focus_input()
		local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Draft survives resize Привет" })
		vim.o.columns, vim.o.lines = 80, 30
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.is_true(vim.wait(1000, function()
			for _, id in ipairs(input.get_winids()) do
				local pos = vim.api.nvim_win_get_position(id)
				if pos[1] + vim.api.nvim_win_get_height(id) >= vim.o.lines - vim.o.cmdheight then return false end
			end
			return #input.get_winids() == 2
		end, 10))
		assert.equals(win, vim.api.nvim_get_current_win())
		assert.same({ "Draft survives resize Привет" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		input.close(false)
		assert.equals(0, #vim.api.nvim_get_autocmds({ group = "OpenCodeInputResize" }))
		chat.close(); require("opencode.cleanup").reset_all()
		vim.o.columns, vim.o.lines = old_columns, old_lines
	end)
end)
