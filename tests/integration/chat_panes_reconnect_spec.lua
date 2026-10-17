local state, sync = require("opencode.state"), require("opencode.sync")
local events, server = require("opencode.events"), require("opencode.events.handlers.server")
local chat, views = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local client, sessions = require("opencode.client"), require("opencode.session")
local history = require("opencode.ui.input.history")
local project = require("opencode.protocol.messages").project

local function text(view)
	return table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
end

local function messages(id, content)
	return { project(id, { id = id .. "-message", type = "assistant", time = { created = 1 },
		content = { { type = "text", text = content } } }) }
end

local function wait_for(predicate)
	assert.is_true(vim.wait(1000, predicate, 10))
end

describe("chat panes reconnect recovery", function()
	local saved, editor, first, second, reads
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor = vim.api.nvim_get_current_tabpage()
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "tab", session_tabs = { enabled = false } } })
		events.clear(); server.clear(); sync.clear_all()
		saved = { refresh = sessions.refresh_status }
		for _, name in ipairs({ "get_messages", "get_all_messages", "get_session", "get_inbox" }) do saved[name] = client[name] end
		sessions.refresh_status = function() end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		client.get_session = function(id, callback) callback(nil, { id = id, title = id }) end
		reads = { history = {}, inbox = {} }
		client.get_all_messages = function(id, callback)
			reads.history[id] = reads.history[id] or {}; table.insert(reads.history[id], callback)
		end
		client.get_inbox = function(id, callback)
			reads.inbox[id] = reads.inbox[id] or {}; table.insert(reads.inbox[id], callback)
		end
		server.setup(events)
		require("opencode.ui.chat.render_coordinator").setup(events)
		for _, id in ipairs({ "recover-a", "recover-b" }) do
			state.upsert_session({ id = id, title = id })
			sync.handle_session_messages(id, messages(id, "Before " .. id))
			history.set_pending("Draft " .. id, {}, id)
		end
		state.set_session("recover-a", "recover-a")
		views.state.session_bound = false
		chat.open(); first = chat.get_view()
		second = chat.create_split(first, state.get_session_record("recover-b"), "vertical")
		chat.for_view(first).do_render(); chat.for_view(second).do_render()
	end)
	after_each(function()
		state.set_connection("idle")
		server.clear(); events.clear()
		for _, view in ipairs(views.all()) do if view.visible then chat.close_view(view) end end
		if vim.api.nvim_tabpage_is_valid(editor) then vim.api.nvim_set_current_tabpage(editor) end
		for _, id in ipairs({ "recover-a", "recover-b" }) do history.clear_session(id) end
		for name, fn in pairs(saved) do if name ~= "refresh" then client[name] = fn end end
		sessions.refresh_status = saved.refresh
		sync.clear_all()
	end)

	it("recovers both visible sessions, ignores old replies and resumes each stream in its own pane", function()
		local first_win, second_win = first.winid, second.winid
		state.set_connection("connected")
		wait_for(function() return reads.history["recover-a"] and reads.inbox["recover-b"] end)
		state.set_connection("idle")
		state.set_connection("connected")
		wait_for(function() return #reads.history["recover-a"] == 2 and #reads.inbox["recover-b"] == 2 end)
		for _, id in ipairs({ "recover-a", "recover-b" }) do
			reads.history[id][1](nil, messages(id, "Stale " .. id)); reads.inbox[id][1](nil, {})
			assert.equals("Before " .. id, sync.get_message_text(id .. "-message"))
		end
		reads.history["recover-b"][2](nil, messages("recover-b", "Recovered B"))
		reads.inbox["recover-b"][2](nil, {})
		wait_for(function() return text(second):find("Recovered B", 1, true) end)
		assert.is_nil(text(first):find("Recovered B", 1, true))
		reads.inbox["recover-a"][2](nil, {})
		reads.history["recover-a"][2](nil, messages("recover-a", "Recovered A"))
		wait_for(function() return text(first):find("Recovered A", 1, true) end)
		assert.equals("Recovered A", sync.get_message_text("recover-a-message"))
		assert.equals("Recovered B", sync.get_message_text("recover-b-message"))
		assert.is_nil(text(second):find("Recovered A", 1, true))
		vim.wait(40, function() return false end, 5)
		local sibling_tick = vim.api.nvim_buf_get_changedtick(second.bufnr)
		events.emit("server_event", { id = "recovered-stream", created = 3, type = "session.text.delta",
			data = { sessionID = "recover-a", assistantMessageID = "recover-a-message", ordinal = 0, delta = " resumed" } })
		wait_for(function() return text(first):find("Recovered A resumed", 1, true) end)
		assert.equals(sibling_tick, vim.api.nvim_buf_get_changedtick(second.bufnr))
		assert.equals("recover-b", state.get_session().id)
		assert.equals(second_win, vim.api.nvim_get_current_win())
		assert.equals(first_win, first.winid); assert.equals(second_win, second.winid)
		assert.equals("Draft recover-a", history.get_pending("recover-a"))
		assert.equals("Draft recover-b", history.get_pending("recover-b"))
	end)
end)
