describe("opencode chat notices and widget correlation", function()
	it("schedules canonical rendering for notices while preserving render=false", function()
		local messages = require("opencode.ui.chat.messages")
		local chat_state = require("opencode.ui.chat.state").state
		local scheduled = {}
		local schedule_count = 0
		local previous_notices = chat_state.local_notices
		local previous_bufnr = chat_state.bufnr

		chat_state.local_notices = {}
		chat_state.bufnr = nil
		messages.set_schedule_render(function(opts)
			schedule_count = schedule_count + 1
			scheduled[schedule_count] = opts
		end)

		local default_id = messages.add_message("system", "canonical notice")
		assert(default_id ~= nil, "default notice should have an id")
		assert(#chat_state.local_notices == 1, "default notice should be retained")
		assert(scheduled[1] and scheduled[1].force == true, "default notice should force canonical rendering")

		messages.add_message("system", "deferred notice", { render = false })
		assert(#chat_state.local_notices == 2, "render=false notice should be retained")
		assert(schedule_count == 2, "render=false should preserve scheduling")
		assert(scheduled[2] == nil, "render=false should preserve the existing no-options scheduling call")

		chat_state.local_notices = previous_notices
		chat_state.bufnr = previous_bufnr
		messages.set_schedule_render(function(opts)
			require("opencode.ui.chat").schedule_render(opts)
		end)
	end)

	it("matches only exact question and edit call ids", function()
		local question_state = require("opencode.question.state")
		local edit_state = require("opencode.edit.state")
		local widget_index = require("opencode.ui.chat.widget_index")

		question_state.clear_all()
		edit_state.clear_all()

		question_state.add_question("question_message_only", "widget_session", {
			{ prompt = "Continue?", options = { { label = "Yes", value = "yes" } } },
		}, { message_id = "widget_message" })
		question_state.add_question("question_call_a", "widget_session", {
			{ prompt = "Continue?", options = { { label = "Yes", value = "yes" } } },
		}, { message_id = "widget_message", call_id = "call-a" })
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
