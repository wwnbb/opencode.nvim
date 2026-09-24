describe("opencode sync message ordering", function()
	it("orders messages by created time while preserving ID lookup", function()
		local sync = require("opencode.sync")
		sync.clear_all()

		local session_id = "session_message_order"
		sync.handle_message_updated({
			id = "msg_00000000000000000001",
			sessionID = session_id,
			role = "assistant",
			time = { created = 200 },
		})
		sync.handle_message_updated({
			id = "msg_ffffffffffffffffffff",
			sessionID = session_id,
			role = "assistant",
			time = { created = 100 },
		})
		sync.handle_message_updated({
			id = "msg_aaaaaaaaaaaaaaaaaaaa",
			sessionID = session_id,
			role = "assistant",
			time = { created = 100 },
		})

		local messages = sync.get_messages(session_id)
		assert(#messages == 3, "message ordering test should retain all messages")
		assert(messages[1].id == "msg_aaaaaaaaaaaaaaaaaaaa", "equal timestamps should use ID order")
		assert(messages[2].id == "msg_ffffffffffffffffffff", "equal timestamps should use ID order")
		assert(messages[3].id == "msg_00000000000000000001", "created time should take precedence over ID order")
		assert(
			sync.get_message(session_id, "msg_ffffffffffffffffffff") == messages[2],
			"message lookup should remain ID-based after chronological sorting"
		)

		sync.handle_message_removed(session_id, "msg_ffffffffffffffffffff")
		assert(
			sync.get_message(session_id, "msg_ffffffffffffffffffff") == nil,
			"message removal should remain ID-based after chronological sorting"
		)

		sync.clear_all()
	end)

	it("stores a native part before its message without fabricating a placeholder", function()
		local sync = require("opencode.sync")
		sync.clear_all()

		local session_id = "session_message_out_of_order"
		sync.handle_message_updated({
			id = "placeholder_anchor",
			sessionID = session_id,
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "late_part",
			messageID = "late_message",
			sessionID = session_id,
			type = "text",
			text = "complete native content",
		})
		assert(#sync.get_messages(session_id) == 1, "a part update must not invent a message")
		sync.handle_message_updated({
			id = "late_message",
			sessionID = session_id,
			role = "assistant",
			time = { created = 0 },
		})

		local messages = sync.get_messages(session_id)
		assert(#messages == 2, "late native message should be inserted once")
		assert(messages[1].id == "late_message", "late message should be inserted by created time")
		assert(
			sync.get_message(session_id, "late_message") == messages[1],
			"late message should be discoverable by ID"
		)
		assert(sync.get_part("late_message", "late_part").text == "complete native content")

		sync.clear_all()
	end)

	it("invalidates task summaries only for visible child summary data", function()
		local sync = require("opencode.sync")
		sync.clear_all()

		local session_id = "task_summary_revision"
		sync.handle_message_updated({
			id = "assistant_message",
			sessionID = session_id,
			role = "assistant",
			time = { created = 1 },
		})
		local revision = sync.get_task_summary_revision(session_id)

		sync.handle_part_updated({
			id = "assistant_text",
			messageID = "assistant_message",
			sessionID = session_id,
			type = "text",
			text = "streamed answer",
		})
		assert(sync.get_task_summary_revision(session_id) == revision, "assistant text should not invalidate task summaries")

		sync.handle_part_updated({
			id = "assistant_reasoning",
			messageID = "assistant_message",
			sessionID = session_id,
			type = "reasoning",
			text = "private reasoning",
		})
		assert(
			sync.get_task_summary_revision(session_id) == revision,
			"assistant reasoning should not invalidate task summaries"
		)

		sync.handle_part_updated({
			id = "assistant_tool",
			messageID = "assistant_message",
			sessionID = session_id,
			type = "tool",
			tool = "read",
			state = { status = "running", input = {} },
		})
		revision = sync.get_task_summary_revision(session_id)
		assert(revision > 0, "assistant tools should invalidate task summaries")

		sync.handle_message_updated({
			id = "user_message",
			sessionID = session_id,
			role = "user",
			time = { created = 2 },
		})
		local before_user_text = sync.get_task_summary_revision(session_id)
		sync.handle_part_updated({
			id = "user_text",
			messageID = "user_message",
			sessionID = session_id,
			type = "text",
			text = "task prompt",
		})
		assert(
			sync.get_task_summary_revision(session_id) > before_user_text,
			"user text should invalidate the cached task prompt"
		)

		sync.clear_all()
	end)

	it("keeps extra messages during partial hydrate and removes them on complete reconcile", function()
		local sync = require("opencode.sync")
		sync.clear_all()

		local session_id = "session_hydrate_ghosts"
		local function seed(id, created)
			sync.handle_message_updated({
				id = id,
				sessionID = session_id,
				role = "assistant",
				time = { created = created },
			})
		end
		seed("history", 10)
		seed("window_old", 20)
		seed("ghost", 25)
		seed("window_new", 30)
		seed("inflight", 40)
		sync.handle_part_updated({
			id = "window_old_part",
			messageID = "window_old",
			sessionID = session_id,
			type = "text",
			text = "hello",
		})
		sync.handle_part_updated({
			id = "stale_part",
			messageID = "window_old",
			sessionID = session_id,
			type = "text",
			text = "removed on server",
		})

		local snapshot = {
			{
				info = {
					id = "window_old",
					sessionID = session_id,
					role = "assistant",
					time = { created = 20 },
				},
				parts = {
					{
						id = "window_old_part",
						messageID = "window_old",
						sessionID = session_id,
						type = "text",
						text = "hello",
					},
				},
			},
			{
				info = {
					id = "window_new",
					sessionID = session_id,
					role = "assistant",
					time = { created = 30 },
				},
				parts = {},
			},
		}

		sync.handle_session_messages(session_id, snapshot)
		assert(sync.get_message(session_id, "ghost") ~= nil, "upsert-only hydrate must keep ghost messages")
		assert(sync.get_part("window_old", "stale_part") == nil, "native content replaces stale parts of its own message")

		sync.handle_session_messages(session_id, snapshot, {
			reconcile = true,
			complete = true,
			snapshot = sync.capture_session_snapshot(session_id),
		})

		assert(sync.get_message(session_id, "history") == nil, "complete reconcile must remove absent history")
		assert(sync.get_message(session_id, "window_old") ~= nil, "reconcile must keep snapshot messages")
		assert(sync.get_message(session_id, "window_new") ~= nil, "reconcile must keep snapshot messages")
		assert(sync.get_message(session_id, "ghost") == nil, "complete reconcile must remove absent messages")
		assert(sync.get_message(session_id, "inflight") == nil, "complete reconcile must remove absent newer messages")
		assert(sync.get_part("window_old", "window_old_part") ~= nil, "reconcile must keep snapshot parts")
		assert(sync.get_part("window_old", "stale_part") == nil, "reconcile must drop ghost parts")

		sync.clear_all()
	end)
end)
