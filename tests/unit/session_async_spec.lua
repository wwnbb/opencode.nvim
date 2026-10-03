describe("session actions across connection changes", function()
	local app = require("opencode")
	local actions = require("opencode.actions")
	local client = require("opencode.client")
	local lifecycle = require("opencode.lifecycle")
	local state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local send = require("opencode.send")
	local input_requests = {
		{ action = "cancel_pending_input", method = "cancel_input" },
		{ action = "cancel_submitting_input", method = "cancel_submitting_input" },
		{ action = "edit_pending_input", method = "edit_input" },
		{ action = "steer_pending_input", method = "steer_input" },
		{ action = "queue_pending_input", method = "queue_input" },
	}
	local requests = {
		{ action = "fork_session", method = "fork_session", options = true },
		{ action = "export_session", method = "export_session", options = true },
		{ action = "compact_session", method = "summarize_session", options = true },
		{ action = "get_session", method = "get_session" },
		{ action = "get_session_children", method = "get_session_children" },
		{ action = "list_pending_inputs", method = "get_inbox" },
	}
	local saved, reply, scheduled, input_calls

	before_each(function()
		app.setup({ server = { auto_start = false }, lualine = { enabled = false } })
		state.reset()
		require("opencode.sync").clear_all()
		pending.clear_all()
		saved = { ensure = lifecycle.ensure_connected, create = client.create_session,
			delete = client.delete_session, schedule = vim.schedule, notify = vim.notify, clients = {}, sends = {} }
		reply, scheduled, input_calls = nil, {}, {}
		lifecycle.ensure_connected = function(callback) callback() end
		client.create_session = function(_, callback) reply = callback end
		client.delete_session = function(_, callback) reply = callback end
		for _, request in ipairs(requests) do
			saved.clients[request.method] = client[request.method]
			client[request.method] = function(session_id, opts_or_callback, callback)
				assert.equals("original", session_id)
				reply = callback or opts_or_callback
			end
		end
		for _, request in ipairs(input_requests) do
			saved.sends[request.method] = send[request.method]
			send[request.method] = function(session_id, message_id, callback)
				assert.equals("original", session_id)
				assert.equals("input-one", message_id)
				input_calls[#input_calls + 1] = request.action
				reply = callback
			end
		end
		saved.clients.get_all_sessions, saved.clients.list_integrations = client.get_all_sessions, client.list_integrations
		saved.clients.cancel_input = client.cancel_input
		client.cancel_input = function(_, _, callback) reply = callback end
		client.get_all_sessions = function(_, callback) reply = callback end
		client.list_integrations = function(callback) reply = callback end
		vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
		vim.notify = function() end
		state.set_session("original", "Original")
	end)

	after_each(function()
		lifecycle.ensure_connected, client.create_session, client.delete_session = saved.ensure, saved.create, saved.delete
		vim.schedule, vim.notify = saved.schedule, saved.notify
		for method, original in pairs(saved.clients) do client[method] = original end
		for method, original in pairs(saved.sends) do send[method] = original end
		state.reset()
		require("opencode.sync").clear_all()
		pending.clear_all()
	end)

	local function flush()
		while #scheduled > 0 do table.remove(scheduled, 1)() end
	end

	for _, invalidation in ipairs({ "connection", "session" }) do
		it("does not start queued-input actions after " .. invalidation .. " cancellation while connecting", function()
			local connected = {}
			lifecycle.ensure_connected = function(callback) connected[#connected + 1] = callback end
			for _, request in ipairs(input_requests) do
				actions[request.action]("original", "input-one", function() error("stale callback") end)
			end
			if invalidation == "connection" then pending.invalidate() else pending.clear_session("original") end
			for _, callback in ipairs(connected) do callback() end
			assert.same({}, input_calls)
		end)
	end

	it("drops a late cancellation response after connection invalidation", function()
		local completed = 0
		send.cancel_input = saved.sends.cancel_input
		actions.cancel_pending_input("original", "input-one", function() completed = completed + 1 end)
		pending.invalidate()
		reply(nil)
		flush()
		assert.equals(0, completed)
	end)

	it("keeps input actions bound to their original session when tabs change", function()
		local connected, completed = {}, 0
		lifecycle.ensure_connected = function(callback) connected[#connected + 1] = callback end
		for _, request in ipairs(input_requests) do
			actions[request.action]("original", "input-one", function(err, draft)
				assert.is_nil(err); assert.same({ text = "draft" }, draft)
				completed = completed + 1
			end)
		end
		state.set_session("other", "Other")
		for _, callback in ipairs(connected) do callback(); reply(nil, { text = "draft" }) end
		flush()
		assert.equals(5, #input_calls)
		assert.equals(5, completed)
	end)

	it("ignores a new-session response queued before the connection changes", function()
		app.new_session({ silent = true })
		reply(nil, { id = "old-server", title = "Old server" })
		pending.invalidate()
		flush()
		assert.equals("original", state.get_session().id)
		assert.is_nil(state.get_session_record("old-server"))
	end)

	it("does not create a session on a different connection after waiting", function()
		local connected
		lifecycle.ensure_connected = function(callback) connected = callback end
		app.new_session({ silent = true })
		pending.invalidate()
		connected()
		assert.is_nil(reply)
	end)

	it("deletes only the requested session after switching tabs", function()
		local token = pending.token("original")
		local completed = 0
		actions.delete_session("original", function(err)
			assert.is_nil(err)
			completed = completed + 1
		end)
		state.set_session("other", "Other")
		reply(nil, true)
		flush()
		assert.equals("other", state.get_session().id)
		assert.is_nil(state.get_session_record("original"))
		assert.is_false(pending.is_current(token))
		assert.equals(1, completed)
	end)

	it("ignores a queued deletion response after changing connections", function()
		local completed = 0
		actions.delete_session("original", function() completed = completed + 1 end)
		reply(nil, true)
		pending.invalidate()
		flush()
		assert.is_not_nil(state.get_session_record("original"))
		assert.equals(0, completed)
	end)

	it("ignores queued session operation responses after changing connections", function()
		local completed = 0
		for _, request in ipairs(requests) do
			local callback = function() completed = completed + 1 end
			if request.options then actions[request.action]("original", {}, callback)
			else actions[request.action]("original", callback) end
			reply(nil, {})
		end
		pending.invalidate()
		flush()
		assert.equals(0, completed)
	end)

	it("ignores queued session lists and integrations after changing connections", function()
		local completed = 0
		actions.list_sessions({}, function() completed = completed + 1 end)
		reply(nil, {})
		actions.list_integrations(function() completed = completed + 1 end, {})
		reply(nil, {})
		pending.invalidate()
		flush()
		assert.equals(0, completed)
	end)

	it("completes valid session operations after switching tabs", function()
		local completed = 0
		for _, request in ipairs(requests) do
			local result = { id = request.action }
			local callback = function(err, response)
				assert.is_nil(err)
				assert.same(result, response)
				completed = completed + 1
			end
			if request.options then actions[request.action]("original", {}, callback)
			else actions[request.action]("original", callback) end
			reply(nil, result)
		end
		state.set_session("other", "Other")
		flush()
		assert.equals(6, completed)
	end)

	it("does not start session operations after their session is deleted while waiting", function()
		local connected = {}
		lifecycle.ensure_connected = function(callback) connected[#connected + 1] = callback end
		for _, request in ipairs(requests) do
			local callback = function() error("stale callback") end
			if request.options then actions[request.action]("original", {}, callback)
			else actions[request.action]("original", callback) end
		end
		pending.clear_session("original")
		for _, callback in ipairs(connected) do callback() end
		assert.is_nil(reply)
	end)

	it("does not reconcile an old connection after a late compaction response", function()
		local events = require("opencode.events")
		events.clear_history()
		actions.compact_session("original", {}, function() error("stale callback") end)
		pending.invalidate()
		reply(nil, {})
		flush()
		for _, event in ipairs(events.get_history()) do assert.is_not.equals("v2_reconcile", event.type) end
	end)
end)
