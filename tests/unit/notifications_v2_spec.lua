describe("v2 event notifications", function()
	local bus = require("opencode.events.bus")
	local state = require("opencode.state")
	local forms = require("opencode.question.state")
	local original_notify, notices

	before_each(function()
		bus.clear(); forms.clear_all(); state.reset()
		state.set_session("notify-session", "Notify")
		notices = {}
		original_notify = vim.notify
		vim.notify = function(message) notices[#notices + 1] = tostring(message) end
		require("opencode.events.handlers.notifications").setup(bus)
	end)

	after_each(function()
		vim.notify = original_notify
		bus.clear(); forms.clear_all(); state.reset()
	end)

	it("deduplicates native form prompts and clears terminal IDs", function()
		forms.add_form({ id = "form", sessionID = "notify-session", fields = {
			{ key = "ok", title = "Continue?", type = "boolean", required = true },
		} })
		local pending = { kind = "question", action = "pending", id = "form", session_id = "notify-session" }
		bus.emit("interaction_changed", pending)
		bus.emit("interaction_changed", pending)
		assert.is_true(vim.wait(500, function() return #notices == 1 end, 10))
		bus.emit("interaction_changed", { kind = "question", action = "form.cancelled", id = "form", session_id = "notify-session" })
		forms.remove_question("form")
		bus.emit("interaction_changed", pending)
		vim.wait(30)
		assert.equals(1, #notices)
	end)

	it("reports native execution failure without a false done notice", function()
		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "busy" } })
		bus.emit("v2_event", { type = "session.execution.failed", data = {
			sessionID = "notify-session", error = { message = "native failure" },
		} })
		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "idle", outcome = "failed" } })
		assert.is_true(vim.wait(500, function() return #notices > 0 end, 10))
		vim.wait(30)
		assert.is_truthy(table.concat(notices, "\n"):find("native failure", 1, true))
		assert.is_nil(table.concat(notices, "\n"):find("Session done", 1, true))
	end)
end)
