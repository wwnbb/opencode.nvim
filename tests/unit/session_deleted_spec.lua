describe("opencode session deleted handling", function()
	local function assert_eq(actual, expected, message)
		assert(
			actual == expected,
			string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual))
		)
	end

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
		assert_eq(state.is_runtime_session("del-root-a"), true, "root A should be a runtime tab")
		assert_eq(state.is_runtime_session("del-root-b"), true, "root B should be a runtime tab")
		assert_eq(state.get_session().id, "del-root-b", "root B should be the active view")

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

		assert_eq(session_actions.handle_deleted("del-root-b"), true, "deleting the current tab should be handled")
		assert_eq(state.get_session().id, "del-root-a", "deleting the current tab should switch to the neighbor")
		assert_eq(state.is_runtime_session("del-root-b"), false, "deleted tab should leave the runtime list")
		assert_eq(#sync.get_messages("del-root-b"), 0, "deleted session data should be cleared")
		local active_ids = {}
		for _, session in ipairs(state.get_active_sessions()) do
			active_ids[session.id] = true
		end
		assert_eq(active_ids["del-root-b"], nil, "deleted tab should disappear from active sessions")

		assert_eq(session_actions.handle_deleted("del-root-a"), true, "deleting the last tab should be handled")
		assert_eq(state.get_session().id, nil, "deleting the last tab should clear the active view")

		assert_eq(session_actions.handle_deleted("del-unknown"), false, "unknown sessions should be ignored")
		assert_eq(session_actions.handle_deleted(""), false, "empty ids should be ignored")

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

		assert_eq(session_actions.handle_deleted("del-child"), true, "deleting a child session should be handled")
		assert_eq(state.is_runtime_session("del-parent"), true, "parent tab should survive a child deletion")
		assert_eq(#sync.get_messages("del-child"), 0, "deleted child data should be cleared")
		assert_eq(state.get_session_record("del-child"), nil, "deleted child record should be removed")
		assert(
			state.get_session().id ~= "del-child",
			"active view should not point at the deleted child"
		)

		state.reset()
		sync.clear_all()
	end)

	it("wires the session_deleted event through the event bus", function()
		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local session_actions = require("opencode.session")
		local events = require("opencode.events")

		state.reset()
		sync.clear_all()
		pcall(function()
			events.setup()
		end)

		session_actions.set_active("del-event-a", "Event A", { reason = "test_setup" })
		session_actions.set_active("del-event-b", "Event B", { reason = "test_setup" })

		events.emit("session_deleted", {
			sessionID = "del-event-b",
			info = { id = "del-event-b", title = "Event B" },
		})

		wait_for(function()
			return state.get_session().id == "del-event-a"
		end, "session_deleted event should switch the active view to the neighbor")
		assert_eq(state.is_runtime_session("del-event-b"), false, "session_deleted event should prune the runtime tab")

		events.emit("session_deleted", {
			info = { id = "del-foreign" },
		})
		vim.wait(100, function()
			return false
		end, 50)
		assert_eq(state.get_session().id, "del-event-a", "foreign session_deleted events should be ignored")

		state.reset()
		sync.clear_all()
	end)
end)
