local api = require("opencode")
local state = require("opencode.state")
local sync = require("opencode.sync")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local lifecycle = require("opencode.lifecycle")
local client = require("opencode.client")
local pending = require("opencode.session.pending")

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
		require("opencode.ui.chat.workspace").reset()
		lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify = saved.ensure, saved.create, saved.messages, saved.notify
		sync.clear_all()
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

	it("creates an editor tab when the return tab was closed", function()
		vim.api.nvim_set_current_tabpage(editor); vim.cmd("tabclose!")
		local tab = first.tabpage
		chat.toggle()
		assert.is_not.equals(tab, vim.api.nvim_get_current_tabpage())
		assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
		assert.is_true(first.suspended)
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

describe("tab lifecycle asynchronous boundaries", function()
	local editor, first, create, saved
	before_each(function()
		editor = vim.api.nvim_get_current_tabpage()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false }, chat = { layout = "tab" } })
		saved = { lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify }
		lifecycle.ensure_connected = function(callback) callback() end
		client.create_session = function(_, callback) create = callback end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		vim.notify = function() end
		state.upsert_session({ id = "review-a", title = "A", directory = "/tmp/review" })
		state.set_session("review-a", "A")
		cs.state.session_bound = false
		chat.open()
		first = chat.get_view()
	end)

	after_each(function()
		require("opencode.ui.input").close()
		for _, view in ipairs(cs.all()) do if view.visible then chat.close_view(view) end end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle()
		lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify = unpack(saved)
	end)

	it("does not open a split after its connection attempt was invalidated", function()
		api.split("vertical")
		pending.invalidate()
		create(nil, { id = "review-stale", title = "Old server session" })
		settle()
		assert.is_true(cs.for_session("review-stale") == nil)
		assert.equals(first.winid, vim.api.nvim_get_current_win())
	end)

	it("opens the newly created session after all chat panes were closed", function()
		chat.close_view(first)
		settle()
		api.new_session()
		create(nil, { id = "review-new", title = "New" })
		settle()
		chat.open()
		assert.equals("review-new", cs.session(chat.get_view()).id)
	end)

	it("saves the composer before native tabclose tears down all chat panes", function()
		local input, history = require("opencode.ui.input"), require("opencode.ui.input.history")
		local second = chat.create_split(first, { id = "review-b", title = "B" }, "vertical")
		chat.focus_input()
		input.set_pending_text("Draft survives tabclose")
		vim.cmd("tabclose!")
		settle()
		assert.is_false(first.visible)
		assert.is_false(second.visible)
		assert.is_false(input.is_visible())
		assert.equals("Draft survives tabclose", history.get_pending("review-b"))
		assert.equals(editor, vim.api.nvim_get_current_tabpage())
	end)
end)
