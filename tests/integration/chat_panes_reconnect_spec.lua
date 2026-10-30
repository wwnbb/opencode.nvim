local state, sync = require("opencode.state"), require("opencode.sync")
local events, server = require("opencode.events"), require("opencode.events.handlers.server")
local chat, views = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local client, sessions = require("opencode.client"), require("opencode.session")
local locks = require("opencode.session.lock")
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
		locks.clear_all()
		saved = { refresh = sessions.refresh_status }
		for _, name in ipairs({ "get_messages", "get_all_messages", "get_session", "get_inbox", "get_session_statuses" }) do saved[name] = client[name] end
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
		for _, view in ipairs(views.all()) do if view.visible or view.suspended then chat.close_view(view) end end
		if vim.api.nvim_tabpage_is_valid(editor) then vim.api.nvim_set_current_tabpage(editor) end
		for _, id in ipairs({ "recover-a", "recover-b" }) do history.clear_session(id) end
		for name, fn in pairs(saved) do if name ~= "refresh" then client[name] = fn end end
		sessions.refresh_status = saved.refresh
		sync.clear_all(); locks.clear_all()
	end)

	for _, hidden in ipairs({ true }) do
		it("recovers an opened child in a hidden layout without refetching closed children", function()
			local child = { id = "recover-child", parentID = "recover-a", title = "Child", agent = "explore",
				model = { providerID = "old", id = "before" } }
			sessions.remember(child, { touch = false })
			sessions.remember({ id = "recover-closed-child", parentID = "recover-a" }, { touch = false })
			sync.handle_session_messages(child.id, messages(child.id, "Before child"))
			first.session_stack = { { id = "recover-a", name = "recover-a", runtime = true } }
			require("opencode.actions").set_view_session(first, child.id, child.title, { reason = "child_navigation", runtime = false })
			locks.set(child.id, { agent = "explore", model = { providerID = "old", modelID = "before" } })
			if hidden then
				chat.create_layout({ id = "recover-other-layout", title = "Other layout" })
				assert.is_true(first.suspended)
			end
			local selected, window = state.get_session().id, vim.api.nvim_get_current_win()
			local metadata = {}
			client.get_session = function(id, callback) metadata[id] = callback end
			client.get_session_statuses = function(callback) callback(nil, {}) end
			sessions.refresh_status = saved.refresh
			sessions.set_session_status(child.id, { type = "idle", outcome = "succeeded" })
			state.set_connection("connected")
			wait_for(function() return reads.history[child.id] and reads.inbox[child.id] end)
			assert.is_false(state.is_runtime_session(child.id))
			assert.is_nil(reads.history["recover-closed-child"])
			assert.is_nil(metadata["recover-closed-child"])
			child.agent, child.model = "build", { providerID = "new", id = "recovered" }
			for id, replies in pairs(reads.history) do
				metadata[id](nil, id == child.id and child or state.get_session_record(id))
				local recovered = messages(id, id == child.id and "Recovered child" or "Recovered " .. id)
				if id == child.id then
					recovered[#recovered + 1] = project(id, { id = id .. "-idle", type = "idle", time = { created = 2 }, outcome = "interrupted" })
				end
				replies[1](nil, recovered)
				reads.inbox[id][1](nil, {})
			end
			wait_for(function() return sync.get_message_text(child.id .. "-message") == "Recovered child" end)
			assert.equals("recovered", locks.get(child.id).model.modelID)
			assert.equals("build", locks.get(child.id).agent)
			assert.same(child.model, state.get_session_record(child.id).model)
			assert.equals("interrupted", state.get_session_status(child.id).outcome)
			assert.equals("interrupted", sync.get_session_status(child.id).outcome)
			assert.equals(selected, state.get_session().id)
			assert.equals(window, vim.api.nvim_get_current_win())
			if hidden then require("opencode.ui.chat.workspace").select(first.workspace_id) end
			wait_for(function() return text(first):find("Recovered child", 1, true) end)
			vim.wait(150, function() return false end, 10)
			for _, replies in pairs(reads.history) do assert.equals(1, #replies) end
		end)
	end

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
