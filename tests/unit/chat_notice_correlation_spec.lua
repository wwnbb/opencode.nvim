describe("chat widget tool-call correlation", function()
	it("matches only exact question and edit call ids", function()
		local question_state = require("opencode.question.state")
		local edit_state = require("opencode.edit.state")
		local widget_index = require("opencode.ui.chat.widget_index")

		question_state.clear_all()
		edit_state.clear_all()

		local field = { key = "continue", type = "string", title = "Continue?",
			options = { { label = "Yes", value = "yes" } } }
		question_state.add_form({ id = "question_message_only", sessionID = "widget_session",
			fields = { field }, metadata = { tool = { messageID = "widget_message" } },
		})
		question_state.add_form({ id = "question_call_a", sessionID = "widget_session",
			fields = { field }, metadata = { tool = { messageID = "widget_message", id = "call-a" } },
		})
		edit_state.add_edit("edit_message_only", "widget_session", {
			{ filePath = "message-only.lua", before = "a", after = "b" },
		}, { message_id = "widget_message", review_mode = "readonly" })
		edit_state.add_edit("edit_call_b", "widget_session", {
			{ filePath = "call-b.lua", before = "a", after = "b" },
		}, { message_id = "widget_message", call_id = "call-b", review_mode = "readonly" })

		local index = widget_index.new({ current_session = { id = "widget_session" } })
		assert(index:has_question_widget_for_tool_call("widget_message", "call-a"), "question should match its exact call")
		assert(not index:has_question_widget_for_tool_call("widget_message", "call-b"), "message-only question must not hide another call")
		assert(index:has_edit_widget_for_tool_call("widget_message", "call-b"), "edit should match its exact call")
		assert(not index:has_edit_widget_for_tool_call("widget_message", "call-a"), "message-only edit must not hide another call")
		assert(not index:has_question_widget_for_tool_call("widget_message", nil), "nil call id must not match a question")
		assert(not index:has_edit_widget_for_tool_call("widget_message", ""), "empty call id must not match an edit")

		local question_items = index:items_for_tool_call("widget_message", "call-a")
		assert(#question_items == 1 and question_items[1].id == "question_call_a", "tool question items should be exact-call only")
		local edit_items = index:items_for_tool_call("widget_message", "call-b")
		assert(#edit_items == 1 and edit_items[1].id == "edit_call_b", "tool edit items should be exact-call only")

		question_state.clear_all()
		edit_state.clear_all()
	end)
end)
