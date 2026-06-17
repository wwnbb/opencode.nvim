-- Headless regression coverage for chat buffer freshness across tab switches,
-- close/reopen, and ambiguous parallel streaming.
-- Run with: ./tests/run.sh integration

describe("opencode chat render freshness", function()
	it("keeps buffers fresh across tab switches and parallel streams", function()
local function fail(message)
	error(message, 0)
end

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		fail(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_true(value, message)
	if not value then
		fail(message)
	end
end

local function assert_contains(text, needle, message)
	if not text:find(needle, 1, true) then
		fail(message .. ": missing " .. vim.inspect(needle) .. " in " .. vim.inspect(text))
	end
end

local function assert_not_contains(text, needle, message)
	if text:find(needle, 1, true) then
		fail(message .. ": unexpected " .. vim.inspect(needle) .. " in " .. vim.inspect(text))
	end
end

local function count_occurrences(text, needle)
	local _, count = text:gsub(vim.pesc(needle), "")
	return count
end

local function wait_for(predicate, message)
	assert_true(vim.wait(500, predicate, 10), message)
end

vim.o.columns = 120
vim.o.lines = 36

local opencode = require("opencode")
opencode.setup({
	server = {
		auto_start = false,
		lazy = true,
	},
	chat = {
		layout = "float",
		close_on_focus_lost = false,
		session_tabs = {
			enabled = true,
			max_tabs = 4,
		},
	},
	lualine = {
		enabled = false,
	},
})

local app_state = require("opencode.state")
local session_actions = require("opencode.session")
local sync = require("opencode.sync")
local local_state = require("opencode.local")
local chat = require("opencode.ui.chat")
local chat_state_mod = require("opencode.ui.chat.state")
local chat_state = chat_state_mod.state
local render_state = require("opencode.ui.chat.render_state")
local client = require("opencode.client")
local events = require("opencode.events")
local event_util = require("opencode.events.util")
local spinner = require("opencode.ui.spinner")
local question_state = require("opencode.question.state")

client.get_messages = function(_, _, callback)
	callback(nil, {})
end

local function seed_selection()
	sync.handle_providers({
		{
			id = "openai",
			name = "OpenAI",
			models = {
				["gpt-5.5"] = { name = "GPT-5.5" },
			},
		},
	})
	sync.handle_agents({
		{ id = "coder_v2", name = "coder_v2" },
	})
	local_state.agent.set("coder_v2")
	local_state.model.set({ providerID = "openai", modelID = "gpt-5.5" })
end

local function seed_assistant(session_id, message_id, part_id, text, created)
	sync.handle_message_updated({
		id = message_id,
		sessionID = session_id,
		role = "assistant",
		time = {
			created = created or 1,
			completed = (created or 1) + 1,
		},
	})
	sync.handle_part_updated({
		id = part_id,
		messageID = message_id,
		sessionID = session_id,
		type = "text",
		text = text,
	})
end

local function buffer_text()
	local bufnr = chat.get_bufnr()
	return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

local function count_chat_highlights(hl_group)
	local bufnr = chat.get_bufnr()
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return 0
	end
	local count = 0
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_hl_ns, 0, -1, { details = true })) do
		local details = mark[4] or {}
		if details.hl_group == hl_group then
			count = count + 1
		end
	end
	return count
end

local function wait_for_buffer_contains(needle, message)
	wait_for(function()
		return buffer_text():find(needle, 1, true) ~= nil
	end, message)
end

local function switch_to(session_id, title)
	session_actions.switch_to({ id = session_id, title = title or session_id }, { reason = "test_switch" })
	wait_for(function()
		return app_state.get_session().id == session_id
	end, "session should switch to " .. session_id)
end

sync.clear_all()
app_state.reset()
chat.create()

seed_assistant("fresh-a", "fresh-a-msg", "fresh-a-part", "ALPHA_ONLY_RENDER_TEXT", 1)
seed_assistant("fresh-b", "fresh-b-msg", "fresh-b-part", "BRAVO_ONLY_RENDER_TEXT", 3)
session_actions.set_active("fresh-a", "Fresh A", { preserve_cache = true })
session_actions.remember({ id = "fresh-b", title = "Fresh B" }, { touch = true })

chat.open()
wait_for_buffer_contains("ALPHA_ONLY_RENDER_TEXT", "initial session A text should render")
events.emit("message", {
	info = {
		id = "created-msg",
		sessionID = "fresh-a",
		role = "assistant",
		time = { created = 100 },
	},
	parts = {
		{
			id = "created-part",
			messageID = "created-msg",
			type = "text",
			text = "MESSAGE_CREATED_VISIBLE_TEXT",
		},
	},
})
wait_for_buffer_contains(
	"MESSAGE_CREATED_VISIBLE_TEXT",
	"local message.created event should render without switching tabs or reopening chat"
)
assert_not_contains(buffer_text(), "BRAVO_ONLY_RENDER_TEXT", "initial render should not include session B")

switch_to("fresh-b", "Fresh B")
wait_for_buffer_contains("BRAVO_ONLY_RENDER_TEXT", "switching to B should render cached B text")
assert_not_contains(buffer_text(), "ALPHA_ONLY_RENDER_TEXT", "switching to B should remove stale A text")
assert_not_contains(buffer_text(), "MESSAGE_CREATED_VISIBLE_TEXT", "switching to B should remove message.created text from A")

switch_to("fresh-a", "Fresh A")
wait_for_buffer_contains("ALPHA_ONLY_RENDER_TEXT", "switching back to A should render cached A text")
wait_for_buffer_contains("MESSAGE_CREATED_VISIBLE_TEXT", "switching back to A should preserve message.created text")
assert_not_contains(buffer_text(), "BRAVO_ONLY_RENDER_TEXT", "switching back to A should remove stale B text")

chat.close()
seed_assistant("fresh-a", "fresh-a-msg", "fresh-a-part", "ALPHA_UPDATED_AFTER_CLOSE", 9)
chat.open()
wait_for_buffer_contains("ALPHA_UPDATED_AFTER_CLOSE", "reopened chat should render updated sync content")
assert_not_contains(buffer_text(), "ALPHA_ONLY_RENDER_TEXT", "reopened chat should not keep stale closed buffer content")

sync.clear_all()
app_state.reset()
seed_selection()
session_actions.set_active("idle-spinner", "Idle Spinner", { preserve_cache = true })
session_actions.set_session_status("idle-spinner", { type = "idle" }, { reason = "test_idle" })
sync.handle_message_updated({
	id = "idle-spinner-user",
	sessionID = "idle-spinner",
	role = "user",
	time = { created = 40 },
})
sync.handle_part_updated({
	id = "idle-spinner-user-part",
	messageID = "idle-spinner-user",
	sessionID = "idle-spinner",
	type = "text",
	text = "hi",
})
sync.handle_message_updated({
	id = "idle-spinner-assistant",
	sessionID = "idle-spinner",
	role = "assistant",
	parentID = "idle-spinner-user",
	time = { created = 41, completed = 42 },
	agent = "coder_v2",
	mode = "coder_v2",
	modelID = "gpt-5.5",
	providerID = "openai",
	finish = "stop",
})
sync.handle_part_updated({
	id = "idle-spinner-assistant-part",
	messageID = "idle-spinner-assistant",
	sessionID = "idle-spinner",
	type = "text",
	text = "IDLE_SPINNER_DONE_TEXT",
})
spinner.start()
chat.open()
wait_for_buffer_contains("IDLE_SPINNER_DONE_TEXT", "idle spinner regression baseline should render")
assert_not_contains(buffer_text(), "| Coder_v2", "idle completed session should not render a live fallback spinner")
assert_eq(count_occurrences(buffer_text(), "Coder_v2"), 1, "idle completed session should render one assistant footer")
spinner.stop()

sync.clear_all()
app_state.reset()
seed_selection()
session_actions.set_active("highlight-refresh", "Highlight Refresh", { preserve_cache = true })
session_actions.set_session_status("highlight-refresh", { type = "idle" }, { reason = "test_highlights" })
sync.handle_message_updated({
	id = "highlight-user",
	sessionID = "highlight-refresh",
	role = "user",
	time = { created = 70 },
	agent = "coder_v2",
})
sync.handle_part_updated({
	id = "highlight-user-part",
	messageID = "highlight-user",
	sessionID = "highlight-refresh",
	type = "text",
	text = "USER_HIGHLIGHT_REFRESH_TEXT",
})
sync.handle_message_updated({
	id = "highlight-assistant",
	sessionID = "highlight-refresh",
	role = "assistant",
	time = { created = 71, completed = 72 },
	agent = "coder_v2",
	mode = "coder_v2",
	modelID = "gpt-5.5",
	providerID = "openai",
	finish = "tool-calls",
})
sync.handle_part_updated({
	id = "highlight-todos",
	messageID = "highlight-assistant",
	sessionID = "highlight-refresh",
	type = "tool",
	tool = "todowrite",
	state = {
		status = "completed",
		input = {
			todos = {
				{ content = "Keep panel background", status = "completed" },
				{ content = "Keep pending background", status = "pending" },
			},
		},
	},
})
chat.open()
wait_for_buffer_contains("USER_HIGHLIGHT_REFRESH_TEXT", "highlight refresh baseline should render user message")
wait_for_buffer_contains("Keep panel background", "highlight refresh baseline should render todo widget")
assert_true(count_chat_highlights("OpenCodeUserMessageBg") > 0, "user message background should be applied")
assert_true(count_chat_highlights("OpenCodeTodoHeader") > 0, "todo panel header background should be applied")

local todo_pos = chat_state.tools["highlight-todos"]
assert_true(todo_pos ~= nil, "highlight refresh todo widget should be tracked")
render_state.clear_chat_highlights(chat.get_bufnr(), todo_pos.start_line, todo_pos.start_line + 3)
assert_eq(count_chat_highlights("OpenCodeTodoHeader"), 0, "test should clear the todo header extmark")
sync.handle_part_updated({
	id = "highlight-todos",
	messageID = "highlight-assistant",
	sessionID = "highlight-refresh",
	type = "tool",
	tool = "todowrite",
	state = {
		status = "completed",
		input = {
			todos = {
				{ content = "Keep panel background updated", status = "completed" },
				{ content = "Keep pending background", status = "pending" },
			},
		},
	},
})
chat.do_render()
assert_contains(buffer_text(), "Keep panel background updated", "partial todo body update should render")
assert_true(count_chat_highlights("OpenCodeUserMessageBg") > 0, "partial render should keep user background")
assert_true(count_chat_highlights("OpenCodeTodoHeader") > 0, "partial render should restore todo header background")
assert_true(count_chat_highlights("OpenCodeTodoCompleted") > 0, "partial render should restore completed todo background")
assert_true(count_chat_highlights("OpenCodeTodoPending") > 0, "partial render should restore pending todo background")

render_state.clear_chat_highlights(chat.get_bufnr(), 0, -1)
assert_eq(count_chat_highlights("OpenCodeUserMessageBg"), 0, "test should clear user background extmarks")
assert_eq(count_chat_highlights("OpenCodeTodoHeader"), 0, "test should clear todo background extmarks")
chat.do_render()
assert_true(count_chat_highlights("OpenCodeUserMessageBg") > 0, "no-diff render should restore user background")
assert_true(count_chat_highlights("OpenCodeTodoHeader") > 0, "no-diff render should restore todo panel background")

sync.clear_all()
app_state.reset()
seed_selection()
session_actions.set_active("return-a", "Return A", { preserve_cache = true })
session_actions.remember({ id = "return-b", title = "Return B" }, { touch = true })
session_actions.set_session_status("return-a", { type = "busy" }, { reason = "test_busy" })
seed_assistant("return-b", "return-b-msg", "return-b-part", "RETURN_B_VISIBLE_TEXT", 49)
sync.handle_message_updated({
	id = "return-user",
	sessionID = "return-a",
	role = "user",
	time = { created = 50 },
})
sync.handle_part_updated({
	id = "return-user-part",
	messageID = "return-user",
	sessionID = "return-a",
	type = "text",
	text = "generate long text",
})
sync.handle_message_updated({
	id = "return-assistant",
	sessionID = "return-a",
	role = "assistant",
	parentID = "return-user",
	time = { created = 51 },
	agent = "coder_v2",
	mode = "coder_v2",
	modelID = "gpt-5.5",
	providerID = "openai",
})
sync.handle_part_updated({
	id = "return-part",
	messageID = "return-assistant",
	sessionID = "return-a",
	type = "text",
	text = "STREAM_PREFIX_",
})

chat.open()
wait_for_buffer_contains("STREAM_PREFIX_", "stream return baseline should render")
events.emit("message_part_delta", {
	messageID = "return-assistant",
	partID = "return-part",
	sessionID = "return-a",
	field = "text",
	delta = "MIDDLE_",
})
wait_for(function()
	local part = sync.get_part("return-assistant", "return-part")
	return part and part.text == "STREAM_PREFIX_MIDDLE_"
end, "visible stream delta should append")

switch_to("return-b", "Return B")
wait_for_buffer_contains("RETURN_B_VISIBLE_TEXT", "return B should render after switching")
assert_not_contains(buffer_text(), "STREAM_PREFIX_MIDDLE_", "return B should not show return A stream")
events.emit("message_part_delta", {
	messageID = "return-assistant",
	partID = "return-part",
	sessionID = "return-a",
	field = "text",
	delta = "TAIL_",
})
wait_for(function()
	local part = sync.get_part("return-assistant", "return-part")
	return part and part.text == "STREAM_PREFIX_MIDDLE_TAIL_"
end, "hidden session stream delta should still append")

switch_to("return-a", "Return A")
sync.handle_session_messages("return-a", {
	{
		info = {
			id = "return-assistant",
			sessionID = "return-a",
			role = "assistant",
			parentID = "return-user",
			time = { created = 51 },
			agent = "coder_v2",
			mode = "coder_v2",
			modelID = "gpt-5.5",
			providerID = "openai",
		},
		parts = {
			{
				id = "return-part",
				messageID = "return-assistant",
				sessionID = "return-a",
				type = "text",
				text = "STALE_SUFFIX_ONLY",
			},
		},
	},
})
events.emit("sync_changed", {
	kind = "session_messages",
	action = "stale_stream_snapshot",
	session_id = "return-a",
})
vim.wait(100, function()
	return false
end, 10)
local return_part = sync.get_part("return-assistant", "return-part")
assert_eq(return_part and return_part.text, "STREAM_PREFIX_MIDDLE_TAIL_", "stale stream snapshot should not shrink accumulated text")
assert_contains(buffer_text(), "STREAM_PREFIX_MIDDLE_TAIL_", "returning to stream should preserve accumulated text")
assert_not_contains(buffer_text(), "STALE_SUFFIX_ONLY", "returning to stream should not render stale suffix snapshot")

sync.clear_all()
question_state.clear_all()
app_state.reset()
session_actions.set_active("question-tool", "Question Tool", { preserve_cache = true })
session_actions.set_session_status("question-tool", { type = "busy" }, { reason = "test_question_tool" })
local question_payload = {
	{
		header = "Function behavior",
		question = "What should hello_world do?",
		multiple = false,
		options = {
			{
				label = "Return string",
				description = "Return a reusable greeting.",
			},
			{
				label = "Print message",
				description = "Write the greeting to stdout.",
			},
		},
	},
}
local question_tool_part = {
	id = "question-part",
	messageID = "question-msg",
	sessionID = "question-tool",
	type = "tool",
	tool = "question",
	callID = "question-call",
	state = {
		status = "running",
		input = {
			questions = question_payload,
		},
	},
}
sync.handle_message_updated({
	id = "question-msg",
	sessionID = "question-tool",
	role = "assistant",
	time = { created = 60 },
	agent = "coder_v2",
	mode = "coder_v2",
	modelID = "gpt-5.5",
	providerID = "openai",
	finish = "tool-calls",
})
sync.handle_part_updated(question_tool_part)
chat_state.expanded_tools["question-part"] = true
local original_list_questions = client.list_questions
client.list_questions = function(callback)
	callback(nil, {
		{
			id = "que_question_tool",
			sessionID = "question-tool",
			questions = question_payload,
			tool = {
				messageID = "question-msg",
				callID = "question-call",
			},
		},
	})
end
spinner.start()
chat.open()
events.emit("tool_update", {
	session_id = "question-tool",
	message_id = "question-msg",
	tool_name = "question",
	call_id = "question-call",
	status = "running",
	input = {
		questions = question_payload,
	},
})
wait_for_buffer_contains("Function behavior", "question tool recovery should render the widget")
assert_not_contains(buffer_text(), "Input:", "question widget should hide the raw expanded tool input")
assert_not_contains(buffer_text(), " question", "question widget should hide the raw running tool row")
assert_true(not spinner.is_active(), "question tool recovery should stop the visible spinner")
client.list_questions = original_list_questions
spinner.stop()

sync.clear_all()
question_state.clear_all()
app_state.reset()
seed_selection()
session_actions.set_active("task-parent", "Task Parent", { preserve_cache = true })
session_actions.set_session_status("task-parent", { type = "busy" }, { reason = "test_task_child" })
sync.handle_message_updated({
	id = "task-parent-msg",
	sessionID = "task-parent",
	role = "assistant",
	time = { created = 80 },
	agent = "coder_v2",
	mode = "coder_v2",
	modelID = "gpt-5.5",
	providerID = "openai",
	finish = "tool-calls",
})
sync.handle_part_updated({
	id = "task-parent-part",
	messageID = "task-parent-msg",
	sessionID = "task-parent",
	type = "tool",
	tool = "task",
	state = {
		status = "running",
		input = {
			subagent_type = "grep_slave",
			description = "Child render",
		},
		metadata = {
			sessionId = "task-child",
		},
		time = { start = 81 },
	},
})

chat.open()
wait_for_buffer_contains("Child render", "task parent baseline should render")
events.emit("message_updated", {
	info = {
		id = "task-child-msg",
		sessionID = "task-child",
		role = "assistant",
		time = { created = 82 },
		agent = "grep_slave",
		mode = "grep_slave",
		modelID = "gpt-5.5",
		providerID = "openai",
	},
})
events.emit("message_part_updated", {
	part = {
		id = "task-child-read",
		messageID = "task-child-msg",
		sessionID = "task-child",
		type = "tool",
		tool = "read",
		state = {
			status = "running",
			input = {
				filePath = "/tmp/task_child.lua",
			},
			time = { start = 83 },
		},
	},
})
wait_for_buffer_contains(
	"Read /tmp/task_child.lua",
	"task child part update should render in visible parent without switching"
)
events.emit("message_part_delta", {
	messageID = "task-child-msg",
	partID = "task-child-read",
	sessionID = "task-child",
	field = "state.title",
	delta = "Reading child session now",
})
wait_for_buffer_contains(
	"Read Reading child session now",
	"task child part delta should rerender the visible parent without switching"
)

sync.clear_all()
app_state.reset()
seed_selection()
session_actions.set_active("late-parent", "Late Parent", { preserve_cache = true })
chat.open()

local late_parent_sync_events = 0
events.on("sync_changed", function(data)
	if type(data) == "table" and data.session_id == "late-parent" then
		late_parent_sync_events = late_parent_sync_events + 1
	end
end)

local before_late_parent_generation = chat_state.render_generation or 0
events.emit("session_updated", {
	sessionID = "late-child",
	info = {
		id = "late-child",
		parentID = "late-parent",
		time = { created = 90, updated = 90 },
	},
})
wait_for(function()
	return event_util.session_owns_task_child("late-parent", "late-child")
end, "session.updated parentID should mark child relevant to visible parent")
wait_for(function()
	return late_parent_sync_events >= 1 and (chat_state.render_generation or 0) > before_late_parent_generation
end, "late parentID session update should rerender the visible parent")

events.emit("message_updated", {
	info = {
		id = "late-child-msg",
		sessionID = "late-child",
		role = "assistant",
		time = { created = 91 },
	},
})
wait_for(function()
	return late_parent_sync_events >= 2
end, "late child message update should request a parent render")

events.emit("message_part_updated", {
	part = {
		id = "late-child-text",
		messageID = "late-child-msg",
		sessionID = "late-child",
		type = "text",
		text = "LATE_CHILD_TEXT",
	},
})
wait_for(function()
	return late_parent_sync_events >= 3
end, "late child part update should request a parent render")

local before_late_stream_generation = chat_state.render_generation or 0
events.emit("chat_stream_part_updated", {
	session_id = "late-child",
	message_id = "late-child-msg",
	part_id = "late-child-text",
	delta = "STREAM",
	field = "text",
})
wait_for(function()
	return (chat_state.render_generation or 0) > before_late_stream_generation
end, "late child stream update should schedule a parent render")

local original_update_stream_part_block = chat.update_stream_part_block
local original_schedule_render = chat.schedule_render
local fallback_force = nil
chat.update_stream_part_block = function()
	return false
end
chat.schedule_render = function(opts)
	fallback_force = type(opts) == "table" and opts.force == true
end
events.emit("chat_stream_part_updated", {
	session_id = "late-parent",
	message_id = "late-force-msg",
	part_id = "late-force-part",
	delta = "FORCE",
	field = "text",
})
wait_for(function()
	return fallback_force ~= nil
end, "stream fallback should request a render when no in-place block exists")
chat.update_stream_part_block = original_update_stream_part_block
chat.schedule_render = original_schedule_render
assert_true(fallback_force, "stream fallback should force a full render")

sync.clear_all()
app_state.reset()
seed_assistant("stream-a", "stream-a-existing", "stream-a-existing-part", "STREAM_A_VISIBLE_TEXT", 20)
session_actions.set_active("stream-a", "Stream A", { preserve_cache = true })
session_actions.remember({ id = "stream-b", title = "Stream B" }, { touch = true })
session_actions.set_session_status("stream-a", { type = "busy" }, { reason = "test_busy" })
session_actions.set_session_status("stream-b", { type = "busy" }, { reason = "test_busy" })

chat.open()
wait_for_buffer_contains("STREAM_A_VISIBLE_TEXT", "stream A baseline should render")

events.emit("message_part_updated", {
	part = {
		id = "ambiguous-part",
		messageID = "ambiguous-msg",
		type = "text",
		text = "AMBIGUOUS_PARALLEL_STREAM_TEXT",
	},
})

vim.wait(100, function()
	return false
end, 10)
assert_not_contains(
	buffer_text(),
	"AMBIGUOUS_PARALLEL_STREAM_TEXT",
	"ambiguous stream chunk must not patch the visible session while two sessions are busy"
)
assert_eq(sync.get_message("stream-a", "ambiguous-msg"), nil, "ambiguous chunk should not create a message in stream A")

events.emit("message_updated", {
	info = {
		id = "ambiguous-msg",
		sessionID = "stream-b",
		role = "assistant",
		time = {
			created = 30,
			completed = 31,
		},
	},
})
wait_for(function()
	return sync.get_message("stream-b", "ambiguous-msg") ~= nil
end, "later message owner should resolve to stream B")
assert_not_contains(buffer_text(), "AMBIGUOUS_PARALLEL_STREAM_TEXT", "resolved stream B text should stay hidden on stream A")

switch_to("stream-b", "Stream B")
wait_for_buffer_contains("AMBIGUOUS_PARALLEL_STREAM_TEXT", "resolved ambiguous chunk should render in stream B")
assert_not_contains(buffer_text(), "STREAM_A_VISIBLE_TEXT", "stream B render should not include stream A text")

chat.close()
print("Chat render freshness integration passed")
	end)
end)
