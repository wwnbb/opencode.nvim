local util = require("opencode.events.util")

describe("event error helpers", function()
	it("formats nested errors with optional codes and detects nested aborts", function()
		local err = { type = "error", error = {
			type = "invalid_request", code = "cyber_policy",
			message = "This content was flagged for possible cybersecurity risk.",
		} }
		assert.equals(err.error.message .. " [cyber_policy]", util.format_session_error(err))
		assert.equals(err.error.message, util.format_session_error(err, { include_code = false }))
		assert.is_true(util.is_abort_error({ error = { name = "MessageAbortedError" } }))
	end)

	it("marks only repeated errors as duplicates", function()
		local recent = {}
		assert.is_false(util.mark_recent_error(recent, "session\0error"))
		assert.is_true(util.mark_recent_error(recent, "session\0error"))
	end)

	it("extends the inclusive dedupe window and removes expired or invalid timestamps", function()
		local original_now, now = vim.uv.now, 1000
		vim.uv.now = function() return now end
		local ok, err = pcall(function()
			local recent = { invalid = "bad", expired = 989 }
			assert.is_false(util.mark_recent_error(recent, "error", 10))
			assert.same({ error = 1000 }, recent)
			now = 1010
			assert.is_true(util.mark_recent_error(recent, "error", 10))
			now = 1020
			assert.is_true(util.mark_recent_error(recent, "error", 10))
			now = 1031
			assert.is_false(util.mark_recent_error(recent, "error", 10))
			assert.equals(now, recent.error)
		end)
		vim.uv.now = original_now
		assert.is_true(ok, err)
	end)
end)

describe("event task ownership", function()
	local sync = require("opencode.sync")
	local state = require("opencode.state")
	before_each(function() sync.clear_all(); state.reset() end)
	after_each(function() sync.clear_all(); state.reset() end)

	it("falls back to part metadata while preserving record and index precedence", function()
		local part = { id = "task", messageID = "message", type = "tool", tool = "task",
			metadata = { sessionId = "child" } }
		sync.handle_part_updated(part)
		sync.handle_message_updated({ id = "message", sessionID = "parent", role = "assistant" })
		assert.is_nil(sync.get_task_parent_session("child"))
		assert.is_true(util.session_owns_task_child("parent", "child"))
		assert.is_false(util.session_owns_task_child("parent", "unknown"))

		state.upsert_session({ id = "child", parentID = "other" })
		assert.is_false(util.session_owns_task_child("parent", "child"))
		assert.is_true(util.session_owns_task_child("other", "child"))

		sync.handle_part_updated(vim.tbl_extend("force", part, { sessionID = "parent" }))
		assert.equals("parent", sync.get_task_parent_session("child"))
		assert.is_true(util.session_owns_task_child("parent", "child"))
		assert.is_false(util.session_owns_task_child("other", "child"))
	end)
end)
