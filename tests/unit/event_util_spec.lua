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
end)
