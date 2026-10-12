describe("opencode session deleted handling", function()

	local function wait_for(predicate, message)
		assert(vim.wait(500, predicate, 10), message)
	end

	it("prunes deleted runtime tabs and switches the active view", function()
		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local session_actions = require("opencode.session")

		state.reset()
		sync.clear_all()

		session_actions.set_active("del-root-a", "Root A", { reason = "test_setup" })
		session_actions.set_active("del-root-b", "Root B", { reason = "test_setup" })
		assert.equals(true, state.is_runtime_session("del-root-a"), "root A should be a runtime tab")
		assert.equals(true, state.is_runtime_session("del-root-b"), "root B should be a runtime tab")
		assert.equals("del-root-b", state.get_session().id, "root B should be the active view")

		sync.handle_message_updated({
			id = "del-root-b-msg",
			sessionID = "del-root-b",
			role = "user",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "del-root-b-part",
			messageID = "del-root-b-msg",
			sessionID = "del-root-b",
			type = "text",
			text = "bye",
		})
		assert(#sync.get_messages("del-root-b") == 1, "seeded message should exist before deletion")

		assert.equals(true, session_actions.handle_deleted("del-root-b"), "deleting the current tab should be handled")
		assert.equals("del-root-a", state.get_session().id, "deleting the current tab should switch to the neighbor")
		assert.equals(false, state.is_runtime_session("del-root-b"), "deleted tab should leave the runtime list")
		assert.equals(0, #sync.get_messages("del-root-b"), "deleted session data should be cleared")
		local active_ids = {}
		for _, session in ipairs(state.get_active_sessions()) do
			active_ids[session.id] = true
		end
		assert.equals(nil, active_ids["del-root-b"], "deleted tab should disappear from active sessions")

		assert.equals(true, session_actions.handle_deleted("del-root-a"), "deleting the last tab should be handled")
		assert.equals(nil, state.get_session().id, "deleting the last tab should clear the active view")

		assert.equals(false, session_actions.handle_deleted("del-unknown"), "unknown sessions should be ignored")
		assert.equals(false, session_actions.handle_deleted(""), "empty ids should be ignored")

		state.reset()
		sync.clear_all()
	end)

	it("prunes deleted child sessions without closing the parent tab", function()
		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local session_actions = require("opencode.session")

		state.reset()
		sync.clear_all()

		session_actions.set_active("del-parent", "Parent", { reason = "test_setup" })
		sync.handle_message_updated({
			id = "del-parent-msg",
			sessionID = "del-parent",
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "del-parent-task",
			messageID = "del-parent-msg",
			sessionID = "del-parent",
			type = "tool",
			tool = "task",
			state = {
				status = "completed",
				metadata = { sessionId = "del-child" },
			},
		})
		session_actions.remember({ id = "del-child", title = "Child" })
		session_actions.set_active("del-child", "Child", { runtime = false, reason = "test_setup" })

		sync.handle_message_updated({
			id = "del-child-msg",
			sessionID = "del-child",
			role = "assistant",
			time = { created = 2 },
		})
		assert(#sync.get_messages("del-child") == 1, "seeded child message should exist before deletion")

		assert.equals(true, session_actions.handle_deleted("del-child"), "deleting a child session should be handled")
		assert.equals(true, state.is_runtime_session("del-parent"), "parent tab should survive a child deletion")
		assert.equals(0, #sync.get_messages("del-child"), "deleted child data should be cleared")
		assert.equals(nil, state.get_session_record("del-child"), "deleted child record should be removed")
		assert(
			state.get_session().id ~= "del-child",
			"active view should not point at the deleted child"
		)

		state.reset()
		sync.clear_all()
	end)

	it("wires native session.deleted through the event bus", function()
		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local session_actions = require("opencode.session")
		local events = require("opencode.events")

		state.reset()
		sync.clear_all()
		events.setup()

		session_actions.set_active("del-event-a", "Event A", { reason = "test_setup" })
		session_actions.set_active("del-event-b", "Event B", { reason = "test_setup" })

		events.emit("server_event", {
			id = "evt-delete-b",
			type = "session.deleted",
			data = { sessionID = "del-event-b" },
			created = 1,
		})

		wait_for(function()
			return state.get_session().id == "del-event-a"
		end, "native session.deleted event should switch the active view to the neighbor")
		assert.equals(false, state.is_runtime_session("del-event-b"), "native session.deleted event should prune the runtime tab")

		require("tests.helpers.schedule").with(function(flush)
			events.emit("server_event", {
				id = "evt-delete-foreign",
				type = "session.deleted",
				data = { sessionID = "del-foreign" },
				created = 2,
			})
			flush()
			assert.equals("del-event-a", state.get_session().id, "foreign session.deleted events should be ignored")
		end)

		state.reset()
		sync.clear_all()
	end)
end)
