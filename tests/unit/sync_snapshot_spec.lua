describe("opencode HTTP snapshot freshness", function()
	local sync = require("opencode.sync")
	local sid, mid = "snapshot_session", "snapshot_message"
	local function message(id, created, completed)
		return { id = id or mid, sessionID = sid, role = "assistant", time = { created = created or 10, completed = completed } }
	end
	local function part(id, text)
		return { id = id, messageID = mid, sessionID = sid, type = "text", text = text }
	end
	before_each(function() sync.clear_all() end)
	after_each(function() sync.clear_all() end)

	it("preserves a new SSE part and its subsequent deltas", function()
		sync.handle_message_updated(message())
		sync.handle_part_updated(part("p1", "first"))
		local snapshot = sync.capture_session_snapshot(sid)
		sync.handle_part_updated(part("p2", "Hello"))
		sync.handle_session_messages(sid, { { info = message(), parts = { part("p1", "first") } } }, {
			reconcile = true, snapshot = snapshot,
		})
		sync.handle_part_delta({ messageID = mid, sessionID = sid, partID = "p2", field = "text", delta = " world" })
		assert.equals("Hello world", sync.get_part(mid, "p2").text)
	end)

	it("does not regress a completed tool or resurrect an SSE-deleted message", function()
		sync.handle_message_updated(message())
		sync.handle_message_updated(message("removed", 20))
		local tool = { id = "tool", messageID = mid, sessionID = sid, type = "tool", tool = "bash", state = { status = "running" } }
		sync.handle_part_updated(vim.deepcopy(tool))
		local snapshot = sync.capture_session_snapshot(sid)
		local complete = vim.deepcopy(tool)
		complete.state.status = "completed"
		sync.handle_part_updated(complete)
		sync.handle_message_updated(message(nil, nil, 30))
		sync.handle_message_removed(sid, "removed")
		sync.handle_session_messages(sid, {
			{ info = message(), parts = { tool } }, { info = message("removed", 20), parts = {} },
		}, { reconcile = true, snapshot = snapshot })
		assert.equals("completed", sync.get_part(mid, "tool").state.status)
		assert.equals(30, sync.get_message(sid, mid).time.completed)
		assert.is_nil(sync.get_message(sid, "removed"))
	end)

	it("still removes unchanged ghosts inside a fetched page", function()
		sync.handle_message_updated(message())
		sync.handle_message_updated(message("ghost", 15))
		sync.handle_message_updated(message("last", 20))
		sync.handle_part_updated(part("ghost_part", "stale"))
		local snapshot = sync.capture_session_snapshot(sid)
		sync.handle_session_messages(sid, {
			{ info = message(), parts = {} }, { info = message("last", 20), parts = {} },
		}, { reconcile = true, snapshot = snapshot })
		assert.is_nil(sync.get_message(sid, "ghost"))
		assert.is_nil(sync.get_part(mid, "ghost_part"))
	end)

	it("ignores a response after the session cache has been cleared", function()
		sync.handle_message_updated(message())
		local snapshot = sync.capture_session_snapshot(sid)
		sync.clear_session(sid)
		sync.handle_session_messages(sid, { { info = message(), parts = {} } }, { snapshot = snapshot })
		assert.equals(0, #sync.get_messages(sid))
	end)

	it("keeps streaming parts when freshness metadata is unavailable", function()
		sync.handle_message_updated(message())
		sync.handle_part_updated(part("streaming", "text"))
		sync.handle_session_messages(sid, { { info = message(), parts = {} } }, { reconcile = true })
		assert.equals("text", sync.get_part(mid, "streaming").text)
	end)
end)
