describe("shared layout tabbar mouse input", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.request("nvim_ui_attach", { 100, 30, { rgb = true, ext_linegrid = true } })
		editor.lua([[
			vim.o.mouse = "a"
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab", session_tabs = { persist = false } } })
			require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
			local sessions = require("opencode.session")
			_G.chat, _G.workspace = require("opencode.ui.chat"), require("opencode.ui.chat.workspace")
			local function seed(id) local s = { id = id, title = id }; sessions.remember(s); return s end
			seed("mouse-a"); sessions.set_active("mouse-a", "mouse-a")
			chat.open()
			_G.first = workspace.current().id
			chat.create_split(chat.get_view(), seed("mouse-b"), "vertical")
			chat.create_layout(seed("mouse-c"))
			_G.second = workspace.current().id
		]])
	end)
	after_each(function() if editor then editor.close() end end)

	local function click(title)
		local position = editor.lua([[
			local win = require("opencode.ui.chat.workspace_bar").winid()
			local line = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, 1, false)[1]
			local first = assert(line:find(..., 1, true))
			return { vim.api.nvim_win_get_position(win)[1], vim.fn.strdisplaywidth(line:sub(1, first - 1)) }
		]], { title })
		editor.request("nvim_input_mouse", { "left", "press", "", 0, position[1], position[2] })
		editor.request("nvim_input_mouse", { "left", "release", "", 0, position[1], position[2] })
	end
	local function selected(name)
		return vim.wait(2000, function() return editor.lua("return workspace.current().id == _G[...]", { name }) end, 10)
	end

	it("selects another layout with the first click from a chat pane", function()
		for _ = 1, 3 do
			click("mouse-a")
			assert.is_true(selected("first"))
			assert.is_true(editor.lua("return vim.api.nvim_get_current_win() == chat.get_winid()"))
			click("mouse-c")
			assert.is_true(selected("second"))
		end
	end)

	it("selects with the first click from a file pane and retains its unsaved text", function()
		editor.lua([[
			vim.cmd("rightbelow new")
			_G.file = vim.api.nvim_get_current_buf()
			vim.api.nvim_buf_set_lines(file, 0, -1, false, { "Unsaved mouse test" })
		]])
		click("mouse-a")
		assert.is_true(selected("first"))
		click("mouse-c")
		assert.is_true(selected("second"))
		assert.same({ "Unsaved mouse test" }, editor.lua("return vim.api.nvim_buf_get_lines(file, 0, -1, false)"))
		assert.is_true(editor.lua("return vim.bo[file].modified"))
	end)

	it("respects disabled mouse selection while keeping keyboard selection", function()
		editor.lua([[
			local state = require("opencode.state")
			local config = state.get_config()
			config.session_tabs = { keymaps = { select = false } }
			state.set_config(config)
			require("opencode.ui.chat.workspace_bar").update()
		]])
		click("mouse-a")
		assert.is_true(vim.wait(2000, function()
			return editor.lua("return vim.api.nvim_get_current_win() == require('opencode.ui.chat.workspace_bar').winid()")
		end, 10))
		assert.is_true(editor.lua("return workspace.current().id == second"))
		editor.feed("<CR>")
		assert.is_true(selected("first"))
	end)
end)
