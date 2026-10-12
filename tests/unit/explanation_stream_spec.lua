describe("native explanation streaming", function()
	local names = { "opencode.client", "opencode.client.api", "opencode.client.sse", "opencode.client.explanation", "opencode.events.sse_bridge" }
	local saved, schedule, calls, listeners, client, updates, progress, finished, endpoint
	local function emit(kind, data)
		for _, listener in ipairs(vim.list_slice(listeners[kind] or {})) do listener(data) end
		for _, listener in ipairs(vim.list_slice(listeners["*"] or {})) do listener(kind, data) end
	end
	local function start()
		return client.generate_explanation("Explain selection", { providerID = "test", id = "explain" },
			function(err, text) finished[#finished + 1] = { err = err, text = text } end,
			{ directory = "/project", timeout = 1000, on_update = function(text) updates[#updates + 1] = text end })
	end
	local function start_completion(callbacks)
		return client.generate_completion("Complete at cursor", { providerID = "test", id = "complete" },
			function(err, text) finished[#finished + 1] = { err = err, text = text } end,
			vim.tbl_extend("force", { directory = "/project", timeout = 1000 }, callbacks or {
				on_progress = function(tokens) progress[#progress + 1] = tokens end,
			}))
	end
	local function create()
		local id = calls[1].args.body.id
		calls[1].callback(nil, { id = id })
		return id
	end
	before_each(function()
		saved, calls, listeners, updates, progress, finished = {}, {}, {}, {}, {}, {}
		for _, name in ipairs(names) do saved[name], package.loaded[name] = package.loaded[name], nil end
		schedule = vim.schedule
		vim.schedule = function(fn) fn() end
		package.loaded["opencode.client.api"] = {
			request = function(name, args, callback)
				local call = { name = name, args = args, callback = callback }
				calls[#calls + 1] = call
				return { cancel = function() call.cancelled = true end }
			end,
			session = function(info) return info end,
		}
		package.loaded["opencode.client.sse"] = {
			is_connected = function() return true end,
			on = function(kind, listener) listeners[kind] = listeners[kind] or {}; table.insert(listeners[kind], listener) end,
			off = function(kind, listener)
				for index, value in ipairs(listeners[kind] or {}) do if value == listener then table.remove(listeners[kind], index); break end end
			end,
		}
		client = require("opencode.client")
		endpoint = { generation = 1 }
		client.endpoint_config = function() return endpoint end
	end)
	after_each(function()
		require("opencode.client.explanation").cancel_all()
		vim.schedule = schedule
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	end)

	it("streams only its session, replaces completed parts, and removes the session on success", function()
		local request = start()
		assert.equals("session_create", calls[1].name)
		local body = calls[1].args.body
		assert.is_true(client.is_explanation_session(body.id))
		assert.same({ directory = "/project" }, body.location)
		assert.same({ providerID = "test", id = "explain" }, body.model)
		assert.same({ { action = "*", resource = "*", effect = "deny" } }, body.permissions)
		local id = create()
		assert.equals("prompt", calls[2].name)
		assert.same({ text = "Explain selection" }, calls[2].args.body)
		calls[2].callback(nil, {})
		local data = { sessionID = "ordinary", assistantMessageID = "msg_1", ordinal = 0, delta = "foreign" }
		emit("session.text.delta", data)
		assert.same({}, updates)
		data.sessionID, data.delta = id, "Hel"
		emit("session.text.delta", data)
		assert.same({ "Hel" }, updates)
		data.delta = "lo"
		emit("session.text.delta", data)
		data.text = "Hello!"
		emit("session.text.ended", data)
		data.delta = "stale"
		emit("session.text.delta", data)
		assert.equals("Hello!", updates[#updates])
		data.ordinal, data.delta = 1, "Second block"
		emit("session.text.delta", data)
		assert.equals("Hello!\n\nSecond block", updates[#updates])
		emit("session.execution.succeeded", { sessionID = id })
		assert.is_false(request.is_active())
		assert.same({ { text = "Hello!\n\nSecond block" } }, finished)
		assert.equals("session_delete", calls[3].name)
		assert.same({ sessionID = id }, calls[3].args.path)
		assert.same({}, listeners["*"])
		assert.same({}, listeners.disconnected)
		assert.same({}, listeners.error)
		emit("session.execution.succeeded", { sessionID = id })
		assert.equals(1, #finished)
	end)

	it("streams cumulative completion output with only on_update and removes the temporary session", function()
		local request = start_completion({ on_update = function(text) updates[#updates + 1] = text end })
		assert.equals("session_create", calls[1].name)
		assert.equals("Completion", calls[1].args.body.title)
		local id = create()
		local listener = listeners["*"][1]
		local data = { sessionID = "foreign", assistantMessageID = "msg_1", ordinal = 0, delta = "ignored" }
		emit("session.text.delta", data)
		data.sessionID, data.delta = id, "private reasoning"
		emit("session.reasoning.delta", data)
		data.text = "private reasoning completed"
		emit("session.reasoning.ended", data)
		assert.same({}, updates)
		data.delta = "loc"
		emit("session.text.delta", data)
		data.delta = "al x"
		emit("session.text.delta", data)
		data.text = "local x = 1"
		emit("session.text.ended", data)
		data.delta = "stale"
		emit("session.text.delta", data)
		assert.same({ "loc", "local x", "local x = 1" }, updates)
		emit("session.execution.succeeded", { sessionID = id })
		listener("session.text.delta", data)
		assert.same({ "loc", "local x", "local x = 1" }, updates)
		assert.same({ { text = "local x = 1" } }, finished)
		assert.is_false(request.is_active())
		assert.equals("session_delete", calls[3].name)
		assert.same({ sessionID = id }, calls[3].args.path)
		assert.same({}, listeners["*"])
		assert.same({}, progress)
	end)

	it("estimates completion progress from output and reasoning characters without including reasoning in the result", function()
		local request = start_completion()
		local body = calls[1].args.body
		assert.equals("Completion", body.title)
		assert.is_true(client.is_explanation_session(body.id))
		assert.same({ directory = "/project" }, body.location)
		assert.same({ providerID = "test", id = "complete" }, body.model)
		assert.same({ { action = "*", resource = "*", effect = "deny" } }, body.permissions)
		assert.equals(1000, calls[1].args.timeout)
		local id = create()
		assert.same({ text = "Complete at cursor" }, calls[2].args.body)
		assert.equals(1000, calls[2].args.timeout)
		local data = { sessionID = "foreign", assistantMessageID = "msg_1", ordinal = 0, delta = "ignored" }
		emit("session.text.delta", data)
		assert.same({}, progress)
		data.sessionID, data.delta = id, "思考中。"
		emit("session.reasoning.delta", data)
		assert.same({ 1 }, progress)
		data.delta = "résu"
		emit("session.text.delta", data)
		assert.equals(2, progress[#progress])
		data.text = "思考中。完成！！"
		emit("session.reasoning.ended", data)
		assert.equals(3, progress[#progress])
		emit("session.reasoning.ended", data)
		assert.equals(3, progress[#progress])
		data.delta = "stale reasoning"
		emit("session.reasoning.delta", data)
		assert.equals(4, #progress)
		data.text = "résultat"
		emit("session.text.ended", data)
		assert.equals(4, progress[#progress])
		data.delta = "stale output"
		emit("session.text.delta", data)
		assert.equals(5, #progress)
		data.ordinal, data.text = 1, "_ok!"
		emit("session.text.ended", data)
		assert.equals(5, progress[#progress])
		local count = #progress
		for _, malformed in ipairs({
			{ sessionID = id, ordinal = 2, delta = "missing message" },
			{ sessionID = id, assistantMessageID = "msg_1", delta = "missing ordinal" },
			{ sessionID = id, assistantMessageID = "msg_1", ordinal = 2, delta = 123 },
		}) do emit("session.text.delta", malformed) end
		emit("session.text.ended", { sessionID = id, assistantMessageID = "msg_1", ordinal = 2, delta = "missing text" })
		emit("session.usage.updated", { sessionID = id, tokens = { output = 999 } })
		assert.equals(count, #progress)
		emit("session.execution.succeeded", { sessionID = id })
		assert.is_false(request.is_active())
		assert.same({ { text = "résultat\n\n_ok!" } }, finished)
		assert.equals("session_delete", calls[3].name)
		assert.same({}, listeners["*"])
		assert.same({}, updates)
	end)

	it("does not report progress when on_update cancels the request", function()
		local request
		request = start_completion({
			on_update = function() request.cancel() end,
			on_progress = function(tokens) progress[#progress + 1] = tokens end,
		})
		local id = create()
		emit("session.text.delta", { sessionID = id, assistantMessageID = "msg_1", ordinal = 0, delta = "code" })
		assert.is_false(request.is_active())
		assert.is_true(finished[1].err.cancelled)
		assert.same({}, progress)
	end)

	it("cancels before creation resolves, then deletes the late session without sending a prompt", function()
		local request = start()
		assert.is_true(request.cancel())
		assert.is_false(request.cancel())
		assert.is_nil(calls[1].cancelled)
		assert.is_true(finished[1].err.cancelled)
		local id = create()
		assert.equals(2, #calls)
		assert.equals("session_delete", calls[2].name)
		assert.equals(id, calls[2].args.path.sessionID)
		assert.same({}, updates)
	end)

	it("does not delete through a changed server endpoint", function()
		local original_notify, notices = vim.notify, {}
		vim.notify = function(message) notices[#notices + 1] = message end
		local request = start()
		endpoint = { generation = 2 }
		request.cancel()
		create()
		vim.notify = original_notify
		assert.equals(1, #calls)
		assert.matches("server changed", notices[1])
	end)

	it("keeps transient sessions out of lists, active status and chat reducers, including late events", function()
		local request = start()
		local id = create()
		local forwarded = {}
		require("opencode.events.sse_bridge").setup({ emit = function(kind, data) forwarded[#forwarded + 1] = { kind, data } end })
		emit("session.created", { sessionID = id, _envelope = { type = "session.created" } })
		assert.same({}, forwarded)
		request.cancel()
		emit("session.deleted", { sessionID = id, _envelope = { type = "session.deleted" } })
		assert.same({}, forwarded)
		client.list_sessions({}, function(err, sessions) assert.is_nil(err); assert.same({ { id = "ordinary" } }, sessions) end)
		calls[#calls].callback(nil, { { id = id }, { id = "ordinary" } })
		client.get_session_statuses(function(err, sessions) assert.is_nil(err); assert.same({ ordinary = { type = "busy" } }, sessions) end)
		calls[#calls].callback(nil, { [id] = {}, ordinary = {} })
	end)
	it("stops text and progress callbacks after cancellation, failure, or disconnect", function()
		for _, generate in ipairs({ client.generate_completion, client.generate_explanation }) do
			for _, outcome in ipairs({ "cancel", "session.execution.failed", "disconnected" }) do
				calls, updates, progress, finished = {}, {}, {}, {}
				local request = generate("Explain selection", { providerID = "test", id = "model" },
					function(err, text) finished[#finished + 1] = { err = err, text = text } end, {
						directory = "/project", timeout = 1000,
						on_update = function(text) updates[#updates + 1] = text end,
						on_progress = function(tokens) progress[#progress + 1] = tokens end,
					})
				local id = create()
				local listener = listeners["*"][1]
				local data = { sessionID = id, assistantMessageID = "msg_1", ordinal = 0, delta = "code" }
				emit("session.text.delta", data)
				if outcome == "cancel" then request.cancel()
				else emit(outcome, { sessionID = id, error = { message = "Provider failed" } }) end
				listener("session.text.delta", data)
				for _, kind in ipairs({ "session.text.ended", "session.reasoning.ended" }) do
					listener(kind, { sessionID = id, assistantMessageID = "msg_1", ordinal = 0, text = "late" })
				end
				assert.same({ "code" }, updates)
				assert.same({ 1 }, progress)
				assert.is_false(request.is_active())
				assert.equals(1, #finished)
				assert.is_truthy(finished[1].err)
				assert.is_true(calls[2].cancelled)
				assert.equals("session_delete", calls[3].name)
				assert.same({}, listeners["*"])
			end
		end
	end)

end)
