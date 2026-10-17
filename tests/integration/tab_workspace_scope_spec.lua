local api = require("opencode")
local state, sessions = require("opencode.state"), require("opencode.session")
local chat, views = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local client, lifecycle = require("opencode.client"), require("opencode.lifecycle")
local tabs = require("opencode.session.tabs")
local workspace = require("opencode.ui.chat.workspace")

local function settle() vim.wait(40, function() return false end, 5) end
local function press(key)
	local mapping = vim.fn.maparg(key, "n", false, true)
	assert.is_function(mapping.callback, "missing chat mapping " .. key)
	mapping.callback(); settle()
end

describe("tab workspace directory scope", function()
	local editor, cwd, directory, source, destination, file, saved, notices, created
	local function scope(path) return vim.json.encode({ "localhost", 4096, state.normalize_directory(path) }) end
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor, cwd = vim.api.nvim_get_current_tabpage(), vim.fn.getcwd()
		directory = vim.fn.tempname()
		source, destination, file = directory .. "/source", directory .. "/destination", directory .. "/tabs.json"
		vim.fn.mkdir(source, "p"); vim.fn.mkdir(destination, "p")
		source, destination = vim.uv.fs_realpath(source), vim.uv.fs_realpath(destination)
		tabs.teardown(); state.reset(); require("opencode.sync").clear_all()
		saved = { messages = client.get_messages, create = client.create_session,
			ensure = lifecycle.ensure_connected, notify = vim.notify }
		notices, created = {}, 0
		vim.notify = function(message) notices[#notices + 1] = message end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		lifecycle.ensure_connected = function(callback) callback() end
		client.create_session = function(options, callback)
			created = created + 1
			assert.equals(source, options.location and options.location.directory)
			callback(nil, { id = "created-" .. created, title = "Created " .. created, directory = options.location.directory })
		end
		assert.is_true(require("opencode.preferences").open(file).save({ scopes = {
			[scope(source)] = { tabs = { { id = "scope-a", title = "Source A" } }, active = "scope-a" },
			[scope(destination)] = { tabs = { { id = "scope-c", title = "Destination C" } }, active = "scope-c" },
		} }))
		vim.cmd.cd(source)
		api.setup({ server = { auto_start = false, host = "localhost", port = 4096 }, lualine = { enabled = false },
			chat = { layout = "tab", session_tabs = { scope = "cwd", file = file, max_tabs = 5, auto_fit = false } } })
		sessions.remember({ id = "scope-a", title = "Source A", directory = source }, { touch = false })
		chat.open(); settle()
	end)
	after_each(function()
		require("opencode.ui.input").close()
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle(); tabs.teardown()
		if vim.api.nvim_tabpage_is_valid(editor) then vim.api.nvim_set_current_tabpage(editor) end
		vim.cmd.cd(cwd)
		client.get_messages, client.create_session = saved.messages, saved.create
		lifecycle.ensure_connected, vim.notify = saved.ensure, saved.notify
		vim.fn.delete(directory, "rf")
	end)

	it("keeps layouts in one native tab through repeated N and x keypresses", function()
		local view, native_tab = chat.get_view(), vim.api.nvim_get_current_tabpage()
		local native_tabs = #vim.api.nvim_list_tabpages()
		assert.equals("scope-a", views.session(view).id)
		for index = 1, 10 do
			if index == 5 then
				require("opencode.ui.chat.exploration_style")
				vim.cmd.cd(destination); settle()
			end
			press("N")
			assert.equals("created-" .. index, views.session(chat.get_view()).id)
			assert.equals(2, #workspace.list())
			assert.equals(native_tabs, #vim.api.nvim_list_tabpages())
			assert.equals(2, #vim.api.nvim_tabpage_list_wins(native_tab))
			press("x")
			assert.equals(view, chat.get_view())
			assert.equals("scope-a", views.session(chat.get_view()).id)
			assert.same({ "scope-a" }, state.get_runtime_session_order())
			assert.equals(1, #workspace.list())
			assert.equals(2, #vim.api.nvim_tabpage_list_wins(native_tab))
		end
		assert.equals(10, created)
		for _, message in ipairs(notices) do assert.is_nil(message:find("No active OpenCode session", 1, true)) end
	end)

	it("retains open panes on cwd changes and restores the new scope after closing and reopening", function()
		local first = chat.get_view()
		sessions.remember({ id = "scope-b", title = "Other B", directory = destination })
		local second = chat.create_split(first, state.get_session_record("scope-b"), "vertical")
		vim.cmd.cd(destination); settle()
		assert.same({ "scope-a", "scope-b" }, state.get_runtime_session_order())
		assert.equals("scope-b", state.get_session().id)
		chat.focus_view(first); settle()
		assert.equals("scope-a", state.get_session().id)
		local barwin = require("opencode.ui.chat.workspace_bar").winid()
		local bar = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(barwin), 0, -1, false), "\n")
		assert.is_truthy(bar:find("Source A", 1, true))
		chat.focus_view(second); press("q")
		assert.same({ "scope-a", "scope-b" }, state.get_runtime_session_order())
		chat.focus_view(first); press("q")
		chat.open(); settle()
		assert.same({ "scope-c" }, state.get_runtime_session_order())
		assert.equals("scope-c", views.session(chat.get_view()).id)
		assert.equals("scope-c", state.get_session().id)
		press("q")
		vim.cmd.cd(source)
		chat.open(); settle()
		assert.same({ "scope-a", "scope-b" }, state.get_runtime_session_order())
		assert.equals("scope-a", views.session(chat.get_view()).id)
		press("x")
		assert.is_false(state.is_runtime_session("scope-a"))
		assert.is_true(state.is_runtime_session("scope-b"))
		sessions.switch_to(state.get_session_record("scope-b"), { notify = false })
		chat.open(); settle()
		assert.equals("scope-b", views.session(chat.get_view()).id)
		for _, message in ipairs(notices) do assert.is_nil(message:find("No active OpenCode session", 1, true)) end
	end)

	it("reopens a q-closed session and its draft in the same directory scope", function()
		local history = require("opencode.ui.input.history")
		history.set_pending("Keep this draft", {}, "scope-a")
		press("q")
		assert.is_nil(state.get_session().id)
		assert.is_true(state.is_runtime_session("scope-a"))
		chat.open(); settle()
		assert.equals("scope-a", views.session(chat.get_view()).id)
		assert.equals("Keep this draft", history.get_pending(views.session(chat.get_view()).id))
		press("x")
		chat.open(); settle()
		assert.is_nil(views.session(chat.get_view()).id)
		assert.is_false(state.is_runtime_session("scope-a"))
		history.clear_session("scope-a")
	end)

	it("reopens the last closed split session instead of the old default pane session", function()
		local first = chat.get_view()
		local history = require("opencode.ui.input.history")
		history.set_pending("Split draft", {}, "scope-b")
		sessions.remember({ id = "scope-b", title = "Other B", directory = source })
		local second = chat.create_split(first, state.get_session_record("scope-b"), "vertical")
		chat.focus_view(first); press("q")
		chat.focus_view(second); press("q")
		chat.open(); settle()
		assert.equals("scope-b", views.session(chat.get_view()).id)
		assert.equals("Split draft", history.get_pending(views.session(chat.get_view()).id))
		assert.same({ "scope-a", "scope-b" }, state.get_runtime_session_order())
		history.clear_session("scope-b")
	end)
end)
