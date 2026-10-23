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

describe("tab workspace navigation", function()
	local editor, cwd, directory, source, destination, saved, notices, created, expected_directory
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor, cwd = vim.api.nvim_get_current_tabpage(), vim.fn.getcwd()
		directory = vim.fn.tempname()
		source, destination = directory .. "/source", directory .. "/destination"
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
			assert.equals(expected_directory, options.location and options.location.directory)
			callback(nil, { id = "created-" .. created, title = "Created " .. created, directory = options.location.directory })
		end
		vim.cmd.cd(source)
		expected_directory = source
		api.setup({ server = { auto_start = false, host = "localhost", port = 4096 }, lualine = { enabled = false },
			chat = { layout = "tab", session_tabs = { max_tabs = 5, auto_fit = false } } })
		sessions.remember({ id = "scope-a", title = "Source A", directory = source })
		sessions.set_active("scope-a", "Source A")
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
				-- New sessions follow the changed cwd, not the replaced session's directory.
				expected_directory = destination
			end
			press("N")
			assert.equals("created-" .. index, views.session(chat.get_view()).id)
			assert.equals(2, #workspace.list())
			assert.equals(native_tabs, #vim.api.nvim_list_tabpages())
			assert.equals(1, #vim.api.nvim_tabpage_list_wins(native_tab))
			press("x")
			assert.equals(view, chat.get_view())
			assert.equals("scope-a", views.session(chat.get_view()).id)
			assert.same({ "scope-a" }, state.get_runtime_session_order())
			assert.equals(1, #workspace.list())
			assert.equals(1, #vim.api.nvim_tabpage_list_wins(native_tab))
		end
		assert.equals(10, created)
		for _, message in ipairs(notices) do assert.is_nil(message:find("No active OpenCode session", 1, true)) end
	end)

	it("reopens a q-closed session and its draft", function()
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
