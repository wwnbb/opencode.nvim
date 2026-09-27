describe("opencode session project scope", function()
	local state = require("opencode.state")
	local session = require("opencode.session")
	local sse = require("opencode.client.sse")
	local original_client, requests, cwd, other
	before_each(function()
		state.reset()
		require("opencode.sync").clear_all()
		cwd = state.normalize_directory(vim.fn.getcwd())
		other = cwd .. "/other-project"
		state.upsert_session({ id = "a", directory = cwd })
		state.upsert_session({ id = "b", directory = other })
		state.set_session("a", "A")
		state.set_session_status("a", { type = "busy" })
		state.set_session_status("b", { type = "busy" })
		requests = {}
		original_client = package.loaded["opencode.client"]
		package.loaded["opencode.client"] = {
			get_session_statuses = function(opts, callback) assert.same({}, opts); requests[#requests + 1] = callback end,
		}
	end)
	after_each(function()
		package.loaded["opencode.client"] = original_client
		state.reset()
		require("opencode.sync").clear_all()
	end)

	it("accepts background project events but drops closed and unrelated projects", function()
		local event = { location = { directory = other .. "/" }, type = "form.created", data = { sessionID = "b" } }
		assert.is_true(sse._should_accept(event))
		assert.is_false(sse._should_accept({ location = { directory = cwd .. "/foreign" }, type = "test", data = {} }))
		state.close_runtime_session("b")
		assert.is_false(sse._should_accept(event))
	end)

	it("filters decoded native events before delivering them", function()
		sse.clear_listeners()
		local seen = 0
		sse.on("form.created", function() seen = seen + 1 end)
		sse.emit("message", { id = "scope-a", type = "form.created", location = { directory = other },
			data = { sessionID = "b", form = { id = "f", sessionID = "b", fields = {} } } })
		assert.equals(1, seen)
		state.close_runtime_session("b")
		sse.emit("message", { id = "scope-b", type = "form.created", location = { directory = other },
			data = { sessionID = "b", form = { id = "f2", sessionID = "b", fields = {} } } })
		assert.equals(1, seen)
		sse.clear_listeners()
	end)

	it("fetches one global active snapshot across directories", function()
		local completed = 0
		session.refresh_status(function(err, statuses)
			assert.is_nil(err)
			assert.equals("busy", statuses.b.type)
			completed = completed + 1
		end)
		assert.equals(1, #requests)
		requests[1](nil, { b = { type = "busy" } })
		assert.equals("idle", state.get_session_status("a").type)
		assert.equals("busy", state.get_session_status("b").type)
		assert.equals(1, completed)
	end)

	it("preserves state on fetch failure and does not recreate a closed tab", function()
		local error_result
		session.refresh_status(function(err) error_result = err end)
		state.close_runtime_session("a")
		requests[1]({ message = "unavailable" })
		assert.equals("busy", state.get_session_status("b").type)
		assert.is_false(state.is_runtime_session("a"))
		assert.equals("unavailable", error_result.message)
	end)

	it("does not overwrite a newer repeated busy event or a closed session", function()
		session.refresh_status()
		state.set_session_status("a", { type = "busy" })
		state.close_runtime_session("b")
		requests[1](nil, {})
		assert.equals("busy", state.get_session_status("a").type)
		assert.is_false(state.is_runtime_session("b"))
	end)

	it("invalidates snapshots on connection generation change", function()
		session.refresh_status()
		require("opencode.session.pending").invalidate()
		requests[1](nil, {})
		assert.equals("busy", state.get_session_status("a").type)
	end)

	it("hydrates child activity into both stores and preserves newer child SSE", function()
		local sync = require("opencode.sync")
		sync.record_task_child_session("a", "m", "part", "child")
		sync.handle_session_messages("child", { require("opencode.protocol.v2.messages").project("child", {
			id = "idle", type = "idle", outcome = "succeeded",
		}) })
		session.refresh_status(); requests[1](nil, {})
		assert.same({ type = "idle", outcome = "succeeded" }, sync.get_session_status("child"))
		assert.equals("idle", state.get_session_status("child").type)
		session.refresh_status()
		sync.handle_session_status("child", { type = "busy" })
		state.set_session_status("child", { type = "busy" })
		requests[2](nil, {})
		assert.equals("busy", sync.get_session_status("child").type)
		assert.equals("busy", state.get_session_status("child").type)
	end)
end)
