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

	it("reconciles a placeholder without duplicating the message", function()
		local sync = require("opencode.sync")
		sync.clear_all()

		local session_id = "session_message_placeholder"
		sync.handle_message_updated({
			id = "placeholder_anchor",
			sessionID = session_id,
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "placeholder_part",
			messageID = "placeholder",
			sessionID = session_id,
			type = "text",
			text = "",
		})
		sync.handle_message_updated({
			id = "placeholder",
			sessionID = session_id,
			role = "assistant",
			time = { created = 0 },
		})

		local messages = sync.get_messages(session_id)
		assert(#messages == 2, "placeholder reconciliation should not duplicate messages")
		assert(messages[1].id == "placeholder", "reconciled message should be reinserted by created time")
		assert(
			sync.get_message(session_id, "placeholder") == messages[1],
			"reconciled placeholder should remain discoverable by ID"
		)

		sync.clear_all()
	end)
end)
