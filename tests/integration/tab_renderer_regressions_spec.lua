describe("tab renderer regressions", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.request("nvim_ui_attach", { 100, 35, { rgb = true, ext_linegrid = true } })
	end)
	after_each(function() if editor then editor.close() end end)

	local function open_renderer(layout)
		editor.lua([[
			local layout = ...
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = layout, session_tabs = { auto_fit = true, separator = " │  " } } })
			_G.app = require("opencode.state")
			_G.cs = require("opencode.ui.chat.state")
			for index = 1, 5 do app.set_session("session-" .. index, "Session " .. index) end
			app.set_session("session-3", "Session 3")
			_G.view = cs.new()
			view.session_id, view.session_name = "session-3", "Session 3"
			view.config = vim.deepcopy(app.get_config().chat)
			view.bufnr = vim.api.nvim_create_buf(false, true)
			if layout == "float" then
				view.winid = vim.api.nvim_open_win(view.bufnr, true, {
					relative = "editor", row = 3, col = 3, width = 80, height = 20, style = "minimal",
				})
				view.float_dims = { row = 3, col = 3, width = 67, height = 20 }
			else
				vim.cmd("vsplit")
				view.winid = vim.api.nvim_get_current_win()
				vim.api.nvim_win_set_buf(view.winid, view.bufnr)
			end
			view.visible, view.tabpage = true, vim.api.nvim_get_current_tabpage()
			_G.tabs = require("opencode.ui.chat.session_tabs").for_view(view)
			_G.resize = function(width)
				if layout == "float" then view.float_dims.width = width + 2
				else vim.api.nvim_win_set_width(view.winid, width) end
				tabs.update_winbar()
			end
			_G.tab_text = function()
				if layout == "float" then return vim.api.nvim_buf_get_lines(view.session_tabs_bufnr, 0, 1, false)[1] end
				return vim.api.nvim_eval_statusline(vim.wo[view.winid].winbar,
					{ winid = view.winid, use_winbar = true, maxwidth = 10000 }).str
			end
			resize(65)
		]], { layout })
	end

	for _, layout in ipairs({ "vertical", "float" }) do
		it("recenters " .. layout .. " tabs after fitting changes without resetting viewport state", function()
			open_renderer(layout)
			local result = editor.lua([[
				local wide = tab_text()
				local first = view.session_tabs_start
				resize(30)
				local narrow = tab_text()
				local narrow_first = view.session_tabs_start
				resize(65)
				return { wide = wide, narrow = narrow, first = first, narrow_first = narrow_first,
					final = tab_text(), count = view.session_tabs_max_tabs }
			]])
			assert.equals(2, result.first)
			assert.equals(3, result.narrow_first)
			assert.is_truthy(result.narrow:find("Session 3", 1, true))
			assert.is_true(vim.fn.strdisplaywidth(result.narrow) <= 30)
			assert.equals(result.wide, result.final)
			assert.equals(3, result.count)
		end)

		it("keeps the active " .. layout .. " tab visible when the fitted count changes at the same width", function()
			open_renderer(layout)
			local result = editor.lua([[
				local wide = tab_text()
				assert(view.session_tabs_max_tabs == 3 and view.session_tabs_start == 2)
				for index = 1, 5 do
					app.upsert_session({ id = "session-" .. index, title = "Label-" .. index .. "-" .. string.rep("é", 10) }, { touch = false })
				end
				app.set_session_status("session-2", "busy")
				tabs.update_winbar()
				local fitted, first, text = view.session_tabs_max_tabs, view.session_tabs_start, tab_text()
				local active = false
				for _, target in pairs(view.winbar_targets) do
					if target.session_id == "session-3" then active = true end
				end
				for index = 1, 5 do app.upsert_session({ id = "session-" .. index, title = "Session " .. index }, { touch = false }) end
				app.set_session_status("session-2", "idle")
				tabs.update_winbar()
				return { fitted = fitted, first = first, text = text, active = active,
					width = view.session_tabs_width, final = tab_text(), wide = wide }
			]])
			assert.equals(1, result.fitted)
			assert.equals(3, result.first)
			assert.is_true(result.active)
			assert.is_truthy(result.text:find("Label-3-", 1, true))
			assert.is_true(vim.fn.strdisplaywidth(result.text) <= 65)
			assert.equals(65, result.width)
			assert.equals(result.wide, result.final)
		end)

		it("keeps " .. layout .. " manual paging until the session order changes", function()
			open_renderer(layout)
			local result = editor.lua([[
				resize(30)
				for id, target in pairs(view.winbar_targets) do
					if target.kind == "page" and target.start == 4 then tabs.select_winbar_session(id); break end
				end
				local paged = tab_text()
				tabs.update_winbar()
				local refreshed = tab_text()
				app.set_runtime_session_order({ "session-3", "session-2", "session-1", "session-4", "session-5" })
				tabs.update_winbar()
				return { paged = paged, refreshed = refreshed, reordered = tab_text(), current = view.session_id }
			]])
			assert.is_truthy(result.paged:find("Session 4", 1, true))
			assert.is_nil(result.paged:find("Session 3", 1, true))
			assert.equals(result.paged, result.refreshed)
			assert.is_truthy(result.reordered:find("Session 3", 1, true))
			assert.equals("session-3", result.current)
		end)

		it("bounds narrow " .. layout .. " labels and click targets, including controls and Unicode", function()
			open_renderer(layout)
			local result = editor.lua([[
				app.upsert_session({ id = "session-3", title = "界\n%héllo\tworld", name = "界\n%héllo\tworld" }, { touch = false })
				app.set_session_status("session-2", "busy")
				app.set_session_pending_counts("session-4", { questions = 1 })
				local lines = {}
				for _, auto_fit in ipairs({ true, false }) do
					view.config.session_tabs.auto_fit = auto_fit
					for _, width in ipairs({ 30, 20, 12, 6, 3, 2, 1 }) do
						resize(width)
						local text = tab_text()
						assert(vim.fn.strdisplaywidth(text) <= width, text)
						assert(not text:find("[%c]"), text)
						local active
						for id, target in pairs(view.winbar_targets) do
							if target.kind == "session" and target.session_id == "session-3" then active = id end
						end
						assert(active, text)
						for _, target in ipairs(view.session_tabs_mouse_targets) do
							assert(target.start_col >= 1 and target.end_col <= width)
							assert(view.winbar_targets[target.target])
						end
						lines[#lines + 1] = text
					end
				end
				resize(20)
				local selected
				require("opencode.actions").switch_session = function(record) selected = record.id end
				if view.config.layout == "float" then
					local target = view.session_tabs_mouse_targets[1]
					local original = vim.fn.getmousepos
					vim.fn.getmousepos = function() return { winid = view.session_tabs_winid, wincol = target.end_col } end
					for _, map in ipairs(vim.api.nvim_buf_get_keymap(view.session_tabs_bufnr, "n")) do
						if map.lhs == "<LeftMouse>" then map.callback(); break end
					end
					vim.fn.getmousepos = original
				else
					for id, target in pairs(view.winbar_targets) do
						if target.kind == "session" then tabs.select_winbar_session(id); break end
					end
				end
				return { lines = lines, text = tab_text(), selected = selected }
			]])
			assert.equals("session-3", result.selected)
			assert.is_truthy(result.text:find("界 %héllo world", 1, true))
			assert.equals("○界", result.lines[5])
			assert.equals("○", result.lines[7])
			assert.equals(14, #result.lines)
		end)
	end

	local function open_workspace(layout, options)
		editor.lua([[
			local layout, options = ...
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				notifications = { enabled = false },
				chat = { layout = layout, close_on_focus_lost = false,
					session_tabs = options } })
			local client = require("opencode.client")
			client.get_messages = function(_, _, cb) cb(nil, {}) end
			client.get_all_messages = function(_, cb) cb(nil, {}) end
			client.get_inbox = function(_, cb) cb(nil, {}) end
			_G.app, _G.sessions = require("opencode.state"), require("opencode.session")
			client.get_session = function(id, cb) cb(nil, app.get_session_record(id)) end
			_G.chat, _G.workspace = require("opencode.ui.chat"), require("opencode.ui.chat.workspace")
			_G.bar = require("opencode.ui.chat.workspace_bar")
			_G.settle = function() vim.wait(80, function() return false end, 5) end
			local sequence = 9000
			_G.native = function(kind, id, data)
				sequence = sequence + 1
				require("opencode.events").emit("server_event", { id = "evt-renderer-" .. sequence,
					type = kind, created = sequence, data = vim.tbl_extend("force", { sessionID = id }, data or {}) })
			end
			_G.seed = function(id, title)
				local record = { id = id, title = title or id }
				sessions.remember(record)
				return record
			end
			seed("root-a"); sessions.set_active("root-a", "root-a"); chat.open()
			_G.first = chat.get_view()
			_G.bar_text = function()
				return vim.api.nvim_eval_statusline(vim.o.tabline, { use_tabline = true, maxwidth = vim.o.columns }).str
			end
			settle()
		]], { layout or "tab", options or {} })
	end

	it("selects a float session on the first native mouse click at either Unicode target edge", function()
		open_workspace("float", { auto_fit = true })
		editor.lua([[
			seed("other", "界é% destination")
			first.float_dims.width = 95
			require("opencode.ui.chat.session_tabs").for_view(first).update_winbar()
		]])
		for _, edge in ipairs({ "start_col", "end_col" }) do
			local click = editor.lua([[
				local edge = ...
				sessions.set_active("root-a", "root-a"); settle()
				vim.api.nvim_set_current_win(first.winid)
				assert(require("opencode.ui.chat.state").session(first).id == "root-a")
				for _, target in ipairs(first.session_tabs_mouse_targets) do
					if first.winbar_targets[target.target].session_id == "other" then
						local position = vim.api.nvim_win_get_position(first.session_tabs_winid)
						return { position[1], position[2] + target[edge] - 1 }
					end
				end
				error("missing destination target")
			]], { edge })
			editor.request("nvim_input_mouse", { "left", "press", "", 0, click[1], click[2] })
			editor.request("nvim_input_mouse", { "left", "release", "", 0, click[1], click[2] })
			local result = editor.lua([[
				settle()
				return { session = require("opencode.ui.chat.state").session(first).id,
					current = vim.api.nvim_get_current_win(), transcript = first.winid, mouse = vim.fn.getmousepos() }
			]])
			assert.equals("other", result.session, edge .. ": " .. vim.inspect(result))
			assert.equals(result.transcript, result.current)
		end
	end)

	it("refreshes native failures and status priority in a suspended secondary pane", function()
		open_workspace()
		local result = editor.lua([[
			local second = chat.create_split(first, seed("secondary"), "vertical")
			chat.create_layout(seed("root-c")); settle()
			local focused, selected = vim.api.nvim_get_current_win(), workspace.current().id
			native("session.execution.started", "secondary"); settle()
			native("session.execution.failed", "secondary", { error = { name = "ProviderError", message = "provider failure" } }); settle()
			local failed, raw = bar_text(), app.get_session_status("secondary")
			sessions.remember({ id = "root-a", time = { idle = 20, viewed = 10 } }, { touch = false }); settle()
			local error_over_unread = bar_text()
			native("session.execution.started", "root-a"); settle()
			local running = bar_text()
			require("opencode.question.state").add_form({ id = "renderer-question", sessionID = "secondary",
				fields = { { key = "ok", type = "boolean", required = true } } })
			sessions.recount_pending(); settle()
			return { failed = failed, raw = raw, error_over_unread = error_over_unread, running = running,
				waiting = bar_text(), suspended = second.suspended,
				focused = vim.api.nvim_get_current_win() == focused and workspace.current().id == selected }
		]])
		assert.same({ type = "idle", outcome = "failed" }, result.raw)
		assert.is_truthy(result.failed:find("✕ root-a", 1, true))
		assert.is_truthy(result.error_over_unread:find("✕ root-a", 1, true))
		assert.is_truthy(result.running:find("● root-a", 1, true))
		assert.is_truthy(result.waiting:find("◈ root-a", 1, true))
		assert.is_true(result.suspended)
		assert.is_true(result.focused)
	end)

	it("refreshes native status and title events while the active layout contains only files", function()
		open_workspace()
		local result = editor.lua([[
			local second = chat.create_split(first, seed("secondary"), "vertical")
			local current = chat.create_layout(seed("root-c"))
			vim.cmd("rightbelow vsplit")
			local filewin = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(filewin, vim.api.nvim_create_buf(true, false))
			chat.close_view(current); settle()
			vim.api.nvim_set_current_win(filewin)
			native("session.execution.started", "secondary"); settle()
			native("session.renamed", "root-a", { title = "Renamed root" }); settle()
			return { text = bar_text(), suspended = second.suspended,
				focused = vim.api.nvim_get_current_win() == filewin, count = #workspace.list() }
		]])
		assert.is_truthy(result.text:find("● Renamed root", 1, true))
		assert.is_true(result.suspended)
		assert.is_true(result.focused)
		assert.equals(2, result.count)
	end)

	it("keeps full-width tabline titles unchanged when focused panes wrap at different widths", function()
		open_workspace()
		local result = editor.lua([[
			app.upsert_session({ id = "root-a", title = "Long layout title" }, { touch = false })
			local second = chat.create_split(first, seed("secondary"), "vertical")
			local rendered, widths = {}, {}
			for _, view in ipairs({ first, second }) do
				chat.focus_view(view)
				if view == first then vim.api.nvim_win_set_width(view.winid, 10) end
				vim.wo[view.winid].wrap, vim.wo[view.winid].linebreak, vim.wo[view.winid].breakindent = true, true, true
				widths[#widths + 1] = vim.api.nvim_win_get_width(view.winid)
				bar.update()
				rendered[#rendered + 1] = bar_text()
			end
			return { rendered = rendered, widths = widths }
		]])
		assert.equals(10, result.widths[1])
		assert.is_true(result.widths[2] > 18)
		assert.is_truthy(result.rendered[1]:find("Long layout title", 1, true))
		assert.equals(result.rendered[1], result.rendered[2])
	end)

	it("refits the shared bar on native UI resize in a file-only active layout", function()
		open_workspace("tab", { auto_fit = true })
		editor.lua([[
			for index = 2, 5 do chat.create_layout(seed("layout-" .. index, "Long layout " .. index)) end
			local current = chat.get_view()
			vim.cmd("rightbelow vsplit")
			_G.filewin = vim.api.nvim_get_current_win()
			vim.api.nvim_win_set_buf(filewin, vim.api.nvim_create_buf(true, false))
			chat.close_view(current); settle()
			vim.api.nvim_set_current_win(filewin)
		]])
		for _, width in ipairs({ 20, 100, 28 }) do
			editor.request("nvim_ui_try_resize", { width, 35 })
			local result = editor.lua([[
				settle()
				local text = bar_text()
				return { text = text, cells = vim.fn.strwidth(text),
					width = vim.o.columns,
					focused = vim.api.nvim_get_current_win() == filewin, selected = workspace.current().id == workspace.list()[5].id }
			]])
			assert.is_true(result.cells <= result.width, vim.inspect(result))
			assert.is_truthy(result.text:find("Long layou", 1, true))
			assert.is_true(result.focused)
			assert.is_true(result.selected)
		end
	end)

	it("selects the visible fifth icon using accumulated display cells with a combining separator", function()
		open_workspace("tab", { auto_fit = true, separator = vim.fn.nr2char(0x301) })
		local click = editor.lua([[
			for index = 2, 5 do chat.create_layout(seed("layout-" .. index, index == 5 and "Fifth" or ("Label " .. index))) end
			_G.fifth = workspace.current().id
			workspace.select(first.workspace_id); settle()
			local text = bar_text()
			return { row = 0,
				column = vim.fn.strwidth(text:sub(1, assert(text:find("○ Fifth", 1, true)) - 1)) }
		]])
		editor.request("nvim_input_mouse", { "left", "press", "", 0, click.row, click.column })
		editor.request("nvim_input_mouse", { "left", "release", "", 0, click.row, click.column })
		assert.is_true(editor.lua("settle(); return workspace.current().id == fifth"))
	end)

	it("shows Error and Unread from a suspended secondary pane without changing focus", function()
		open_workspace()
		local result = editor.lua([[
			local second = chat.create_split(first, seed("split-b"), "vertical")
			local current = chat.create_layout(seed("root-c"))
			assert(second.suspended)
			local focused, selected = vim.api.nvim_get_current_win(), workspace.current().id
			local function has_highlight(name)
				local rendered = vim.api.nvim_eval_statusline(vim.o.tabline, { use_tabline = true, maxwidth = vim.o.columns, highlights = true })
				for _, highlight in ipairs(rendered.highlights) do
					if highlight.group == name or vim.tbl_contains(highlight.groups or {}, name) then return true end
				end
				return false
			end
			app.set_session_status("split-b", "error"); bar.update()
			local failed, error_hl = bar_text(), has_highlight("OpenCodeWinbarError")
			app.set_session_status("split-b", "idle")
			app.upsert_session({ id = "split-b", time = { idle = 2, viewed = 1 } }, { touch = false })
			bar.update()
			return { failed = failed, unread = bar_text(), error_hl = error_hl,
				unread_hl = has_highlight("OpenCodeWinbarWaiting"),
				focused = vim.api.nvim_get_current_win() == focused and chat.get_view() == current,
				selected = workspace.current().id == selected }
		]])
		assert.is_truthy(result.failed:find("✕ root-a", 1, true))
		assert.is_truthy(result.unread:find("◆ root-a", 1, true))
		assert.is_nil(result.unread:find("split-b", 1, true))
		assert.is_true(result.error_hl)
		assert.is_true(result.unread_hl)
		assert.is_true(result.focused)
		assert.is_true(result.selected)
	end)

	it("observes each refresh once, including hiding a view", function()
		open_renderer("vertical")
		assert.is_true(editor.lua([[
			vim.wait(50, function() return false end)
			local observed = {}
			require("opencode.actions").observe_session = function(id, visible)
				observed[#observed + 1] = { id, visible }
			end
			tabs.setup_refresh_autocmds()
			local callback = vim.api.nvim_get_autocmds({ group = "OpenCodeSessionTabs_" .. view.id, event = "ColorScheme" })[1].callback
			callback()
			assert(vim.wait(1000, function() return #observed > 0 end))
			assert(#observed == 1 and observed[1][1] == "session-3" and observed[1][2] == true)
			view.visible = false
			callback()
			assert(vim.wait(1000, function() return #observed > 1 end))
			return #observed == 2 and observed[2][2] == false
		]]))
	end)
end)
