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
			list_sessions = function(_, callback) requests[#requests + 1] = callback end,
			get_messages = function(_, _, callback) requests[#requests + 1] = callback end,
		}
	end)
	after_each(function()
		package.loaded["opencode.client"] = original_client
		state.reset()
		require("opencode.sync").clear_all()
	end)

	it("counts the merged cache rather than one history page after switching", function()
		local sync = require("opencode.sync")
		for index = 1, 2 do
			sync.handle_message_updated({ id = "cached-" .. index, sessionID = "b", role = "user", time = { created = index } })
		end
		session.switch_to(state.get_session_record("b"))
		sync.handle_message_updated({ id = "live", sessionID = "b", role = "user", time = { created = 3 } })
		requests[1](nil, { { info = { id = "cached-2", sessionID = "b", role = "user", time = { created = 2 } }, parts = {} } })
		assert.is_true(vim.wait(500, function() return state.get_session_message_cache("b").loaded == true end, 10))
		assert.equals(3, #sync.get_messages("b"))
		assert.equals(3, state.get_message_count())
		assert.equals(3, state.get_session_message_cache("b").count)
	end)

	it("ignores recent-session lists from another project or connection", function()
		local original_cwd, failure = vim.fn.getcwd, nil
		session.refresh_recent(function(err) failure = err end)
		vim.fn.getcwd = function() return other end
		local ok, err = pcall(requests[1], nil, { { id = "stale-project" } })
		vim.fn.getcwd = original_cwd
		assert.is_true(ok, err)
		assert.is_nil(state.get_session_record("stale-project"))
		assert.equals("cancelled", failure.code)
		session.refresh_recent()
		require("opencode.session.pending").invalidate()
		requests[2](nil, { { id = "stale-server" } })
		assert.is_nil(state.get_session_record("stale-server"))
	end)

	it("keeps the newest recent-session response", function()
		session.refresh_recent()
		session.refresh_recent()
		requests[2](nil, { { id = "newest" } })
		requests[1](nil, { { id = "outdated" } })
		assert.is_not_nil(state.get_session_record("newest"))
		assert.is_nil(state.get_session_record("outdated"))
	end)

	it("accepts background project events but drops closed and unrelated projects", function()
		local event = { location = { directory = other .. "/" }, type = "form.created", data = { sessionID = "b" } }
		assert.is_true(sse._should_accept(event))
		assert.is_false(sse._should_accept({ location = { directory = cwd .. "/foreign" }, type = "test", data = {} }))
		state.close_runtime_session("b")
		assert.is_false(sse._should_accept(event))
	end)

	it("preserves filesystem roots when storing session directories", function()
		assert.equals("/", state.normalize_directory("/"))
		state.upsert_session({ id = "root", directory = "/" })
		assert.equals("/", state.get_session_directory("root"))
	end)

	it("accepts current project events when the working directory is root", function()
		local original_cwd = vim.fn.getcwd
		vim.fn.getcwd = function() return "/" end
		local ok, accepted = pcall(sse._should_accept, { location = { directory = "/" } })
		vim.fn.getcwd = original_cwd
		assert.is_true(ok)
		assert.is_true(accepted)
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
		sync.handle_session_messages("child", { require("opencode.protocol.messages").project("child", {
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
