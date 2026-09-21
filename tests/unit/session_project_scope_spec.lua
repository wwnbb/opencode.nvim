describe("opencode session project scope", function()
	local state = require("opencode.state")
	local session = require("opencode.session")
	local sse = require("opencode.client.sse")
	local original_client, requests, cwd, other
	before_each(function()
		state.reset()
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
			get_session_statuses = function(opts, callback) requests[opts.directory] = callback end,
		}
	end)
	after_each(function()
		package.loaded["opencode.client"] = original_client
		state.reset()
	end)

	it("accepts background project events but drops closed and unrelated projects", function()
		local event = { directory = other .. "/", payload = { type = "question.asked", properties = { sessionID = "b" } } }
		assert.is_true(sse._should_accept(event))
		assert.is_false(sse._should_accept({ directory = cwd .. "/foreign", payload = { type = "test" } }))
		state.close_runtime_session("b")
		assert.is_false(sse._should_accept(event))
	end)

	it("reconciles each project independently and completes the callback once", function()
		local completed, combined = 0, nil
		session.refresh_status(function(err, statuses)
			assert.is_nil(err)
			completed, combined = completed + 1, statuses
		end)
		assert.is_not_nil(requests[cwd])
		assert.is_not_nil(requests[other])
		requests[cwd](nil, {})
		assert.equals("idle", state.get_session_status("a").type)
		assert.equals("busy", state.get_session_status("b").type)
		assert.equals(0, completed)
		requests[other](nil, { b = { type = "busy" } })
		assert.equals("busy", state.get_session_status("b").type)
		assert.equals(1, completed)
		assert.equals("busy", combined.b.type)
	end)

	it("preserves status on a project fetch failure and does not recreate a closed tab", function()
		local error_result
		session.refresh_status(function(err) error_result = err end)
		state.close_runtime_session("a")
		requests[other]({ message = "unavailable" })
		requests[cwd](nil, { a = { type = "busy" } })
		assert.equals("busy", state.get_session_status("b").type)
		assert.is_false(state.is_runtime_session("a"))
		assert.equals("unavailable", error_result.message)
	end)
end)
