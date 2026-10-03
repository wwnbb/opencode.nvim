describe("direct actions across connection changes", function()
	local actions = require("opencode.actions")
	local client = require("opencode.client")
	local lifecycle = require("opencode.lifecycle")
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local pending = require("opencode.session.pending")
	local saved, scheduled, replies, calls
	local methods = { "list_skills", "get_mcp_status", "get_status", "connect_mcp", "disconnect_mcp", "get_diff",
		"revert_message", "clear_revert", "commit_revert", "abort_session", "wait_session", "dispose" }

	local function flush()
		while #scheduled > 0 do table.remove(scheduled, 1)() end
	end

	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all()
		state.upsert_session({ id = "original", title = "Original", directory = "/project", revert = { messageID = "old" } })
		state.set_session("original", "Original")
		sync.select_catalog_location("/project")
		saved = { schedule = vim.schedule, ensure = lifecycle.ensure_connected }
		scheduled, replies, calls = {}, {}, {}
		vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
		lifecycle.ensure_connected = function() error("Direct actions must not auto-connect") end
		for _, method in ipairs(methods) do
			saved[method] = client[method]
			client[method] = function(...)
				calls[method] = (calls[method] or 0) + 1
				for index = 1, select("#", ...) do
					local value = select(index, ...)
					if type(value) == "function" then replies[method] = value; break end
				end
			end
		end
	end)

	after_each(function()
		for _, method in ipairs(methods) do client[method] = saved[method] end
		vim.schedule, lifecycle.ensure_connected = saved.schedule, saved.ensure
		state.reset(); sync.clear_all(); pending.clear_all()
	end)

	local function query_all(callback)
		actions.list_skills(callback, { directory = "/project/" })
		actions.get_mcp_status(callback)
		actions.get_server_status(callback)
		actions.toggle_mcp("one", false, callback)
		actions.toggle_mcp("two", true, callback)
		actions.get_diff("original", {}, callback)
	end

	it("drops direct callbacks queued before switching connections", function()
		local completed = 0
		query_all(function() completed = completed + 1 end)
		for _, callback in pairs(replies) do callback(nil, {}) end
		pending.invalidate(); sync.clear_all()
		flush()
		assert.equals(0, completed)
		assert.is_nil(sync.get_location_catalog("/project", "skills"))
		assert.is_nil(sync.get_location_catalog("/project", "mcp"))
	end)

	it("completes valid direct requests after switching tabs", function()
		local completed = 0
		query_all(function(err) assert.is_nil(err); completed = completed + 1 end)
		for _, callback in pairs(replies) do callback(nil, {}) end
		state.set_session("other", "Other")
		flush()
		assert.equals(6, completed)
		assert.is_not_nil(sync.get_location_catalog("/project", "skills"))
		assert.is_not_nil(sync.get_location_catalog("/project", "mcp"))
	end)

	for _, operation in ipairs({ "revert_message", "clear_revert", "commit_revert" }) do
		it("ignores a late " .. operation .. " response from the previous connection", function()
			local completed = 0
			local callback = function() completed = completed + 1 end
			if operation == "revert_message" then actions[operation]("original", "new", {}, callback)
			else actions[operation]("original", callback) end
			pending.invalidate()
			replies[operation](nil, { messageID = "new" })
			flush()
			assert.same({ messageID = "old" }, state.get_session_record("original").revert)
			assert.equals(0, completed)
		end)
	end

	for _, phase in ipairs({ { method = "abort_session", next = "wait_session" }, { method = "wait_session", next = "revert_message" } }) do
		it("stops undo after changing connections during " .. phase.method, function()
			local completed = 0
			actions.undo_message("original", "new", function() completed = completed + 1 end)
			if phase.method == "wait_session" then replies.abort_session(nil) end
			pending.invalidate()
			replies[phase.method](nil)
			flush()
			assert.is_nil(calls[phase.next])
			assert.equals(0, completed)
		end)
	end

	it("completes undo for its original session after switching tabs", function()
		local completed = 0
		actions.undo_message("original", "new", function(err) assert.is_nil(err); completed = completed + 1 end)
		state.set_session("other", "Other")
		replies.abort_session(nil)
		replies.wait_session(nil)
		replies.revert_message(nil, { messageID = "new" })
		flush()
		assert.equals(1, completed)
		assert.equals("other", state.get_session().id)
		assert.same({ messageID = "new" }, state.get_session_record("original").revert)
	end)

	it("publishes reload success after its own cleanup invalidates pending requests", function()
		local token, completed = pending.token(), 0
		actions.reload_locations(function(err) assert.is_nil(err); completed = completed + 1 end)
		replies.dispose(nil, true)
		flush()
		assert.is_false(pending.is_current(token))
		assert.equals(1, completed)
	end)
end)
