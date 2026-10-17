local api = require("opencode")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local views = require("opencode.ui.chat.state")
local lifecycle = require("opencode.lifecycle")
local client = require("opencode.client")
local workspace = require("opencode.ui.chat.workspace")

local function settle() vim.wait(40, function() return false end, 5) end
local function press(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
	settle()
end

describe("tab session creation and close keys", function()
	local editor, first, created, saved, notices
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor = vim.api.nvim_get_current_tabpage()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false }, chat = { layout = "tab" } })
		saved = { lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify }
		lifecycle.ensure_connected = function(callback) callback() end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		created, notices = {}, {}
		vim.notify = function(message) notices[#notices + 1] = message end
		client.create_session = function(_, callback) created[#created + 1] = callback end
		for _, session in ipairs(app.get_active_sessions()) do app.close_runtime_session(session.id) end
		app.upsert_session({ id = "session-key-a", title = "Original", directory = "/tmp/session-keys" })
		app.set_session("session-key-a", "Original")
		views.state.session_bound = false
		chat.open()
		first = chat.get_view()
	end)

	after_each(function()
		require("opencode.ui.input").close()
		for _, view in ipairs(views.all()) do if view.visible then chat.close_view(view, { all_windows = true }) end end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle()
		lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify = unpack(saved)
	end)

	it("keeps one native tab when repeatedly creating and closing layouts with N and x", function()
		local tab, buf = first.tabpage, first.bufnr
		local native_tabs = #vim.api.nvim_list_tabpages()
		for i = 1, 12 do
			press("N")
			assert.equals(i, #created)
			created[i](nil, { id = "session-key-new-" .. i, title = "New " .. i })
			settle()
			assert.equals("session-key-new-" .. i, views.session(chat.get_view()).id)
			assert.equals(2, #workspace.list())
			assert.equals(2, #vim.api.nvim_tabpage_list_wins(tab))
			assert.equals(native_tabs, #vim.api.nvim_list_tabpages())
			assert.is_true(first.suspended)
			press("x")
			assert.equals(first, chat.get_view())
			assert.equals("session-key-a", views.session(chat.get_view()).id)
			assert.equals(1, #workspace.list())
			assert.equals(2, #vim.api.nvim_tabpage_list_wins(tab))
			assert.equals(buf, vim.api.nvim_get_current_buf())
			assert.is_false(app.is_runtime_session("session-key-new-" .. i))
			assert.is_true(first.visible)
		end
		assert.is_false(table.concat(notices, "\n"):find("No active", 1, true) ~= nil)
	end)

	it("ignores a new-session reply after x closed its owner", function()
		local tab = first.tabpage
		press("N")
		press("x")
		assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
		assert.is_false(first.visible)
		created[1](nil, { id = "session-key-late", title = "Late" })
		settle()
		assert.equals(editor, vim.api.nvim_get_current_tabpage())
		assert.equals(1, #vim.api.nvim_list_wins())
		assert.is_false(first.visible)
	end)

	it("keeps one native tab when multiple N replies arrive and x drains the layouts", function()
		local tab, native_tabs = first.tabpage, #vim.api.nvim_list_tabpages()
		press("NNNNNN")
		assert.equals(6, #created)
		for i, callback in ipairs(created) do callback(nil, { id = "session-key-burst-" .. i, title = "Burst " .. i }) end
		settle()
		assert.equals(7, #workspace.list())
		assert.equals(native_tabs, #vim.api.nvim_list_tabpages())
		assert.equals(2, #vim.api.nvim_tabpage_list_wins(tab))
		for remaining = #workspace.list() - 1, 0, -1 do
			assert.is_true(chat.get_view().visible)
			press("x")
			assert.equals(remaining, #workspace.list())
			if vim.api.nvim_tabpage_is_valid(tab) then assert.equals(2, #vim.api.nvim_tabpage_list_wins(tab)) end
		end
		assert.same({}, app.get_runtime_session_order())
		assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
		assert.equals(editor, vim.api.nvim_get_current_tabpage())
		assert.is_false(table.concat(notices, "\n"):find("No active", 1, true) ~= nil)
	end)
end)
