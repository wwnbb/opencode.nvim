describe("workspace tabline cleanup", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.request("nvim_ui_attach", { 100, 35, { rgb = true, ext_linegrid = true } })
		editor.lua([[
			vim.o.tabline, vim.o.showtabline = "%#TabLine#Editor tabs", 0
			_G.editor_tab = vim.api.nvim_get_current_tabpage()
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab", session_tabs = { persist = false } } })
			require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
			_G.sessions, _G.chat = require("opencode.session"), require("opencode.ui.chat")
			_G.workspace, _G.cs = require("opencode.ui.chat.workspace"), require("opencode.ui.chat.state")
			_G.bar = require("opencode.ui.chat.workspace_bar")
			_G.settle = function() vim.wait(80, function() return false end, 5) end
			sessions.set_active("bar-cleanup", "Cleanup"); chat.open(); settle()
			_G.first = chat.get_view()
			_G.restored = function() return vim.o.tabline == "%#TabLine#Editor tabs" and vim.o.showtabline == 0 end
		]])
	end)

	after_each(function() if editor then editor.close() end end)

	for _, operation in ipairs({ "close", "reset", "native close", "native leave" }) do
		it("restores both editor options after " .. operation, function()
			assert.is_true(editor.lua([[
				local operation = ...
				if operation == "close" then workspace.close_current()
				elseif operation == "reset" then workspace.reset()
				elseif operation == "native close" then vim.cmd("tabclose!")
				else vim.api.nvim_set_current_tabpage(editor_tab) end
				settle()
				assert(restored())
				bar.remove(); bar.remove()
				return restored()
			]], { operation }))
		end)
	end

	it("restores options on disable and reclaims them without moving a multiline composer", function()
		assert.is_true(editor.lua([[
			chat.focus_input(); settle()
			local input = require("opencode.ui.input")
			input.set_pending_text("Unsaved\ncomposer"); settle()
			local window, buffer = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
			vim.api.nvim_win_set_cursor(window, { 2, 3 })
			local state = require("opencode.state")
			local config = vim.deepcopy(state.get_config())
			config.chat.session_tabs.enabled = false; state.set_config(config); settle()
			assert(restored())
			config.chat.session_tabs.enabled = true; state.set_config(config); settle()
			assert(vim.o.showtabline == 2 and not restored())
			assert(vim.api.nvim_get_current_win() == window and vim.api.nvim_get_current_buf() == buffer)
			assert(input.is_visible() and input.owner_view() == first and input.get_pending_text() == "Unsaved\ncomposer")
			return vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 2, 3 })
		]]))
	end)

	it("restores the other option and remains retryable when the native option API raises", function()
		assert.is_true(editor.lua([[
			local set_option, called = vim.api.nvim_set_option_value, false
			vim.api.nvim_set_option_value = function(name, value, opts)
				if name == "tabline" then called = true; return set_option("opencode_invalid_tabline_option", value, opts) end
				return set_option(name, value, opts)
			end
			local ok, err = pcall(bar.remove)
			vim.api.nvim_set_option_value = set_option
			assert(called and not ok and tostring(err):find("opencode_invalid_tabline_option", 1, true), tostring(err))
			assert(vim.o.showtabline == 0)
			bar.remove()
			assert(restored())
			bar.ensure()
			assert(vim.o.showtabline == 2)
			bar.remove(); bar.remove()
			return restored()
		]]))
	end)

	it("does not override editor changes when updating a parked workspace", function()
		assert.is_true(editor.lua([[
			chat.toggle(); settle()
			vim.o.tabline, vim.o.showtabline = "New editor renderer", 1
			bar.update(); bar.remove()
			return vim.o.tabline == "New editor renderer" and vim.o.showtabline == 1
		]]))
	end)
end)
