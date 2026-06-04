-- Headless regression coverage for chat buffer freshness across tab switches,
-- close/reopen, and ambiguous parallel streaming.
-- Run with: ./scripts/test-headless.sh scripts/integration-chat-render-freshness.lua

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
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state").state
local client = require("opencode.client")
local events = require("opencode.events")
local spinner = require("opencode.ui.spinner")
local question_state = require("opencode.question.state")

client.get_messages = function(_, _, callback)
	callback(nil, {})
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
assert_not_contains(buffer_text(), "BRAVO_ONLY_RENDER_TEXT", "initial render should not include session B")

switch_to("fresh-b", "Fresh B")
wait_for_buffer_contains("BRAVO_ONLY_RENDER_TEXT", "switching to B should render cached B text")
assert_not_contains(buffer_text(), "ALPHA_ONLY_RENDER_TEXT", "switching to B should remove stale A text")

switch_to("fresh-a", "Fresh A")
wait_for_buffer_contains("ALPHA_ONLY_RENDER_TEXT", "switching back to A should render cached A text")
assert_not_contains(buffer_text(), "BRAVO_ONLY_RENDER_TEXT", "switching back to A should remove stale B text")

chat.close()
seed_assistant("fresh-a", "fresh-a-msg", "fresh-a-part", "ALPHA_UPDATED_AFTER_CLOSE", 9)
chat.open()
wait_for_buffer_contains("ALPHA_UPDATED_AFTER_CLOSE", "reopened chat should render updated sync content")
assert_not_contains(buffer_text(), "ALPHA_ONLY_RENDER_TEXT", "reopened chat should not keep stale closed buffer content")

sync.clear_all()
app_state.reset()
app_state.set_agent("coder_v2", "coder_v2")
app_state.set_model("gpt-5.5", "GPT-5.5", "openai")
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
app_state.set_agent("coder_v2", "coder_v2")
app_state.set_model("gpt-5.5", "GPT-5.5", "openai")
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
