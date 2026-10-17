describe("tab layout recovery", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.lua([[
			vim.o.lines, vim.o.columns = 60, 120
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab", session_tabs = { persist = false } } })
			require("opencode.client").get_messages = function(_, _, cb) cb(nil, {}) end
			chat = require("opencode.ui.chat")
			workspace = require("opencode.ui.chat.workspace")
			views = require("opencode.ui.chat.state")
			function seed(id)
				local session = { id = id, title = id }
				require("opencode.session").remember(session)
				return session
			end
			seed("recovery-a"); require("opencode.session").set_active("recovery-a", "A")
			chat.open()
			first, original = chat.get_view(), workspace.current().id
		]])
	end)
	after_each(function() if editor then editor.close() end end)

	it("preserves both layouts when the terminal cannot fit the saved splits", function()
		editor.lua([[
			for i = 1, 6 do chat.create_split(chat.get_view(), seed("split-" .. i), "horizontal") end
			chat.create_layout(seed("recovery-b"))
			local second = workspace.current().id
			vim.o.lines = 10
			local ok, err = pcall(workspace.select, original)
			assert(not ok and tostring(err):find("E36", 1, true), tostring(err))
			assert(workspace.current().id == second, "failed restore must retain the previous layout")
			assert(chat.get_view().visible and vim.api.nvim_win_is_valid(chat.get_view().winid))
			vim.o.lines = 60
			for _ = 1, 2 do
				assert(workspace.select(original))
				assert(#vim.api.nvim_tabpage_list_wins(0) == 8, "all seven panes must survive the failed restore")
				assert(workspace.select(second))
			end
		]])
	end)

	it("recovers when both the initial restore and its rollback fail", function()
		editor.lua([[
			for i = 1, 5 do chat.create_split(chat.get_view(), seed("first-" .. i), "horizontal") end
			chat.create_layout(seed("recovery-b"))
			local second = workspace.current().id
			for i = 1, 5 do chat.create_split(chat.get_view(), seed("second-" .. i), "horizontal") end
			local set_buf = vim.api.nvim_win_set_buf
			vim.api.nvim_win_set_buf = function() error("injected restore failure") end
			local ok = pcall(workspace.select, original)
			vim.api.nvim_win_set_buf = set_buf
			assert(not ok)
			assert(workspace.select(second))
			assert(#vim.api.nvim_tabpage_list_wins(0) == 7)
			assert(workspace.select(original))
			assert(#vim.api.nvim_tabpage_list_wins(0) == 7)
		]])
	end)

	it("dismisses inline proposals before switching while preserving manual file edits", function()
		editor.lua([[
			local edits = views.module(first, require("opencode.ui.chat.edits"))
			local path = vim.fn.tempname()
			vim.fn.writefile({ "before" }, path)
			edits.open_inline_diff_split({ filepath = path, before = "before\n", after = "after\n" })
			local actual = vim.api.nvim_get_current_buf()
			vim.bo[actual].bufhidden = "wipe"
			vim.api.nvim_buf_set_lines(actual, 0, -1, false, { "manual unsaved edit" })
			chat.create_layout(seed("recovery-b"))
			workspace.select(original)
			for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
				assert(not vim.wo[win].diff, "restored panes must not retain an orphaned diff")
				assert(not edits.is_inline_diff_window(win))
				assert(not vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)):find("[proposed]", 1, true))
			end
			assert(vim.api.nvim_buf_is_valid(actual) and vim.bo[actual].modified)
			assert(vim.api.nvim_buf_get_lines(actual, 0, -1, false)[1] == "manual unsaved edit")
			vim.fn.delete(path)
		]])
	end)

	it("leaves the original layout usable when new-view setup fails", function()
		editor.lua([[
			for _, method in ipairs({ "nvim_create_buf", "nvim_win_set_buf" }) do
				local saved, failed = vim.api[method], false
				vim.api[method] = function(...)
					if not failed then failed = true; error("injected layout failure") end
					return saved(...)
				end
				local ok = pcall(chat.create_layout, seed("failed-" .. method))
				vim.api[method] = saved
				assert(not ok)
				assert(#workspace.list() == 1, "failed creation must not leave a layout behind")
				assert(workspace.current().id == original)
				assert(first.visible and vim.api.nvim_win_is_valid(first.winid))
				assert(#views.all() == 1, "failed creation must release its view")
			end
			chat.create_layout(seed("recovery-success"))
			assert(#workspace.list() == 2)
			assert(workspace.select(original))
		]])
	end)

	it("restores resize and tab-refresh hooks after closing and reopening the default view", function()
		editor.lua([[
			workspace.close_current()
			chat.open()
			assert(chat.get_view() == first)
			for _, prefix in ipairs({ "OpenCodeChatResize_", "OpenCodeSessionTabs_" }) do
				assert(#vim.api.nvim_get_autocmds({ group = prefix .. first.id }) > 0)
			end
			local owned, renders = chat.for_view(first), 0
			local render = owned.do_render
			owned.do_render = function(...) renders = renders + 1; return render(...) end
			vim.api.nvim_exec_autocmds("VimResized", {})
			assert(vim.wait(1000, function() return renders > 0 end, 5), "reopened view must respond to resize")
		]])
	end)

	for _, scoped in ipairs({ false, true }) do
		it("preserves window directories and inherited " .. (scoped and "tab" or "global") .. " scope", function()
			editor.lua([[
				local scoped = ...
				local global = vim.fn.getcwd(-1, -1)
				local root = vim.fn.tempname()
				for _, dir in ipairs({ "one", "two", "shared" }) do vim.fn.mkdir(root .. "/" .. dir, "p") end
				root = vim.uv.fs_realpath(root)
				local second = chat.create_split(first, seed("cwd-b"), "vertical")
				local third = chat.create_split(second, seed("cwd-c"), "horizontal")
				vim.api.nvim_win_call(first.winid, function() vim.cmd.lcd(root .. "/one") end)
				vim.api.nvim_win_call(second.winid, function() vim.cmd.lcd(root .. "/two") end)
				local bar = require("opencode.ui.chat.workspace_bar").winid()
				vim.api.nvim_win_call(bar, function() vim.cmd.lcd(root .. "/one") end)
				chat.create_layout(seed("cwd-d"))
				if scoped then vim.cmd.tcd(root .. "/shared") end
				assert(workspace.select(original))
				local function cwd(view)
					return { vim.fn.getcwd(view.winid), vim.fn.haslocaldir(view.winid) }
				end
				assert(vim.deep_equal({ root .. "/one", 1 }, cwd(first)), vim.inspect(cwd(first)))
				assert(vim.deep_equal({ root .. "/two", 1 }, cwd(second)), vim.inspect(cwd(second)))
				assert(vim.deep_equal({ scoped and root .. "/shared" or global, 0 }, cwd(third)),
					"unscoped pane must inherit the current tab/global directory: " .. vim.inspect({ cwd(third), global }))
				assert(vim.fn.getcwd(-1, -1) == global, vim.inspect({ vim.fn.getcwd(-1, -1), global }))
				vim.cmd.cd(global)
				vim.fn.delete(root, "rf")
			]], { scoped })
		end)
	end
end)
