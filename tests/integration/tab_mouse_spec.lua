describe("native layout tabline mouse input", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.request("nvim_ui_attach", { 100, 30, { rgb = true, ext_linegrid = true } })
		editor.lua([[
			vim.o.mouse, vim.o.mousemodel = "a", "extend"
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab" } })
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

	local function click(title, button, modifiers)
		local position = editor.lua([[
			local line = vim.api.nvim_eval_statusline(vim.o.tabline, { use_tabline = true, maxwidth = vim.o.columns }).str
			local first = assert(line:find(..., 1, true))
			return { 0, vim.fn.strwidth(line:sub(1, first - 1)) }
		]], { title })
		editor.request("nvim_input_mouse", { button or "left", "press", modifiers or "", 0, position[1], position[2] })
		editor.request("nvim_input_mouse", { button or "left", "release", modifiers or "", 0, position[1], position[2] })
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
		assert.is_true(editor.lua("return workspace.current().id == second"))
		assert.is_true(editor.lua("return vim.api.nvim_get_current_win() == chat.get_winid()"))
		editor.feed("1gt")
		assert.is_true(selected("first"))
	end)

	it("respects configured mouse buttons and modifiers without native tab actions", function()
		editor.lua([[
			local state = require("opencode.state")
			local config = state.get_config()
			config.session_tabs = { keymaps = { select = "<MiddleMouse>" } }; state.set_config(config)
		]])
		click("mouse-a")
		assert.is_true(editor.lua("return workspace.current().id == second"))
		click("mouse-a", "middle")
		assert.is_true(selected("first"))
		click("mouse-c", "right")
		assert.is_true(editor.lua("return workspace.current().id == first and #workspace.list() == 2"))
		assert.is_true(editor.lua([[
			local state = require("opencode.state")
			local config = state.get_config()
			config.session_tabs = { keymaps = { select = "<C-RightMouse>" } }; state.set_config(config)
			__opencode_workspace_tab_click(second, 1, "r", "    ")
			assert(workspace.current().id == first)
			__opencode_workspace_tab_click(second, 1, "r", "c   ")
			return workspace.current().id == second
		]]))
	end)

	it("consumes clicks on the empty tabline tail without switching or creating native tabs", function()
		local before = editor.lua("return { vim.api.nvim_get_current_tabpage(), #vim.api.nvim_list_tabpages(), workspace.current().id }")
		for _, button in ipairs({ "left", "middle", "right" }) do
			for _ = 1, 2 do
				editor.request("nvim_input_mouse", { button, "press", "", 0, 0, 99 })
				editor.request("nvim_input_mouse", { button, "release", "", 0, 0, 99 })
			end
		end
		assert.same(before, editor.lua("return { vim.api.nvim_get_current_tabpage(), #vim.api.nvim_list_tabpages(), workspace.current().id }"))
	end)
end)
