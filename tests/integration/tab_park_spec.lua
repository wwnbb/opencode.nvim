describe("parking the OpenCode tab workspace", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.request("nvim_ui_attach", { 120, 40, { rgb = true, ext_linegrid = true, ext_messages = true } })
		editor.lua([[
			vim.cmd("tabnew")
			_G.editor_window = vim.api.nvim_get_current_win()
			_G.editor_tabs = vim.api.nvim_list_tabpages()
			_G.custom_tabline = "%#TabLineSel#Editor tabs%#TabLineFill#"
			vim.o.tabline = custom_tabline
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab" } })
			require("opencode.client").get_messages = function(_, _, callback) callback(nil, {}) end
			_G.chat, _G.workspace = require("opencode.ui.chat"), require("opencode.ui.chat.workspace")
			_G.views, _G.state = require("opencode.ui.chat.state"), require("opencode.state")
			_G.sessions, _G.input = require("opencode.session"), require("opencode.ui.input")
			_G.history = require("opencode.ui.input.history")
			_G.settle = function() vim.wait(60, function() return false end, 5) end
			_G.seed = function(id)
				local session = { id = id, title = id, directory = vim.fn.getcwd() }
				sessions.remember(session)
				return session
			end
			_G.open = function(showtabline)
				vim.o.showtabline = showtabline or 1
				seed("park-a"); sessions.set_active("park-a", "park-a")
				chat.open(); settle()
				_G.first, _G.original = chat.get_view(), workspace.current().id
			end
		]])
	end)
	after_each(function() if editor then editor.close() end end)

	for _, showtabline in ipairs({ 0, 2 }) do
		it("restores editor options and retains layouts and drafts with showtabline=" .. showtabline, function()
			editor.lua([[
				local showtabline = ...
				open(showtabline)
				local second = chat.create_split(first, seed("park-b"), "vertical")
				vim.wo[first.winid].scrolloff, vim.wo[second.winid].scrolloff = 3, 7
				local width = vim.api.nvim_win_get_width(first.winid)
				chat.create_layout(seed("park-c"))
				workspace.select(original)
				chat.focus_view(first); chat.focus_input()
				input.set_pending_text("Keep this draft\nand its cursor")
				vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 4 })
				local order = vim.deepcopy(state.get_runtime_session_order())
				local host = views.workspace.tabpage
				chat.toggle()
				assert(workspace.is_parked() and not vim.api.nvim_tabpage_is_valid(host))
				assert(vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()))
				assert(vim.api.nvim_get_current_win() == editor_window)
				assert(vim.o.tabline == custom_tabline and vim.o.showtabline == showtabline)
				assert(#workspace.list() == 2 and workspace.current().id == original)
				assert(vim.deep_equal(order, state.get_runtime_session_order()))
				assert(history.get_pending("park-a") == "Keep this draft\nand its cursor")
				chat.toggle(); settle()
				assert(not workspace.is_parked() and views.workspace.tabpage ~= host)
				assert(#vim.api.nvim_list_tabpages() == #editor_tabs + 1)
				assert(#vim.api.nvim_tabpage_list_wins(views.workspace.tabpage) == 2)
				assert(vim.o.showtabline == 2 and vim.o.tabline ~= custom_tabline)
				assert(vim.api.nvim_win_get_width(first.winid) == width)
				assert(vim.wo[first.winid].scrolloff == 3 and vim.wo[second.winid].scrolloff == 7)
				assert(vim.wo[first.winid].winbar == "" and vim.wo[second.winid].winbar == "")
				chat.focus_view(first); chat.focus_input(); settle()
				assert(input.get_pending_text() == "Keep this draft\nand its cursor")
				assert(vim.deep_equal({ 2, 4 }, vim.api.nvim_win_get_cursor(input.get_winids()[1])))
			]], { showtabline })
		end)
	end

	it("parks after manual tab navigation and captures fresh editor options on reentry", function()
		editor.lua([[
			open()
			local host = views.workspace.tabpage
			vim.api.nvim_set_current_win(editor_window); settle()
			assert(workspace.is_parked() and not vim.api.nvim_tabpage_is_valid(host))
			assert(vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()))
			vim.o.tabline, vim.o.showtabline = "Updated editor tabs", 0
			assert(chat.focus_view(first)); settle()
			chat.toggle()
			assert(vim.api.nvim_get_current_win() == editor_window)
			assert(vim.o.tabline == "Updated editor tabs" and vim.o.showtabline == 0)
		]])
	end)

	for _, hidden in ipairs({ "wipe" }) do
		it("retains a focused modified file, tab directory and native tab variables", function()
			editor.lua([[
				local hidden = ...
				open()
				local global_directory = vim.fn.getcwd(-1, -1)
				vim.cmd.tcd("/tmp")
				local tab_directory = vim.fn.getcwd(-1)
				vim.cmd("let t:Preserved = {'name': 'workspace', 'Fn': {x -> x + 7}}")
				vim.cmd("rightbelow vsplit")
				local file, win = vim.api.nvim_create_buf(true, false), vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_buf(win, file)
				vim.api.nvim_buf_set_lines(file, 0, -1, false, { "unsaved file", "second line" })
				vim.bo[file].bufhidden = hidden
				vim.api.nvim_win_set_cursor(win, { 2, 3 })
				chat.toggle()
				assert(workspace.is_parked() and vim.api.nvim_buf_is_loaded(file) and vim.bo[file].modified)
				assert(vim.bo[file].bufhidden == hidden)
				chat.open(); settle()
				assert(vim.api.nvim_get_current_buf() == file)
				assert(vim.deep_equal({ 2, 3 }, vim.api.nvim_win_get_cursor(0)))
				assert(vim.fn.getcwd(-1) == tab_directory and vim.fn.getcwd(-1, -1) == global_directory,
					vim.inspect({ tab = vim.fn.getcwd(-1), expected_tab = tab_directory,
						global = vim.fn.getcwd(-1, -1), expected_global = global_directory }))
				assert(vim.fn.eval("t:Preserved.name") == "workspace" and vim.fn.eval("call(t:Preserved.Fn, [5])") == 12)
				assert(vim.deep_equal({ "unsaved file", "second line" }, vim.api.nvim_buf_get_lines(file, 0, -1, false)))
				chat.focus_view(first); chat.close(); settle()
				assert(not workspace.current().last_view)
				chat.open()
				assert(vim.api.nvim_get_current_buf() == file and #workspace.list() == 1)
				chat.toggle(); chat.open()
				assert(vim.api.nvim_get_current_buf() == file and #workspace.list() == 1)
			]], { hidden })
		end)
	end

	it("keeps a terminal job alive and usable across park and resume", function()
		editor.lua([[
			open()
			vim.cmd("rightbelow vnew")
			local terminal = vim.api.nvim_get_current_buf()
			local job = vim.fn.termopen({ "cat" })
			assert(job > 0)
			vim.bo[terminal].bufhidden = "wipe"
			chat.toggle()
			assert(workspace.is_parked() and vim.api.nvim_buf_is_loaded(terminal))
			assert(vim.bo[terminal].bufhidden == "wipe" and vim.b[terminal].terminal_job_id == job)
			assert(vim.fn.jobwait({ job }, 0)[1] == -1)
			chat.open()
			assert(vim.api.nvim_get_current_buf() == terminal and vim.b[terminal].terminal_job_id == job)
			assert(vim.fn.jobwait({ job }, 0)[1] == -1)
			vim.api.nvim_chan_send(job, "terminal after resume\n")
			assert(vim.wait(1000, function()
				return table.concat(vim.api.nvim_buf_get_lines(terminal, 0, -1, false), "\n")
					:find("terminal after resume", 1, true) ~= nil
			end, 10), "resumed terminal did not receive input")
			assert(vim.fn.jobstop(job) == 1)
		]])
	end)

	it("q keeps other layouts and the closed pane's session and draft", function()
		editor.lua([[
			open()
			history.set_pending("Preserve closed draft", {}, "park-b")
			local second = chat.create_layout(seed("park-b"))
			local host = views.workspace.tabpage
			vim.api.nvim_feedkeys("q", "xt", false); settle()
			assert(vim.api.nvim_tabpage_is_valid(host) and not workspace.is_parked())
			assert(#workspace.list() == 1 and workspace.current().id == original)
			assert(chat.get_view() == first and not views.valid(second))
			assert(state.is_runtime_session("park-b") and history.get_pending("park-b") == "Preserve closed draft")
		]])
	end)

	it("keeps parked splits when the editor closes chat and changes directory", function()
		editor.lua([[
			open()
			local second = chat.create_split(first, seed("park-b"), "vertical")
			chat.toggle()
			assert(workspace.is_parked() and first.suspended and second.suspended)
			-- Editor mappings may close chat before opening a file tree to switch projects.
			require("opencode").close(); require("opencode").close(); settle()
			vim.cmd.tcd(vim.fn.fnamemodify(vim.fn.getcwd(), ":h")); settle()
			assert(workspace.is_parked() and #workspace.list() == 1 and workspace.current().id == original)
			assert(views.valid(first) and views.valid(second) and first.suspended and second.suspended)
			assert(state.get_session().id == "park-b")
			chat.open(); settle()
			assert(#vim.api.nvim_tabpage_list_wins(views.workspace.tabpage) == 2)
			assert(first.visible and second.visible and first.workspace_id == second.workspace_id)
		]])
	end)

	it("does not retain the closed default pane when q closes its last split", function()
		editor.lua([[
			open()
			local second = chat.create_split(first, seed("park-b"), "vertical")
			local next_view = chat.create_layout(seed("park-c"))
			workspace.select(original)
			chat.close_view(first)
			chat.close_view(second)
			assert(#workspace.list() == 1 and workspace.current().id == next_view.workspace_id)
			assert(not first.workspace_id and not first.suspended)
			chat.close_view(next_view); settle()
			assert(#workspace.list() == 0 and vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()))
			assert(state.is_runtime_session("park-a") and state.is_runtime_session("park-b") and state.is_runtime_session("park-c"))
		]])
	end)

	for _, command in ipairs({ "close" }) do
		it("keeps native " .. command .. " destruction distinct from parking", function()
			editor.lua([[
				open()
				chat.create_layout(seed("park-b"))
				vim.cmd(...); settle()
				assert(not workspace.is_parked() and #workspace.list() == 0)
				assert(vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()))
				assert(vim.o.tabline == custom_tabline and vim.o.showtabline == 1)
			]], { command })
		end)
	end

	for _, fail in ipairs({ false, true }) do
		it("reparks background session work and restores editor focus (failure=" .. tostring(fail) .. ")", function()
			editor.lua([[
				local fail = ...
				open(); chat.toggle()
				local ok, err = pcall(require("opencode.session.focus").with_session_focus, first, function()
					chat.create_layout(seed("park-background"))
					if fail then error("background creation failed") end
				end)
				assert(ok ~= fail, tostring(err))
				if fail then assert(tostring(err):find("background creation failed", 1, true)) end
				assert(workspace.is_parked() and workspace.current().id == original)
				assert(#workspace.list() == 2 and vim.api.nvim_get_current_win() == editor_window)
				assert(vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()))
				assert(vim.o.tabline == custom_tabline)
				chat.open()
				assert(chat.get_view() == first)
			]], { fail })
		end)
	end

	it("retains the workspace after parking fails and permits a retry", function()
		editor.lua([[
			open()
			local close = vim.api.nvim_win_close
			vim.api.nvim_win_close = function() error("injected park close failure") end
			local ok, err = pcall(chat.toggle)
			vim.api.nvim_win_close = close
			assert(not ok and tostring(err):find("injected park close failure", 1, true), tostring(err))
			assert(#workspace.list() == 1 and state.is_runtime_session("park-a"))
			assert(views.valid(first) and not views.workspace.switching)
			workspace.park()
			assert(workspace.is_parked() and vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()))
			chat.open(); settle()
			assert(chat.get_view() == first and first.visible)
		]])
	end)

	it("keeps parked snapshots after a failed resume and restores them on retry", function()
		editor.lua([[
			open()
			chat.create_split(first, seed("park-b"), "vertical")
			chat.toggle()
			local tree, order = workspace.current().tree, vim.deepcopy(state.get_runtime_session_order())
			local set_option = vim.api.nvim_set_option_value
			vim.api.nvim_set_option_value = function(name, value, options)
				if name == "scrolloff" and options and options.scope == "local" then error("injected resume failure") end
				return set_option(name, value, options)
			end
			local ok, err = pcall(chat.open)
			vim.api.nvim_set_option_value = set_option
			assert(not ok and tostring(err):find("injected resume failure", 1, true), tostring(err))
			assert(workspace.is_parked() and workspace.current().tree == tree)
			assert(vim.deep_equal(order, state.get_runtime_session_order()))
			assert(vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()))
			assert(vim.api.nvim_get_current_win() == editor_window and vim.o.tabline == custom_tabline)
			chat.open(); settle()
			assert(#vim.api.nvim_tabpage_list_wins(views.workspace.tabpage) == 2)
			assert(first.visible and not views.workspace.switching)
		]])
	end)

	it("does not apply workspace state to the editor when a tab autocmd redirects resume", function()
		editor.lua([[
			open()
			vim.cmd.tcd("/tmp")
			vim.t.workspace_only = "keep in OpenCode"
			chat.toggle()
			local directory = vim.fn.getcwd(-1)
			vim.t.editor_only = "keep in editor"
			vim.api.nvim_create_autocmd("TabNewEntered", { once = true, callback = function()
				vim.api.nvim_set_current_win(editor_window)
			end })
			local ok, err = pcall(chat.open)
			assert(not ok, "redirected resume must leave its snapshot parked")
			assert(workspace.is_parked() and vim.api.nvim_get_current_win() == editor_window, tostring(err))
			assert(vim.t.workspace_only == nil and vim.t.editor_only == "keep in editor", "workspace variables leaked into editor")
			assert(vim.fn.getcwd(-1) == directory, "workspace directory replaced editor directory")
			assert(vim.deep_equal(editor_tabs, vim.api.nvim_list_tabpages()), "failed resume left an empty native tab")
			chat.open()
			assert(first.visible and vim.t.workspace_only == "keep in OpenCode")
		]])
	end)

	it("does not inherit an editor tab directory when resuming a global workspace", function()
		editor.lua([[
			open()
			local global_directory = vim.fn.getcwd(-1, -1)
			assert(vim.fn.haslocaldir(-1) == 0)
			chat.toggle()
			vim.cmd.tcd("/tmp")
			local editor_directory = vim.fn.getcwd(-1)
			chat.open()
			assert(vim.fn.haslocaldir(-1) == 0, "workspace inherited editor tab directory")
			assert(vim.fn.getcwd(-1) == global_directory)
			chat.toggle()
			assert(vim.fn.haslocaldir(-1) == 1 and vim.fn.getcwd(-1) == editor_directory)
			assert(vim.fn.getcwd(-1, -1) == global_directory)
		]])
	end)
end)
