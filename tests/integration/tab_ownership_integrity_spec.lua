local api, actions = require("opencode"), require("opencode.actions")
local state, sync = require("opencode.state"), require("opencode.sync")
local sessions, tabs = require("opencode.session"), require("opencode.session.tabs")
local chat, views = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local workspace, nav = require("opencode.ui.chat.workspace"), require("opencode.ui.chat.nav")
local client, lifecycle = require("opencode.client"), require("opencode.lifecycle")

local function settle() vim.wait(60, function() return false end, 5) end
local function owner_count(id)
	local count = 0
	for _, view in ipairs(views.all()) do
		if views.valid(view) and view.session_bound and (view.visible or view.suspended) and views.session(view).id == id then count = count + 1 end
	end
	return count
end

describe("tab binding ownership integrity", function()
	local saved, editor, first, directory, original_cwd, files, records
	local function seed(id, parent)
		local record = { id = id, title = id, parentID = parent, directory = directory .. "/one", agent = "build",
			model = { providerID = "provider", modelID = "model" } }
		records[id] = record
		sessions.remember(record, { touch = not parent })
		return record
	end
	local function separate_child()
		local second = chat.create_layout(seed("child", "root"))
		settle()
		assert.is_true(first.suspended)
		assert.equals(second, views.current())
		return second
	end
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor, original_cwd = vim.api.nvim_get_current_tabpage(), vim.fn.getcwd()
		directory = vim.fn.tempname()
		vim.fn.mkdir(directory .. "/one", "p"); vim.fn.mkdir(directory .. "/two", "p")
		tabs.teardown(); state.reset(); sync.clear_all(); require("opencode.session.pending").clear_all()
		vim.fn.chdir(directory .. "/one")
		saved = { notify = vim.notify, ensure = lifecycle.ensure_connected, client = {} }
		for _, name in ipairs({ "get_messages", "get_session", "get_session_statuses", "list_permissions", "list_questions", "review_rpc" }) do saved.client[name] = client[name] end
		vim.notify = function() end
		lifecycle.ensure_connected = function(callback) callback() end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		client.get_session = function(id, callback) callback(nil, vim.deepcopy(records[id])) end
		client.get_session_statuses = function(callback) callback(nil, {}) end
		client.list_permissions = function(_, callback) callback(nil, {}) end
		client.list_questions = function(_, callback) callback(nil, {}) end
		client.review_rpc = function(method, _, _, callback)
			if method == "capabilities" then callback(nil, { protocolVersion = 2, review = true })
			elseif method == "policyList" then callback(nil, {})
			elseif method == "reviewList" then callback(nil, { reviews = {} }) end
		end
		files, records = {}, {}
		api.setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "tab" } })
		seed("root"); sessions.set_active("root", "Root")
		views.state.session_bound = false
		chat.open(); settle()
		first = views.current()
	end)
	after_each(function()
		tabs.teardown()
		require("opencode.ui.input").close()
		workspace.reset()
		for _, view in ipairs(views.all()) do if view.visible then chat.close_view(view, { all_windows = true }) end end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle()
		for _, buf in ipairs(files) do if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end end
		for _, id in ipairs({ "root", "child" }) do require("opencode.ui.input.history").clear_session(id) end
		for name, method in pairs(saved.client) do client[name] = method end
		lifecycle.ensure_connected, vim.notify = saved.ensure, saved.notify
		if vim.api.nvim_tabpage_is_valid(editor) then vim.api.nvim_set_current_tabpage(editor) end
		vim.fn.chdir(original_cwd)
		vim.fn.delete(directory, "rf")
		sync.clear_all(); state.reset()
	end)

	it("focuses an existing owner before any independent bind side effects", function()
		local second = separate_child()
		second.expanded_tools.retained = true
		local generation, layout = second.generation, second.workspace_id
		local history = require("opencode.ui.input.history")
		history.set_pending("Child draft", {}, "child")
		assert.is_false(actions.set_view_session(second, "root", "Root", { reason = "family_navigation", preserve_cache = true }))
		settle()
		assert.equals(first, views.current())
		assert.equals("child", views.session(second).id)
		assert.equals(generation, second.generation)
		assert.equals(layout, second.workspace_id)
		assert.is_true(second.suspended)
		assert.is_true(second.expanded_tools.retained)
		assert.equals("Child draft", history.get_pending("child"))
		assert.equals(1, owner_count("root"))
		assert.equals(1, owner_count("child"))
	end)

	for _, method in ipairs({ "open_family_session", "leave_child_session" }) do
		it("does not duplicate the root or leave a ghost owner through " .. method, function()
			local second = separate_child()
			local generation = second.generation
			local navigation = views.module(second, nav)
			navigation[method]("root")
			settle()
			assert.equals(first, views.current())
			assert.equals("child", views.session(second).id)
			assert.equals(generation, second.generation)
			assert.equals(1, owner_count("root"))
			assert.is_true(sessions.close("root", { silent = true }))
			settle()
			assert.equals(0, owner_count("root"))
			assert.is_nil(views.for_session("root"))
			assert.is_false(state.is_runtime_session("root"))
			assert.is_true(views.valid(second))
			assert.equals("child", views.session(second).id)
		end)
	end

	it("preserves native mirrors of the same chat buffer when focusing and rebinding its owner", function()
		vim.cmd("vsplit"); settle()
		local second = separate_child()
		assert.is_false(chat.bind_session(second, records.root, { reason = "family_navigation" }))
		settle()
		assert.equals(2, #views.windows(first))
		assert.equals(1, owner_count("root"))
		assert.is_true(chat.bind_session(first, seed("replacement"), { preserve_cache = true }))
		settle()
		assert.equals(2, #views.windows(first))
		assert.equals(1, owner_count("replacement"))
		for _, win in ipairs(views.windows(first)) do assert.equals(first.bufnr, vim.api.nvim_win_get_buf(win)) end
	end)

	it("keeps runtime tabs across cwd changes when q leaves hidden and file-only layouts", function()
		local second = chat.create_layout(seed("other"))
		settle()
		vim.cmd("rightbelow new")
		local file, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		files[#files + 1] = file
		vim.api.nvim_buf_set_lines(file, 0, -1, false, { "Unsaved workspace file" })
		chat.focus_view(second)
		local mapping = vim.fn.maparg("q", "n", false, true)
		assert.is_function(mapping.callback)
		mapping.callback(); settle()
		assert.is_true(first.suspended)
		assert.is_false(second.visible)
		assert.equals(2, #workspace.list())
		local order = state.get_runtime_session_order()
		vim.cmd.cd(directory .. "/two")
		assert.same(order, state.get_runtime_session_order())
		assert.equals(2, #workspace.list())
		assert.is_true(vim.api.nvim_win_is_valid(win))
		assert.is_true(vim.bo[file].modified)
		assert.same({ "Unsaved workspace file" }, vim.api.nvim_buf_get_lines(file, 0, -1, false))
	end)
end)
