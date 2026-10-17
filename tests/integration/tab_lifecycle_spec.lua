local api = require("opencode")
local state = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local lifecycle = require("opencode.lifecycle")
local client = require("opencode.client")

local function settle() vim.wait(40, function() return false end, 5) end

describe("OpenCode tab lifecycle", function()
	local saved, editor, first, created
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor = vim.api.nvim_get_current_tabpage()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "tab" }, session = { parallel = { enabled = false } } })
		saved = { ensure = lifecycle.ensure_connected, create = client.create_session, messages = client.get_messages, notify = vim.notify }
		lifecycle.ensure_connected = function(callback) callback() end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		vim.notify = function() end
		created = {}
		client.create_session = function(body, callback) created[#created + 1] = { body = body, callback = callback } end
		state.upsert_session({ id = "tab-a", title = "A", directory = "/tmp/project-a" })
		state.set_session("tab-a", "A")
		cs.state.session_bound = false
		chat.open()
		first = chat.get_view()
	end)
	after_each(function()
		require("opencode.ui.input").close()
		for _, view in ipairs(cs.all()) do if view.visible then chat.close_view(view) end end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor and vim.api.nvim_tabpage_is_valid(editor) then
				vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!")
			end
		end
		settle()
		lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify = saved.ensure, saved.create, saved.messages, saved.notify
		sync.clear_all()
	end)

	it("toggles without changing windows, sizes or cursor and reuses the last pane", function()
		state.upsert_session({ id = "tab-b", title = "B" })
		local second = chat.create_split(first, state.get_session_record("tab-b"), "vertical")
		vim.api.nvim_win_set_width(second.winid, 45)
		local width, win, tab = vim.api.nvim_win_get_width(second.winid), second.winid, second.tabpage
		chat.toggle()
		assert.equals(editor, vim.api.nvim_get_current_tabpage())
		assert.is_true(vim.api.nvim_win_is_valid(win))
		chat.open()
		assert.equals(tab, vim.api.nvim_get_current_tabpage())
		assert.equals(win, vim.api.nvim_get_current_win())
		assert.equals(width, vim.api.nvim_win_get_width(win))
	end)

	it("keeps the layout intact on failed creation and splits only after success", function()
		local count = #vim.api.nvim_tabpage_list_wins(first.tabpage)
		assert.is_true(api.split("vertical"))
		assert.equals(count, #vim.api.nvim_tabpage_list_wins(first.tabpage))
		created[1].callback({ message = "offline" }); settle()
		assert.equals(count, #vim.api.nvim_tabpage_list_wins(first.tabpage))
		api.split("horizontal")
		created[2].callback(nil, { id = "created-b", title = "B" }); settle()
		assert.equals(count + 1, #vim.api.nvim_tabpage_list_wins(first.tabpage))
		assert.equals("created-b", cs.session(chat.get_view()).id)
		assert.equals("/tmp/project-a", created[2].body.location.directory)
	end)

	it("does not resurrect an owner closed before its split response", function()
		api.split("vertical")
		local tab = first.tabpage
		chat.close_view(first)
		created[1].callback(nil, { id = "late-b", title = "Late" }); settle()
		assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
		assert.is_false(first.visible)
		assert.is_nil(cs.for_session("late-b"))
	end)

	it("creates a separate layout without replacing the original pane or stealing focus", function()
		state.upsert_session({ id = "tab-b", title = "B" })
		local second = chat.create_split(first, state.get_session_record("tab-b"), "vertical")
		local workspace = require("opencode.ui.chat.workspace")
		local original_layout, count = workspace.current().id, #workspace.list()
		sync.handle_message_updated({ id = "msg-b", sessionID = "tab-b", role = "user", time = { created = 1 } })
		chat.focus_view(first)
		api.new_session()
		chat.focus_view(second)
		created[1].callback(nil, { id = "replacement-a", title = "New A" }); settle()
		assert.equals("tab-a", first.session_id)
		assert.equals("tab-b", second.session_id)
		assert.equals(original_layout, workspace.current().id)
		assert.equals(second, chat.get_view())
		assert.equals("tab-b", state.get_session().id)
		assert.equals(1, #sync.get_messages("tab-b"))
		assert.equals(count + 1, #workspace.list())
		local created_view = cs.for_session("replacement-a")
		assert.is_not_nil(created_view)
		assert.is_not.equals(original_layout, created_view.workspace_id)
		assert.is_true(created_view.suspended)
	end)

	it("captures send ownership before waiting for a connection", function()
		local connect, sent
		lifecycle.ensure_connected = function(callback) connect = callback end
		local send = require("opencode.send")
		local original = send.send
		send.send = function(_, opts) sent = opts end
		api.send("hello")
		state.upsert_session({ id = "tab-b", title = "B" })
		local second = chat.create_split(first, state.get_session_record("tab-b"), "vertical")
		connect()
		send.send = original
		assert.equals("tab-a", sent.session_id)
		assert.equals(first.id, sent._view_id)
		assert.equals("tab-b", second.session_id)
	end)

	it("preserves an unsaved user window when the last chat closes", function()
		local tab = first.tabpage
		vim.cmd("rightbelow new")
		local file, filewin = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		vim.api.nvim_buf_set_lines(file, 0, -1, false, { "unsaved file" })
		chat.close_view(first); settle()
		assert.is_true(vim.api.nvim_tabpage_is_valid(tab))
		assert.is_true(vim.api.nvim_win_is_valid(filewin))
		assert.same({ "unsaved file" }, vim.api.nvim_buf_get_lines(file, 0, -1, false))
		assert.is_true(vim.bo[file].modified)
	end)

	it("preserves a file that replaced the owned chat buffer", function()
		local win = first.winid
		local file = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_win_set_buf(win, file)
		vim.api.nvim_buf_set_lines(file, 0, -1, false, { "unsaved replacement" })
		chat.close_view(first); settle()
		assert.is_true(vim.api.nvim_win_is_valid(win))
		assert.equals(file, vim.api.nvim_win_get_buf(win))
		assert.is_true(vim.bo[file].modified)
		assert.is_false(first.visible)
	end)

	it("creates an editor tab when the return tab was closed", function()
		vim.api.nvim_set_current_tabpage(editor); vim.cmd("tabclose!")
		local tab = first.tabpage
		chat.toggle()
		assert.is_not.equals(tab, vim.api.nvim_get_current_tabpage())
		assert.is_true(vim.api.nvim_win_is_valid(first.winid))
		editor = vim.api.nvim_get_current_tabpage()
	end)

	it("closes the final OpenCode tab without exiting Neovim", function()
		vim.api.nvim_set_current_tabpage(editor); vim.cmd("tabclose!")
		local tab = first.tabpage
		chat.close_view(first); settle()
		assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
		assert.equals(1, #vim.api.nvim_list_tabpages())
		assert.equals("", vim.bo.filetype)
		editor = vim.api.nvim_get_current_tabpage()
	end)

	it("rejects split commands outside tab mode without changing layout", function()
		local config = state.get_config(); config.chat.layout = "vertical"; state.set_config(config)
		local count = #vim.api.nvim_list_wins()
		assert.is_false(api.split("vertical"))
		assert.equals(0, #created)
		assert.equals(count, #vim.api.nvim_list_wins())
		config.chat.layout = "tab"; state.set_config(config)
	end)
end)
