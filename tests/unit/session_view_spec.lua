local SessionView = require("opencode.session.view")

describe("session views", function()
	it("isolates source data and every table returned by getters", function()
		local record = { id = "s", custom = { value = 1 } }
		local ctx = { status = { type = "retry", attempt = 2 }, pending = { questions = 1 },
			cached_messages = { count = 3, loaded = true } }
		local view = SessionView.from_record(record, ctx)
		record.custom.value, ctx.status.attempt, ctx.pending.questions, ctx.cached_messages.count = 99, 99, 99, 99
		view.record.custom.value, view.status.attempt, view.pending.questions, view.cached_messages.count = 99, 99, 99, 99
		assert.equals(1, view.record.custom.value)
		assert.equals(2, view.status.attempt)
		assert.equals(1, view.pending.questions)
		assert.equals(3, view.cached_messages.count)
	end)

	it("preserves normalized titles and name/id fallbacks", function()
		assert.equals("New session", SessionView.from_record({ title = "New session - 2026-10-12T12:00:00.000Z" }):title())
		assert.equals("Name", SessionView.from_record({ title = "", name = "Name" }):title())
		assert.equals("s", SessionView.from_record({ id = "s" }):title())
		assert.is_nil(SessionView.from_record(nil):title())
	end)

	it("rejects writes", function()
		local view = SessionView.from_record({ id = "s" })
		assert.has_error(function() view.id = "other" end, "SessionView is read-only: cannot assign id")
		assert.equals("s", view.id)
	end)
end)
