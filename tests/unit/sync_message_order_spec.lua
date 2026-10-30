describe("opencode sync message ordering", function()
	local sync = require("opencode.sync")
	local sid = "s"
	local function message(id, created, role)
		sync.handle_message_updated({ id = id, sessionID = sid, role = role or "assistant", time = { created = created } })
	end
	local function part(id, mid, fields)
		sync.handle_part_updated(vim.tbl_extend("force", { id = id, messageID = mid, sessionID = sid, type = "text" }, fields))
	end
	before_each(function() sync.clear_all() end)
	after_each(function() sync.clear_all() end)

	it("stores a native part before its message without fabricating a placeholder", function()
		message("anchor", 1)
		part("late_part", "late", { text = "complete native content" })
		assert.equals(1, #sync.get_messages(sid))
		message("late", 0)
		local messages = sync.get_messages(sid)
		assert.equals(2, #messages)
		assert.equals("late", messages[1].id)
		assert.equals(messages[1], sync.get_message(sid, "late"))
		assert.equals("complete native content", sync.get_part("late", "late_part").text)
	end)

	it("invalidates task summaries only for visible child summary data", function()
		message("a", 1)
		local revision = sync.get_task_summary_revision(sid)
		part("text", "a", { text = "streamed answer" })
		part("reason", "a", { type = "reasoning", text = "private" })
		assert.equals(revision, sync.get_task_summary_revision(sid))
		part("tool", "a", { type = "tool", tool = "read", state = { status = "running", input = {} } })
		revision = sync.get_task_summary_revision(sid)
		assert.is_true(revision > 0)
		message("u", 2, "user")
		local before = sync.get_task_summary_revision(sid)
		part("prompt", "u", { text = "task prompt" })
		assert.is_true(sync.get_task_summary_revision(sid) > before)
	end)

	it("keeps extra messages during partial hydrate and removes them on complete reconcile", function()
		for _, item in ipairs({ { "history", 10 }, { "old", 20 }, { "ghost", 25 }, { "new", 30 }, { "inflight", 40 } }) do
			message(item[1], item[2])
		end
		part("kept", "old", { text = "hello" })
		part("stale", "old", { text = "removed on server" })
		local function info(id, created) return { id = id, sessionID = sid, role = "assistant", time = { created = created } } end
		local page = {
			{ info = info("old", 20), parts = { { id = "kept", messageID = "old", sessionID = sid, type = "text", text = "hello" } } },
			{ info = info("new", 30), parts = {} },
		}
		sync.handle_session_messages(sid, page)
		assert.is_not_nil(sync.get_message(sid, "ghost"))
		assert.is_nil(sync.get_part("old", "stale"), "native content replaces stale parts of its own message")
		sync.handle_session_messages(sid, page, { reconcile = true, complete = true, snapshot = sync.capture_session_snapshot(sid) })
		for _, id in ipairs({ "history", "ghost", "inflight" }) do assert.is_nil(sync.get_message(sid, id)) end
		assert.is_not_nil(sync.get_message(sid, "new"))
		assert.is_not_nil(sync.get_part("old", "kept"))
	end)
end)
