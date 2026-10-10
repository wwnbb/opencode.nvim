describe("shell composer", function()
	local app, chat, input = require("opencode"), require("opencode.ui.chat"), require("opencode.ui.input")
	local send_stub, saved_columns, saved_lines
	local function key(mode, lhs)
		local expected = vim.api.nvim_replace_termcodes(lhs, true, false, true)
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), mode)) do
			if vim.api.nvim_replace_termcodes(mapping.lhs, true, false, true) == expected then return mapping.callback end
		end
		error("Missing composer key " .. lhs)
	end
	before_each(function()
		saved_columns, saved_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 120, 45
		app.setup({ server = { auto_start = false }, chat = { close_on_focus_lost = false }, lualine = { enabled = false } })
		require("opencode.state").set_session("ses_shell", "Shell")
	end)
	after_each(function()
		if send_stub then send_stub:revert(); send_stub = nil end
		input.close(false); chat.close(); require("opencode.cleanup").reset_all()
		vim.o.columns, vim.o.lines = saved_columns, saved_lines
	end)
	it("toggles the visible composer and sends slash-like shell text through the shell action", function()
		local captured
		send_stub = require("luassert.stub")(require("opencode.actions"), "send", function(text, opts) captured = { text = text, opts = opts } end)
		chat.open(); chat.focus_input()
		assert.equals("normal", input.get_mode())
		key("n", "<C-\\>")()
		assert.equals("shell", input.get_mode())
		local info = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(input.get_winids()[2]), 0, -1, false)[1]
		assert.truthy(info:find("Shell", 1, true))
		local command = "/bin/echo 'Привет @agent /rename image.png'"
		vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { command })
		key("n", "<C-g>")()
		assert.equals(command, captured.text)
		assert.equals("shell", captured.opts.mode)
		assert.same({}, captured.opts.parts)
		chat.focus_input()
		input.set_mode("shell"); input.close()
		chat.focus_input()
		assert.equals("shell", input.get_mode())
		key("n", "<C-\\>")()
		assert.equals("normal", input.get_mode())
	end)
end)
