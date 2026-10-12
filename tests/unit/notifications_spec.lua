describe("event notifications", function()
	local bus = require("opencode.events.bus")
	local state = require("opencode.state")
	local forms = require("opencode.question.state")
	local original_notify, original_schedule, notices, scheduled
	local function drain()
		while #scheduled > 0 do table.remove(scheduled, 1)() end
	end

	before_each(function()
		bus.clear(); forms.clear_all(); state.reset()
		state.set_session("notify-session", "Notify")
		notices, scheduled = {}, {}
		original_schedule = vim.schedule
		vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
		original_notify = vim.notify
		vim.notify = function(message) notices[#notices + 1] = tostring(message) end
		require("opencode.events.handlers.notifications").setup(bus)
	end)

	after_each(function()
		vim.notify, vim.schedule = original_notify, original_schedule
		bus.clear(); forms.clear_all(); state.reset()
	end)

	it("deduplicates native form prompts and clears terminal IDs", function()
		local form = { id = "form", sessionID = "notify-session", fields = {
			{ key = "ok", title = "Continue?", type = "boolean", required = true },
		} }
		forms.add_form(form)
		local pending = { kind = "question", action = "pending", id = "form", session_id = "notify-session" }
		bus.emit("interaction_changed", pending)
		bus.emit("interaction_changed", pending)
		drain(); assert.equals(1, #notices)
		forms.mark_rejected("form")
		bus.emit("interaction_changed", { kind = "question", action = "rejected", id = "form", session_id = "notify-session" })
		forms.remove_question("form")
		bus.emit("interaction_changed", pending)
		drain()
		assert.equals(1, #notices)
		-- Reintroducing the same ID makes stale notification dedupe observable.
		forms.add_form(form)
		bus.emit("interaction_changed", pending)
		drain(); assert.equals(2, #notices)
	end)

	it("reports native execution failure without a false done notice", function()
		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "busy" } })
		bus.emit("server_event", { type = "session.execution.failed", data = {
			sessionID = "notify-session", error = { message = "native failure" },
		} })
		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "idle", outcome = "failed" } })
		drain(); assert.is_true(#notices > 0)
		drain()
		assert.is_truthy(table.concat(notices, "\n"):find("native failure", 1, true))
		assert.is_nil(table.concat(notices, "\n"):find("Session done", 1, true))
	end)

	it("suppresses done after failure without an idle outcome and allows the next successful run", function()
		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "busy" } })
		bus.emit("server_event", { type = "session.execution.failed", data = {
			sessionID = "notify-session", error = { message = "native failure" },
		} })
		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "idle" } })
		drain()
		assert.same({ "Notify: native failure" }, notices)

		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "busy" } })
		bus.emit("session_status_change", { session_id = "notify-session", status = { type = "idle" } })
		drain()
		assert.same({ "Notify: native failure", "Notify: Session done" }, notices)
	end)

	it("preserves always notifications and applies native focused/blurred/unknown filters", function()
		local function done()
			bus.emit("session_status_change", { session_id = "notify-session", status = { type = "busy" } })
			bus.emit("session_status_change", { session_id = "notify-session", status = { type = "idle" } })
			drain()
		end
		state.set_config({ notifications = { when = "blurred" } })
		done(); assert.equals(0, #notices, "unknown focus is not blurred")
		vim.api.nvim_exec_autocmds("FocusGained", {})
		done(); assert.equals(0, #notices)
		vim.api.nvim_exec_autocmds("FocusLost", {})
		done(); assert.equals(1, #notices)
		state.set_config({ notifications = { when = "focused" } })
		done(); assert.equals(1, #notices)
		vim.api.nvim_exec_autocmds("FocusGained", {})
		done(); assert.equals(2, #notices)
		state.set_config({ notifications = {} })
		done(); assert.equals(3, #notices, "default preserves focused notifications")
		state.set_config({ notifications = { enabled = false, when = "always" } })
		done(); assert.equals(3, #notices)
	end)
end)
