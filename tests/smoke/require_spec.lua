-- Module-load smoke coverage for opencode.nvim.
-- Run with: ./tests/run.sh smoke

describe("opencode.nvim smoke require", function()
	it("loads modules and exercises setup", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local function stub_module(name, value)
	package.preload[name] = package.preload[name] or function()
		return value
	end
end

local noop = function() end
local popup = {}
popup.__index = popup
function popup:new(opts)
	return setmetatable({
		opts = opts or {},
		bufnr = vim.api.nvim_get_current_buf(),
		winid = vim.api.nvim_get_current_win(),
	}, self)
end
function popup:mount() end
function popup:unmount() end
function popup:map() end
function popup:on() end
setmetatable(popup, {
	__call = function(cls, opts)
		return cls:new(opts)
	end,
})

local line = {}
line.__index = line
function line:new()
	return setmetatable({ _content = "" }, self)
end
function line:append(text)
	self._content = self._content .. tostring(text or "")
end
function line:content()
	return self._content
end
function line:highlight() end
setmetatable(line, {
	__call = function(cls)
		return cls:new()
	end,
})

stub_module("nui.popup", popup)
stub_module("nui.input", popup)
stub_module("nui.split", popup)
stub_module("nui.layout", { new = function() return popup:new() end })
stub_module("nui.line", line)
stub_module("nui.text", function(text) return text end)
stub_module("nui.utils.autocmd", { event = setmetatable({}, { __index = function(_, key) return key end }) })
stub_module("plenary.job", {
	new = function(_, opts)
		return {
			pid = 0,
			start = noop,
			shutdown = noop,
			opts = opts or {},
		}
	end,
})

local function scandir(dir, out)
	out = out or {}
	local handle = vim.uv.fs_scandir(dir)
	if not handle then
		return out
	end
	while true do
		local name, kind = vim.uv.fs_scandir_next(handle)
		if not name then
			break
		end
		local path = dir .. "/" .. name
		if kind == "directory" then
			scandir(path, out)
		elseif kind == "file" and path:match("%.lua$") then
			table.insert(out, path)
		end
	end
	return out
end

local function module_name(path)
	local name = path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
	return name:gsub("%.init$", "")
end

local failures = {}
local files = scandir("lua/opencode")
table.sort(files)
for _, path in ipairs(files) do
	local mod = module_name(path)
	local ok, err = pcall(require, mod)
	if not ok then
		table.insert(failures, string.format("%s: %s", mod, tostring(err)))
	end
end

if #failures > 0 then
	print("Smoke require failures:")
	for _, failure in ipairs(failures) do
		print("  " .. failure)
	end
	error("Smoke require failures:\n  " .. table.concat(failures, "\n  "), 0)
end

local event_util = require("opencode.events.util")
local nested_session_error = {
	type = "error",
	sequence_number = 113,
	error = {
		type = "invalid_request",
		code = "cyber_policy",
		message = "This content was flagged for possible cybersecurity risk.",
	},
}
assert(
	event_util.format_session_error(nested_session_error) == "This content was flagged for possible cybersecurity risk. [cyber_policy]",
	"nested session error did not format cleanly"
)
assert(
	event_util.format_session_error(nested_session_error, { include_code = false })
		== "This content was flagged for possible cybersecurity risk.",
	"nested session error did not support code-free formatting"
)
assert(event_util.is_abort_error({ error = { name = "MessageAbortedError" } }), "nested abort error was not detected")
local recent_errors = {}
assert(event_util.mark_recent_error(recent_errors, "session\0error") == false, "first recent error was marked duplicate")
assert(event_util.mark_recent_error(recent_errors, "session\0error") == true, "duplicate recent error was not detected")

local changes = require("opencode.artifact.changes")
local top_insert = changes.calculate_hunks({ "a", "b", "c" }, { "x", "a", "b", "c" })
assert(#top_insert == 1, "top insertion should produce one hunk")
assert(top_insert[1].line_count == 1, "top insertion should not mark shifted lines as changed")
assert(top_insert[1].original_lines[1] == "", "top insertion original side should be empty")
assert(top_insert[1].modified_lines[1] == "x", "top insertion modified side should contain inserted line")
local middle_insert = changes.calculate_hunks({ "a", "b", "c" }, { "a", "x", "b", "c" })
assert(middle_insert[1].start_line == 2, "middle insertion should start at inserted position")
assert(middle_insert[1].line_count == 1, "middle insertion should produce minimal hunk")
local middle_delete = changes.calculate_hunks({ "a", "b", "c" }, { "a", "c" })
assert(middle_delete[1].start_line == 2, "middle deletion should start at removed line")
assert(middle_delete[1].original_lines[1] == "b", "middle deletion original side should contain removed line")
assert(middle_delete[1].modified_lines[1] == "", "middle deletion modified side should be empty")

local search = require("opencode.ui.chat.search")
local rg = require("opencode.ui.chat.rg")
local function render_text(result)
	return table.concat(result and result.lines or {}, "\n")
end

local grep_render = search.render_tool({
	tool = "grep",
	state = {
		status = "completed",
		input = { pattern = "local" },
		output = "path:with:colon/file.lua:12:3:local x = 1",
	},
	metadata = { matches = 1 },
}, true)
assert(render_text(grep_render):find("path:with:colon/file.lua:12:3:local x = 1", 1, true), "grep widget should render colon-containing paths")

local rg_render = rg.render_tool({
	tool = "rg",
	state = {
		status = "completed",
		input = { pattern = "local" },
		output = "path:with:colon/file.lua-12-local x = 1",
	},
	metadata = { matches = 1 },
}, true)
assert(render_text(rg_render):find("path:with:colon/file.lua-12-local x = 1", 1, true), "rg widget should render context lines with colon-containing paths")

local thinking = require("opencode.ui.thinking")
assert(thinking.is_enabled(), "Thought display should be enabled by default")
assert(thinking.get_config().header_highlight == "WarningMsg", "Thought header should use the configured highlight")

do
	require("opencode.ui.input.info_bar").setup_highlights()
	local user_bg = vim.api.nvim_get_hl(0, { name = "OpenCodeUserMessageBg" })
	local input_bg = vim.api.nvim_get_hl(0, { name = "OpenCodeInputBg" })
	assert(user_bg.link == "CursorLine", "user message background should default to CursorLine")
	assert(input_bg.link == "OpenCodeUserMessageBg", "input background should default to user message background")

	local popups = require("opencode.ui.input.popups")
	local popup_obj, info_popup_obj = popups.mount({
		popup = {
			relative = "editor",
			position = { row = 1, col = 1 },
			size = { width = 20, height = 1 },
		},
		info = {
			relative = "editor",
			position = { row = 2, col = 1 },
			size = { width = 20, height = 1 },
		},
	})
	local popup_winhighlight = popup_obj.opts.win_options.winhighlight
	local info_winhighlight = info_popup_obj.opts.win_options.winhighlight
	assert(
		popup_winhighlight:find("Normal:OpenCodeInputBg", 1, true)
			and popup_winhighlight:find("EndOfBuffer:OpenCodeInputBg", 1, true),
		"input popup normal and empty cells should use the shared input background"
	)
	assert(
		info_winhighlight:find("Normal:OpenCodeInputBg", 1, true)
			and info_winhighlight:find("EndOfBuffer:OpenCodeInputBg", 1, true),
		"input info popup normal and empty cells should use the shared input background"
	)
	assert(
		popup_winhighlight:find("FloatBorder:OpenCodeInputBorderAgent", 1, true)
			and info_winhighlight:find("FloatBorder:OpenCodeInputBorderAgent", 1, true),
		"input popup border should keep the agent-specific highlight"
	)
end

local sync = require("opencode.sync")
sync.clear_all()
sync.handle_part_updated({
	id = "text-visible",
	messageID = "msg_synthetic_filter",
	sessionID = "session_synthetic_filter",
	type = "text",
	text = "visible",
})
sync.handle_part_updated({
	id = "text-synthetic",
	messageID = "msg_synthetic_filter",
	sessionID = "session_synthetic_filter",
	type = "text",
	text = "hidden",
	synthetic = true,
})
assert(
	sync.get_message_text("msg_synthetic_filter", { include_synthetic = false }) == "visible",
	"synthetic text parts should be excluded when include_synthetic=false"
)
sync.clear_all()

do
	local input_keymaps = require("opencode.ui.input.keymaps")
	local bufnr = vim.api.nvim_create_buf(false, true)
	local function has_buffer_keymap(mode, lhs)
		for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
			if keymap.lhs == lhs then
				return true
			end
		end
		return false
	end

	input_keymaps.setup(bufnr, {
		keymaps = {
			send = "<C-g>",
			send_alt = "<C-x><C-s>",
			cancel = "<Esc>",
		},
	}, {
		send = noop,
		cancel = noop,
	})

	assert(not has_buffer_keymap("i", "<Esc>"), "input should allow <Esc> to leave insert mode")
	assert(has_buffer_keymap("n", "<Esc>"), "input should keep normal-mode <Esc> cancel mapping")
	vim.api.nvim_buf_delete(bufnr, { force = true })
end

do
	local chat_state = require("opencode.ui.chat.state").state
	local render_state = require("opencode.ui.chat.render_state")
	local previous = {
		questions = chat_state.questions,
		permissions = chat_state.permissions,
		edits = chat_state.edits,
		tasks = chat_state.tasks,
		tools = chat_state.tools,
	}

	chat_state.questions = {}
	chat_state.permissions = {}
	chat_state.edits = {}
	chat_state.tasks = {}
	chat_state.tools = {
		widget_highlight_range = {
			start_line = 10,
			end_line = 20,
			highlights = {
				{ line = 1, col_start = 0, col_end = 10, hl_group = "PanelHeaderTest" },
			},
		},
	}

	assert(
		render_state.highlight_clear_start(15, {}) == 10,
		"highlight clear should expand from inside a widget to the widget start"
	)
	assert(
		render_state.highlight_clear_start(21, {}) == 21,
		"highlight clear should not expand outside the widget range"
	)

	chat_state.questions = previous.questions
	chat_state.permissions = previous.permissions
	chat_state.edits = previous.edits
	chat_state.tasks = previous.tasks
	chat_state.tools = previous.tools
end

do
	local seq = 0
	local function event(kind, data)
		seq = seq + 1
		return sync.handle_v2_event({ id = "evt_stream_smoke_" .. seq, created = seq,
			type = "session." .. kind, data = vim.tbl_extend("force", {
				sessionID = "session_stream", assistantMessageID = "msg_stream", ordinal = 0,
			}, data or {}) })
	end
	event("step.started", { started = 1, agent = "build", model = { providerID = "test", id = "test" } })
	event("text.started")
	for _, delta in ipairs({ "hel", "lo", " world" }) do event("text.delta", { delta = delta }) end
	assert(sync.get_parts("msg_stream")[1].text == "hello world", "v2 text deltas should accumulate")
	event("text.ended", { text = "authoritative" })
	assert(sync.get_parts("msg_stream")[1].text == "authoritative", "v2 ended text should replace deltas")
	event("reasoning.started")
	event("reasoning.delta", { delta = "because" })
	assert(sync.get_message_render_parts("msg_stream").reasoning == "because", "v2 reasoning should stream")
	sync.clear_all()
end

do
	sync.handle_message_updated({
		id = "msg_render_accessor",
		sessionID = "session_render_accessor",
		role = "user",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "a_text",
		messageID = "msg_render_accessor",
		sessionID = "session_render_accessor",
		type = "text",
		text = "visible",
	})
	sync.handle_part_updated({
		id = "b_synthetic",
		messageID = "msg_render_accessor",
		sessionID = "session_render_accessor",
		type = "text",
		text = "hidden",
		synthetic = true,
	})
	sync.handle_part_updated({
		id = "c_reason",
		messageID = "msg_render_accessor",
		sessionID = "session_render_accessor",
		type = "reasoning",
		text = "why",
	})
	sync.handle_part_updated({
		id = "d_tool",
		messageID = "msg_render_accessor",
		sessionID = "session_render_accessor",
		type = "tool",
		tool = "bash",
		state = { status = "completed" },
	})
	local render_parts = sync.get_message_render_parts("msg_render_accessor", { include_synthetic = false })
	assert(render_parts.content == "visible", "render accessor should honor include_synthetic=false")
	assert(render_parts.reasoning == "why", "render accessor should collect reasoning")
	assert(#render_parts.tool_parts == 1 and render_parts.tool_parts[1].id == "d_tool", "render accessor should collect tools")
	assert(render_parts.parts[1].id == "a_text" and render_parts.parts[4].id == "d_tool", "render accessor should preserve part order")
	assert(render_parts.message_revision > 0, "render accessor should include message revision")
	assert(render_parts.part_revisions.a_text > 0, "render accessor should include part revisions")
	sync.clear_all()
end

do
	local event_util_for_tasks = require("opencode.events.util")
	sync.handle_message_updated({
		id = "task_index_message",
		sessionID = "task_parent",
		role = "assistant",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "task_index_part",
		messageID = "task_index_message",
		sessionID = "task_parent",
		type = "tool",
		tool = "task",
		metadata = { sessionId = "task_child_a" },
	})
	assert(sync.get_task_parent_session("task_child_a") == "task_parent", "task child index should record parent")
	assert(event_util_for_tasks.session_owns_task_child("task_parent", "task_child_a"), "task ownership should use index")
	sync.handle_part_updated({
		id = "task_index_part",
		messageID = "task_index_message",
		sessionID = "task_parent",
		type = "tool",
		tool = "task",
		metadata = { sessionId = "task_child_b" },
	})
	assert(sync.get_task_parent_session("task_child_a") == nil, "task index should clear replaced child")
	assert(sync.get_task_parent_session("task_child_b") == "task_parent", "task index should record replacement child")
	sync.handle_part_removed("task_index_message", "task_index_part")
	assert(sync.get_task_parent_session("task_child_b") == nil, "task index should clear removed child")
	sync.clear_all()
end

do
	local event_util_for_tasks = require("opencode.events.util")
	local actions_for_tasks = require("opencode.actions")
	local events = require("opencode.events")

	events.clear()
	sync.handle_message_updated({
		id = "task_state_message",
		sessionID = "task_state_parent",
		role = "assistant",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "task_state_part",
		messageID = "task_state_message",
		sessionID = "task_state_parent",
		type = "tool",
		tool = "task",
		state = { metadata = { sessionID = "task_state_child" } },
	})
	assert(sync.get_task_parent_session("task_state_child") == "task_state_parent", "state.metadata sessionID should index child")

	local sync_changed = 0
	events.on("sync_changed", function(data)
		if
			data
			and data.session_id == "task_state_parent"
			and data.message_id == "task_state_message"
			and data.part_id == "task_state_late_part"
		then
			sync_changed = sync_changed + 1
		end
	end)
	sync.handle_part_updated({
		id = "task_state_late_part",
		messageID = "task_state_message",
		sessionID = "task_state_parent",
		type = "tool",
		tool = "task",
		state = {
			status = "running",
			input = { subagent_type = "build", description = "late child" },
		},
	})
	sync.handle_message_updated({
		id = "task_state_late_child_msg",
		sessionID = "task_state_late_child",
		role = "assistant",
		time = { created = 2 },
	})
	sync.handle_part_updated({
		id = "task_state_late_child_tool",
		messageID = "task_state_late_child_msg",
		sessionID = "task_state_late_child",
		type = "tool",
		tool = "read",
		state = { status = "running", input = { filePath = "/tmp/late.lua" } },
	})
	assert(
		actions_for_tasks.record_task_child_session(
			"task_state_parent",
			"task_state_message",
			"task_state_late_part",
			"task_state_late_child"
		) == true,
		"action boundary should record late child mapping"
	)
	assert(sync_changed == 1, "late child mapping should emit one parent part sync_changed event")
	assert(
		event_util_for_tasks.session_owns_task_child("task_state_parent", "task_state_late_child"),
		"late mapped child should be relevant to the parent"
	)
	events.clear()
	sync.clear_all()
end

do
	local saved_client = package.loaded["opencode.client"]
	local saved_http = package.loaded["opencode.client.http"]
	local saved_sse = package.loaded["opencode.client.sse"]
	local saved_v2 = package.loaded["opencode.client.v2"]
	package.loaded["opencode.client.v2"] = nil
	package.loaded["opencode.client"] = nil
	package.loaded["opencode.client.http"] = {
		get = function(path, callback)
			if path == "/api/info" then
				callback(nil, { version = "2.0.11", pid = 1, urls = {}, paths = {} })
			elseif path == "/api/plugin" then
				callback(nil, { location = { directory = "/test" }, data = { { id = "test-plugin", source = { type = "local", path = "/test/plugin" }, state = { status = "active" } } } })
			else callback(nil, { location = { directory = "/test" }, data = {} }) end
		end,
	}

	package.loaded["opencode.client.sse"] = {
		setup = noop,
	}

	local status_client = require("opencode.client")
	local status_calls = 0
	local status_result = nil
	status_client.get_status(function(err, status)
		status_calls = status_calls + 1
		assert(err == nil, "fake status request should not error")
		status_result = status
	end)
	assert(status_calls == 1, "client.get_status should call callback exactly once with synchronous HTTP callbacks")
	assert(
		status_result and status_result.plugins and status_result.plugins[1].id == "test-plugin",
		"client.get_status should include plugins from the v2 runtime catalog"
	)

	package.loaded["opencode.client"] = saved_client
	package.loaded["opencode.client.http"] = saved_http
	package.loaded["opencode.client.sse"] = saved_sse
	package.loaded["opencode.client.v2"] = saved_v2
end

do
	local logger = require("opencode.logger")
	local app_state = require("opencode.state")
	app_state.set_config({ logs = { max_entries = 2 } })
	logger.clear()
	logger.debug("first retained test")
	logger.debug("second retained test")
	logger.debug("third retained test")
	local retained = logger.get_logs()
	assert(#retained == 2, "logger should trim old entries to configured max_entries")
	assert(retained[1].message == "second retained test", "logger should keep newest entries after trimming")
	assert(retained[2].message == "third retained test", "logger should keep latest entry after trimming")
	app_state.set_config(nil)
	logger.clear()

	local log_viewer = require("opencode.ui.log_viewer")
	logger.clear()
	logger.debug("old update", { data = { part = { messageID = "msg_log_rebuild" } } })
	logger.debug("new update", { data = { part = { messageID = "msg_log_rebuild" } } })
	log_viewer.open({ position = "bottom", height = 8 })
	local log_text = table.concat(vim.api.nvim_buf_get_lines(1, 0, -1, false), "\n")
	assert(log_text:find("new update", 1, true), "log viewer should render the latest log entry")
	assert(log_text:find("old update", 1, true), "log viewer should retain distinct log entries")
	log_viewer.close()
	logger.clear()
end

do
	local clipboard = require("opencode.clipboard")
	local tmp = vim.fn.tempname() .. ".png"
	vim.fn.writefile({ "abc" }, tmp)
	local content, err = clipboard.read_image_file(tmp, "image/png")
	assert(content ~= nil, "clipboard image file read should succeed: " .. tostring(err))
	local expected_data = vim.base64 and vim.base64.encode("abc\n") or "YWJjCg=="
	assert(content.data == expected_data, "clipboard image file should be base64 encoded")
	assert(content.mime == "image/png", "clipboard image file should preserve explicit mime")
	vim.fn.delete(tmp)
end

do
	local edit_state = require("opencode.edit.state")
	edit_state.clear_all()
	edit_state.add_edit("edit_empty", "session_empty", {}, {})
	assert(edit_state.has_pending_edits() == false, "empty edit should not count as pending")
	edit_state.add_edit("edit_file", "session_file", {
		{ filePath = "a.txt", before = "a", after = "b" },
	}, {})
	assert(edit_state.has_pending_edits() == true, "edit with pending file should count as pending")
	edit_state.clear_all()
end

local render = require("opencode.ui.chat.render")
local chat_highlights = require("opencode.ui.chat.highlights")
local binary_line = "PAR1" .. string.char(0) .. "data"
assert(render.sanitize_buffer_line(binary_line) == "PAR1<NUL>data", "NUL byte was not sanitized")
assert(render.sanitize_buffer_line("one\ntwo\r\nthree") == "one ↵ two ↵ three", "newlines were not sanitized")
local wrapped_binary = render.wrap_text_with_ranges(binary_line, 80)
assert(wrapped_binary[1].text == "PAR1<NUL>data", "binary line did not wrap as sanitized text")
local panel_result = { lines = {}, highlights = {} }
assert(
	pcall(render.add_panel_line, panel_result, binary_line, "Normal", { width = 40 }),
	"panel line render failed on binary text"
)
assert(not panel_result.lines[1]:find(string.char(0), 1, true), "panel line kept a raw NUL byte")

local function assert_no_buffer_newlines(lines, message)
	for _, line_text in ipairs(lines) do
		assert(not line_text:find("\n", 1, true), message .. " kept a raw LF")
		assert(not line_text:find("\r", 1, true), message .. " kept a raw CR")
	end
end

local chat_tasks = require("opencode.ui.chat.tasks")
local multiline_task = chat_tasks.render_task_tool({
	id = "task_newline",
	tool = "task",
	state = {
		status = "running",
		input = {
			subagent_type = "build",
			description = "Investigate\nnewline crash",
		},
		metadata = {
			summary = {
				{
					id = "1",
					tool = "bash",
					state = {
						status = "running",
						title = "Run\nchecks",
						input = {},
					},
				},
			},
		},
	},
}, false)
assert_no_buffer_newlines(multiline_task.lines, "task renderer")
assert(multiline_task.lines[1]:find("Investigate ↵ newline crash", 1, true), "task description was not sanitized")
assert(multiline_task.lines[2]:find("Run ↵ checks", 1, true), "task summary title was not sanitized")

local running_read_task = chat_tasks.render_task_tool({
	id = "task_running_read",
	tool = "task",
	state = {
		status = "running",
		input = {
			subagent_type = "build",
			description = "Inspect file",
		},
		metadata = {
			tool_calls = 3,
			summary = {
				{
					id = "1",
					tool = "read",
					state = {
						status = "running",
						title = "",
						input = { filePath = "/tmp/config.lua" },
					},
				},
			},
		},
	},
}, false)
assert(running_read_task.lines[2]:find("Read /tmp/config.lua", 1, true), "running task did not label current read")
assert(running_read_task.lines[2]:find("3 toolcalls", 1, true), "running task did not parse snake_case count")

local running_count_task = chat_tasks.render_task_tool({
	id = "task_toolcall_count",
	tool = "task",
	state = {
		status = "running",
		input = {
			subagent_type = "build",
			description = "Count tools",
		},
		metadata = {
			toolCallCount = "2",
		},
	},
}, false)
assert(running_count_task.lines[2]:find("2 toolcalls", 1, true), "running task did not parse toolCallCount")

do
	local chat_state = require("opencode.ui.chat.state").state
	local previous = {
		task_child_cache = chat_state.task_child_cache,
		task_child_loading = chat_state.task_child_loading,
		tasks = chat_state.tasks,
		bufnr = chat_state.bufnr,
	}
	local tasks = {}
	local descriptions = {
		"Map repo architecture",
		"Explore UI widgets",
		"Trace client events",
		"Inspect state model",
		"Review commands API",
	}

	chat_state.task_child_cache = {}
	chat_state.task_child_loading = {}
	chat_state.tasks = {}
	chat_state.bufnr = nil
	sync.clear_all()
	sync.handle_message_updated({
		id = "parallel_parent_msg",
		sessionID = "parallel_parent",
		role = "assistant",
		time = { created = 1 },
	})

	for i, desc in ipairs(descriptions) do
		local task_part = {
			id = "parallel_task_" .. i,
			messageID = "parallel_parent_msg",
			sessionID = "parallel_parent",
			type = "tool",
			tool = "task",
			state = {
				status = "running",
				input = {
					subagent_type = "grep_slave",
					description = desc,
				},
				metadata = i ~= 3 and { sessionID = "parallel_child_" .. i } or {},
			},
		}
		tasks[i] = task_part
		sync.handle_part_updated(task_part)
		chat_state.tasks[task_part.id] = {
			start_line = i,
			end_line = i,
			tool_part = task_part,
		}

		sync.handle_message_updated({
			id = "parallel_child_msg_" .. i,
			sessionID = "parallel_child_" .. i,
			role = "assistant",
			time = { created = 2000 + i * 1000 },
		})
		sync.handle_part_updated({
			id = "parallel_child_tool_" .. i,
			messageID = "parallel_child_msg_" .. i,
			sessionID = "parallel_child_" .. i,
			type = "tool",
			tool = "read",
			state = {
				status = "running",
				input = { filePath = "/tmp/parallel_" .. i .. ".lua" },
			},
		})
	end

	local before_metadata
	chat_tasks.resolve_task_child_session_id(tasks[3], function(err, id)
		assert(not err)
		before_metadata = id or false
	end)
	assert(before_metadata == false, "task should not guess a child from matching title or timing")
	tasks[3].state.metadata = { sessionId = "parallel_child_3" }
	sync.handle_part_updated(tasks[3])

	local seen_children = {}
	for i, task_part in ipairs(tasks) do
		local child_id
		chat_tasks.resolve_task_child_session_id(task_part, function(err, id)
			assert(not err)
			child_id = id
		end)
		assert(child_id == "parallel_child_" .. i, "parallel task mapped to the wrong child: " .. tostring(child_id))
		assert(not seen_children[child_id], "parallel child was reused across tasks: " .. tostring(child_id))
		seen_children[child_id] = true

		local rendered = chat_tasks.render_task_tool(task_part, false)
		assert(
			rendered.lines[2] and rendered.lines[2]:find("Read /tmp/parallel_" .. i .. ".lua", 1, true),
			"parallel task did not render its own child tool summary"
		)
	end

	sync.clear_all()
	for key, value in pairs(previous) do
		chat_state[key] = value
	end
end

do
	local actions_mod = require("opencode.actions")
	local chat_state = require("opencode.ui.chat.state").state
	local previous = {
		task_child_cache = chat_state.task_child_cache,
		task_child_loading = chat_state.task_child_loading,
		tasks = chat_state.tasks,
	}
	local original_load_session_messages = actions_mod.load_session_messages
	local calls = 0

	chat_state.task_child_cache = {}
	chat_state.task_child_loading = {}
	chat_state.tasks = {}
	actions_mod.load_session_messages = function(session_id, opts, callback)
		calls = calls + 1
		assert(session_id == "child_autoload", "autoload should use metadata child session id")
		assert(opts and opts.limit == 100, "autoload should request the default message limit")
		callback(nil, {})
	end

	chat_tasks.ensure_task_child_loaded({
		id = "task_autoload",
		tool = "task",
		state = {
			status = "running",
			metadata = { sessionId = "child_autoload" },
		},
	})
	assert(calls == 1, "autoload should issue one child-session load")
	assert(chat_state.task_child_loading.task_autoload == true, "autoload should mark the task as loading")
	assert(vim.wait(200, function()
		return chat_state.task_child_loading.task_autoload == nil
	end, 10), "autoload cleanup was not scheduled")
	assert(chat_state.task_child_cache.task_autoload == true, "autoload success should cache the child session")

	actions_mod.load_session_messages = original_load_session_messages
	for key, value in pairs(previous) do
		chat_state[key] = value
	end
end

do
	local chat_state_mod = require("opencode.ui.chat.state")
	local chat_state = chat_state_mod.state
	local previous = {
		bufnr = chat_state.bufnr,
		winid = chat_state.winid,
		visible = chat_state.visible,
		tasks = chat_state.tasks,
		tools = chat_state.tools,
		task_anim_frame = chat_state.task_anim_frame,
	}
	local winid = vim.api.nvim_get_current_win()
	local previous_win_buf = vim.api.nvim_win_get_buf(winid)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(winid, bufnr)

	local task_part = {
		id = "task_anim_overlay",
		tool = "task",
		state = {
			status = "running",
			input = {
				subagent_type = "webfetcher_slave",
				description = "Research vim.diff docs",
			},
			metadata = {
				summary = {
					{
						id = "1",
						tool = "webfetch",
						state = {
							status = "running",
							title = "Webfetch https://raw.githubusercontent.com/neovim/neovim/...",
							input = {},
						},
					},
				},
			},
		},
	}

	chat_state.bufnr = bufnr
	chat_state.winid = winid
	chat_state.visible = true
	chat_state.tasks = {}
	chat_state.tools = {}
	chat_state.task_anim_frame = 1

	local tool_panel = require("opencode.ui.chat.tool_panel")
	chat_state.task_anim_frame = 5
	assert(chat_tasks.get_task_anim_frame() == "⠼", "task animation is missing middle braille frames")
	chat_state.task_anim_frame = 10
	assert(chat_tasks.get_task_anim_frame() == "⠏", "task animation is missing final braille frame")
	chat_state.task_anim_frame = 6
	assert(tool_panel.anim_frame({ "|", "/", "-", "\\" }) == "/", "regular tool animation should wrap shared frame index")
	chat_state.task_anim_frame = 1

	local rendered_task = chat_tasks.render_task_tool(task_part, false)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered_task.lines)
	chat_highlights.apply_extmark_highlights(bufnr, chat_state_mod.chat_hl_ns, rendered_task.highlights, 0)
	chat_state.tasks[task_part.id] = {
		start_line = 0,
		end_line = #rendered_task.lines - 1,
		tool_part = task_part,
		highlights = rendered_task.highlights,
	}

	local before_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local before_highlights =
		vim.inspect(vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_hl_ns, 0, -1, { details = true }))
	chat_state.task_anim_frame = 2
	assert(chat_tasks.update_animation_frames_in_place() == true, "task animation overlay did not update")
	assert(
		vim.deep_equal(before_lines, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)),
		"task animation should not mutate buffer text"
	)
	assert(
		before_highlights
			== vim.inspect(vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_hl_ns, 0, -1, { details = true })),
		"task animation should not move task highlight extmarks"
	)
	assert(
		#vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_anim_ns, 0, -1, { details = true }) > 0,
		"task animation overlay extmark was not applied"
	)
	chat_tasks.clear_animation_extmarks(bufnr)

	vim.api.nvim_win_set_buf(winid, previous_win_buf)
	for key, value in pairs(previous) do
		chat_state[key] = value
	end
end

local generic_tool = render.render_tool_line({
	tool = "custom",
	state = {
		status = "running",
		input = {
			description = "Generated\nheader",
			payload = "body\nvalue",
		},
		output = "output\r\nvalue",
		error = "error\nvalue",
	},
}, true)
assert_no_buffer_newlines(generic_tool.lines, "generic tool renderer")
assert(generic_tool.lines[1]:find("Generated ↵ header", 1, true), "generic tool header was not sanitized")

local function wait_until(predicate, message)
	assert(vim.wait(500, predicate, 10), message)
end

do
	local sse = require("opencode.client.sse")
	sse.clear_listeners()
	local received = {}
	sse.on("session.text.delta", function(data, event_id)
		received[#received + 1] = { data = data, event_id = event_id }
	end)
	local native = {
		id = "evt_text_delta", created = 1000, type = "session.text.delta",
		location = { directory = vim.fn.getcwd() },
		data = { sessionID = "ses_stream", assistantMessageID = "msg_stream", ordinal = 0, delta = "hello" },
	}
	sse.emit("message", native)
	sse.emit("message", native)
	assert(#received == 1, "native event ID should deduplicate SSE replay")
	assert(received[1].event_id == "evt_text_delta", "native event ID should be forwarded")
	assert(received[1].data.delta == "hello", "native delta should be preserved")
	assert(received[1].data._v2_envelope.type == "session.text.delta", "native envelope should reach the event bridge")
	assert(received[1].data._directory == vim.fn.getcwd(), "native location should be attached")
	sse.clear_listeners()
end

do
	local bus = require("opencode.events.bus")
	local render_coordinator = require("opencode.ui.chat.render_coordinator")
	bus.clear()
	bus.clear_history()
	render_coordinator.setup(bus)

	local full_render_count = 0
	local stream_render_count = 0
	bus.on("chat_render", function()
		full_render_count = full_render_count + 1
	end)
	bus.on("chat_stream_part_updated", function()
		stream_render_count = stream_render_count + 1
	end)

	bus.emit("sync_changed", {
		kind = "part",
		action = "updated",
		session_id = "stream_route_session",
		message_id = "stream_route_message",
		part_id = "stream_route_part",
	})
	wait_until(function()
		return full_render_count == 1
	end, "part.updated snapshots should request a full chat render")
	assert(stream_render_count == 0, "part.updated snapshots should not use stream-only rendering")

	bus.emit("sync_changed", {
		kind = "part",
		action = "updated",
		session_id = "stream_route_session",
		message_id = "stream_route_message",
		part_id = "stream_route_part",
		field = "text",
		delta = "chunk",
	})
	wait_until(function()
		return stream_render_count == 1
	end, "part deltas should use stream-only rendering")
	assert(full_render_count == 1, "part deltas should not force a full render")

	bus.clear()
	render_coordinator.setup(bus)
	full_render_count = 0
	stream_render_count = 0
	bus.on("chat_render", function()
		full_render_count = full_render_count + 1
	end)
	bus.on("chat_stream_part_updated", function()
		stream_render_count = stream_render_count + 1
	end)
	bus.emit("sync_changed", {
		kind = "session",
		action = "updated",
		session_id = "rebound_session",
	})
	wait_until(function()
		return full_render_count == 1
	end, "render coordinator should rebind after bus.clear")
	assert(stream_render_count == 0, "rebound snapshot should remain a full render")

	bus.clear()
	bus.clear_history()
end

do
	local bus = require("opencode.events.bus")
	local events = require("opencode.events")
	local saved_client = package.loaded["opencode.client"]
	local sse_listeners = {}

	package.loaded["opencode.client"] = {
		on_event = function(event_type, callback)
			table.insert(sse_listeners, { event_type = event_type, callback = callback })
		end,
	}

	bus.clear()
	bus.clear_history()
	events.setup()
	local sse_listener_count = #sse_listeners
	local event_listener_count = bus.listener_count("v2_event")
	assert(sse_listener_count > 0, "initial events setup should register SSE listeners")
	assert(event_listener_count > 0, "initial events setup should register native event handlers")

	events.setup()
	assert(#sse_listeners == sse_listener_count, "repeated plugin setup should not duplicate SSE listeners")
	assert(
		bus.listener_count("v2_event") == event_listener_count,
		"repeated plugin setup should not duplicate native handlers"
	)

	bus.clear()
	events.setup()
	assert(#sse_listeners == sse_listener_count, "SSE bridge should not duplicate listeners after bus.clear")
	assert(
		bus.listener_count("v2_event") == event_listener_count,
		"native handlers should rebind after bus.clear"
	)

	package.loaded["opencode.client"] = saved_client
	bus.clear()
	bus.clear_history()
	sync.clear_all()
end

do
	local saved_client = package.loaded["opencode.client"]
	local saved_lifecycle = package.loaded["opencode.lifecycle"]
	local calls = {}
	package.loaded["opencode.client"] = {
		get_messages = function(session_id, opts, callback)
			table.insert(calls, { session_id = session_id, opts = opts })
			callback(nil, {})
		end,
	}
	package.loaded["opencode.lifecycle"] = {
		ensure_connected = function(callback)
			callback()
		end,
	}

	local actions = require("opencode.actions")
	local callbacks = 0
	actions.load_session_messages("default_limit_session", nil, function()
		callbacks = callbacks + 1
	end)
	actions.load_session_messages("explicit_limit_session", { limit = 25 }, function()
		callbacks = callbacks + 1
	end)
	wait_until(function()
		return callbacks == 2
	end, "load_session_messages callbacks should run")
	assert(calls[1].opts.limit == 100, "load_session_messages should default to limit=100")
	assert(calls[2].opts.limit == 25, "load_session_messages should honor explicit limit")

	package.loaded["opencode.client"] = saved_client
	package.loaded["opencode.lifecycle"] = saved_lifecycle
end

do
	local chat = require("opencode.ui.chat")
	local chat_state = require("opencode.ui.chat.state").state
	local render_state = require("opencode.ui.chat.render_state")
	local app_state = require("opencode.state")
	local previous_session = app_state.get_session()
	local previous_buf = vim.api.nvim_get_current_buf()
	local previous_state = {
		bufnr = chat_state.bufnr,
		winid = chat_state.winid,
		visible = chat_state.visible,
		stream_blocks = chat_state.stream_blocks,
		spinner_footer_line = chat_state.spinner_footer_line,
		auto_scroll = chat_state.auto_scroll,
	}

	local bufnr = vim.api.nvim_create_buf(false, true)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	chat_state.bufnr = bufnr
	chat_state.winid = winid
	chat_state.visible = true
	chat_state.auto_scroll = false
	chat_state.stream_blocks = {}
	app_state.set_session("stream_session", "Stream Session")
	sync.clear_all()
	local projection = require("opencode.protocol.v2.messages")
	local stream_part_id = projection.part_id("stream_session", "stream_message", "text", 0)
	sync.handle_session_messages("stream_session", { projection.project("stream_session", {
		id = "stream_message", type = "assistant", content = { { type = "text", text = "hello" } },
		time = { created = 1 },
	}) })
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello", "\\ Coder_v2 · GPT-5.5" })
	vim.bo[bufnr].modifiable = false
	vim.api.nvim_buf_set_extmark(bufnr, require("opencode.ui.chat.state").chat_hl_ns, 1, 2, {
		end_col = 10,
		hl_group = "OpenCodeAgent_coder_v2",
	})
	chat_state.spinner_footer_line = 1

	local block_key = render_state.stream_block_key("stream_session", "stream_message", stream_part_id, "text")
	chat_state.stream_blocks[block_key] = {
		start_line = 0,
		end_line = 0,
		session_id = "stream_session",
		message_id = "stream_message",
		part_id = stream_part_id,
		kind = "text",
	}
	sync.handle_v2_event({ id = "evt_stream_world", created = 2, type = "session.text.delta",
		data = { sessionID = "stream_session", assistantMessageID = "stream_message", ordinal = 0, delta = " world" } })
	assert(
		chat.update_stream_part_block("stream_session", "stream_message", stream_part_id),
		"same-line stream delta should update in place"
	)
	assert(
		vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "hello world",
		"same-line stream delta did not append visibly"
	)
	assert(chat_state.stream_blocks[block_key].end_line == 0, "same-line stream delta should not grow block")

	sync.handle_v2_event({ id = "evt_stream_next", created = 3, type = "session.text.delta",
		data = { sessionID = "stream_session", assistantMessageID = "stream_message", ordinal = 0, delta = "\nnext" } })
	assert(
		chat.update_stream_part_block("stream_session", "stream_message", stream_part_id),
		"newline stream delta should replace the rendered block"
	)
	local updated_stream_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert(#updated_stream_lines == 3, "newline stream delta should grow rendered block without losing footer")
	assert(updated_stream_lines[1] == "hello world", "newline fallback should preserve first line")
	assert(updated_stream_lines[2] == "next", "newline fallback should render next line")
	assert(updated_stream_lines[3]:find("Coder_v2", 1, true), "stream growth should preserve footer text")
	assert(chat_state.spinner_footer_line == 2, "stream growth should shift tracked footer line")
	local footer_marks = vim.api.nvim_buf_get_extmarks(
		bufnr,
		require("opencode.ui.chat.state").chat_hl_ns,
		{ 2, 0 },
		{ 2, -1 },
		{ details = true }
	)
	assert(#footer_marks == 1, "stream growth should preserve footer agent highlight")
	assert(footer_marks[1][4].hl_group == "OpenCodeAgent_coder_v2", "wrong footer highlight after stream growth")

	sync.handle_v2_event({ id = "evt_stream_end", created = 4, type = "session.text.ended",
		data = { sessionID = "stream_session", assistantMessageID = "stream_message", ordinal = 0, text = "short" } })
	assert(
		chat.update_stream_part_block("stream_session", "stream_message", stream_part_id),
		"stream replacement should shrink rendered block"
	)
	updated_stream_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert(
		#updated_stream_lines == 2,
		"stream shrink should keep footer immediately after content: " .. vim.inspect(updated_stream_lines)
	)
	assert(updated_stream_lines[1] == "short", "stream shrink should render replacement text")
	assert(updated_stream_lines[2]:find("Coder_v2", 1, true), "stream shrink should preserve footer text")
	assert(chat_state.spinner_footer_line == 1, "stream shrink should shift tracked footer line back")
	footer_marks = vim.api.nvim_buf_get_extmarks(
		bufnr,
		require("opencode.ui.chat.state").chat_hl_ns,
		{ 1, 0 },
		{ 1, -1 },
		{ details = true }
	)
	assert(#footer_marks == 1, "stream shrink should preserve footer agent highlight")

	sync.clear_all()
	chat_state.bufnr = previous_state.bufnr
	chat_state.winid = previous_state.winid
	chat_state.visible = previous_state.visible
	chat_state.stream_blocks = previous_state.stream_blocks
	chat_state.spinner_footer_line = previous_state.spinner_footer_line
	chat_state.auto_scroll = previous_state.auto_scroll
	if previous_session and previous_session.id then
		app_state.set_session(previous_session.id, previous_session.name, {
			runtime = previous_session.runtime,
		})
	else
		app_state.set_session(nil, nil)
	end
	if vim.api.nvim_buf_is_valid(previous_buf) then
		vim.api.nvim_win_set_buf(winid, previous_buf)
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end
end

do
	local chat = require("opencode.ui.chat")
	local chat_state = require("opencode.ui.chat.state").state
	local render_state = require("opencode.ui.chat.render_state")
	local app_state = require("opencode.state")
	local question_state = require("opencode.question.state")
	local permission_state = require("opencode.permission.state")
	local edit_state = require("opencode.edit.state")

	local previous_buf = vim.api.nvim_get_current_buf()
	local previous_session = app_state.get_session()
	local previous_view = {
		bufnr = chat_state.bufnr,
		winid = chat_state.winid,
		visible = chat_state.visible,
		config = chat_state.config,
		local_notices = chat_state.local_notices,
		session_stack = chat_state.session_stack,
		auto_scroll = chat_state.auto_scroll,
		stream_blocks = chat_state.stream_blocks,
		spinner_footer_line = chat_state.spinner_footer_line,
		questions = chat_state.questions,
		permissions = chat_state.permissions,
		edits = chat_state.edits,
		tasks = chat_state.tasks,
		tools = chat_state.tools,
	}

	local bufnr = vim.api.nvim_create_buf(false, true)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	chat_state.bufnr = bufnr
	chat_state.winid = winid
	chat_state.visible = true
	chat_state.config = {
		max_rendered_messages = 2,
		max_user_message_lines = 120,
		session_tabs = { enabled = false },
	}
	chat_state.local_notices = {
		{
			role = "user",
			content = "recent echoed local",
			timestamp = 4,
			session_id = "render_contract_session",
			id = "local_echo",
		},
	}
	chat_state.session_stack = {}
	chat_state.auto_scroll = false
	chat_state.stream_blocks = {}
	chat_state.spinner_footer_line = nil
	chat_state.questions = {}
	chat_state.permissions = {}
	chat_state.edits = {}
	chat_state.tasks = {}
	chat_state.tools = {}

	sync.clear_all()
	question_state.clear_all()
	permission_state.clear_all()
	edit_state.clear_all()
	app_state.set_session("render_contract_session", "Render Contract")
	app_state.set_session_status("render_contract_session", { type = "streaming" })

	sync.handle_message_updated({
		id = "m1",
		sessionID = "render_contract_session",
		role = "user",
		time = { created = 1000 },
	})
	sync.handle_part_updated({
		id = "m1_text",
		messageID = "m1",
		sessionID = "render_contract_session",
		type = "text",
		text = "older user anchored",
	})
	sync.handle_message_updated({
		id = "m2",
		sessionID = "render_contract_session",
		role = "assistant",
		time = { created = 2000, completed = 2500 },
	})
	sync.handle_part_updated({
		id = "m2_text",
		messageID = "m2",
		sessionID = "render_contract_session",
		type = "text",
		text = "older assistant",
	})
	sync.handle_message_updated({
		id = "m3",
		sessionID = "render_contract_session",
		role = "user",
		time = { created = 4000 },
	})
	sync.handle_part_updated({
		id = "m3_text",
		messageID = "m3",
		sessionID = "render_contract_session",
		type = "text",
		text = "recent echoed local",
	})
	sync.handle_message_updated({
		id = "m4",
		sessionID = "render_contract_session",
		role = "assistant",
		time = { created = 5000 },
	})
	sync.handle_part_updated({
		id = "m4_text",
		messageID = "m4",
		sessionID = "render_contract_session",
		type = "text",
		text = "streaming answer",
	})
	sync.handle_part_updated({
		id = "m4_question_tool",
		messageID = "m4",
		sessionID = "render_contract_session",
		type = "tool",
		tool = "question",
		callID = "call_question",
		state = { status = "pending", input = {} },
	})
	sync.handle_part_updated({
		id = "m4_edit_tool",
		messageID = "m4",
		sessionID = "render_contract_session",
		type = "tool",
		tool = "edit",
		callID = "call_edit",
		state = { status = "pending", input = {} },
	})
	sync.handle_part_updated({
		id = "m4_patch_tool",
		messageID = "m4",
		sessionID = "render_contract_session",
		type = "tool",
		tool = "apply_patch",
		callID = "call_patch",
		state = {
			status = "completed",
			metadata = {
				status = "success",
				files = {
					{
						filePath = "render-patch.txt",
						type = "update",
						diff = table.concat({
							"--- a/render-patch.txt",
							"+++ b/render-patch.txt",
							"@@ -1 +1 @@",
							"-old line",
							"+new line",
						}, "\n"),
					},
				},
			},
		},
	})
	sync.handle_part_updated({
		id = "m4_neovim_edit_tool",
		messageID = "m4",
		sessionID = "render_contract_session",
		type = "tool",
		tool = "neovim_edit",
		callID = "call_neovim_edit",
		state = {
			status = "completed",
			metadata = {
				status = "success",
				filediff = {
					file = "render-neovim-edit.txt",
					status = "applied",
					diff = table.concat({
						"--- a/render-neovim-edit.txt",
						"+++ b/render-neovim-edit.txt",
						"@@ -1 +1 @@",
						"-old neovim edit",
						"+new neovim edit",
					}, "\n"),
				},
			},
		},
	})
	sync.handle_part_updated({
		id = "m4_neovim_patch_tool",
		messageID = "m4",
		sessionID = "render_contract_session",
		type = "tool",
		tool = "neovim_patch",
		callID = "call_neovim_patch",
		state = {
			status = "completed",
			metadata = {
				status = "success",
				files = {
					{
						filePath = "render-neovim-patch.txt",
						type = "update",
						status = "applied",
						diff = table.concat({
							"--- a/render-neovim-patch.txt",
							"+++ b/render-neovim-patch.txt",
							"@@ -1 +1 @@",
							"-old neovim patch",
							"+new neovim patch",
						}, "\n"),
					},
				},
			},
		},
	})

	question_state.add_form({ id = "q_anchor", sessionID = "render_contract_session",
		fields = { { key = "anchor", type = "string", title = "Anchor?", options = { { label = "Yes", value = "yes" } } } },
		metadata = { tool = { messageID = "m1" } },
	}, { timestamp = 1 })
	question_state.add_form({ id = "q_tool", sessionID = "render_contract_session",
		fields = { { key = "tool", type = "string", title = "Tool question?", options = { { label = "Yes", value = "yes" } } } },
		metadata = { tool = { messageID = "m4", id = "call_question" } },
	}, { timestamp = 5 })
	permission_state.add_permission("perm_orphan", "render_contract_session", "bash", {
		timestamp = 6,
		tool_input = { command = "pwd" },
	})
	edit_state.add_edit("edit_tool", "render_contract_session", {
		{ filePath = "render-contract.txt", before = "a", after = "b" },
	}, {
		message_id = "m4",
		call_id = "call_edit",
		timestamp = 7,
		review_mode = "readonly",
	})

	local raw_lines = chat.render()
	local rendered = table.concat(raw_lines, "\n")
	local echo_count = 0
	for _ in rendered:gmatch("recent echoed local") do
		echo_count = echo_count + 1
	end

	assert(rendered:find("older user anchored", 1, true), "pending widget should anchor a message before cutoff")
	assert(echo_count == 1, "local user notice should not duplicate a server echo")
	assert(chat_state.questions.q_tool, "tool-call question should be tracked")
	assert(chat_state.permissions.perm_orphan, "orphan permission should be tracked")
	assert(chat_state.edits.edit_tool, "tool-call edit should be tracked")
	local preview_edit_id = "tool-preview:render_contract_session:m4:m4_patch_tool"
	local preview_edit = edit_state.get_edit(preview_edit_id)
	assert(preview_edit and preview_edit.preview == true, "completed apply_patch should create preview edit state")
	assert(preview_edit.status == "sent", "completed apply_patch preview should not be pending")
	assert(chat_state.edits[preview_edit_id], "completed apply_patch preview should be tracked")
	local neovim_edit_preview_id = "tool-preview:render_contract_session:m4:m4_neovim_edit_tool"
	local neovim_edit_preview = edit_state.get_edit(neovim_edit_preview_id)
	assert(neovim_edit_preview and neovim_edit_preview.preview == true, "approved neovim_edit should create preview edit state")
	assert(chat_state.edits[neovim_edit_preview_id], "approved neovim_edit preview should be tracked")
	local neovim_patch_preview_id = "tool-preview:render_contract_session:m4:m4_neovim_patch_tool"
	local neovim_patch_preview = edit_state.get_edit(neovim_patch_preview_id)
	assert(
		neovim_patch_preview and neovim_patch_preview.preview == true,
		"approved neovim_patch should create preview edit state"
	)
	assert(chat_state.edits[neovim_patch_preview_id], "approved neovim_patch preview should be tracked")
	assert(chat_state.tools.m4_question_tool == nil, "question tool row should be suppressed by widget")
	assert(chat_state.tools.m4_edit_tool == nil, "edit tool row should be suppressed by widget")
	assert(chat_state.tools.m4_patch_tool == nil, "apply_patch tool row should be suppressed by preview widget")
	assert(chat_state.tools.m4_neovim_edit_tool == nil, "neovim_edit tool row should be suppressed by preview widget")
	assert(chat_state.tools.m4_neovim_patch_tool == nil, "neovim_patch tool row should be suppressed by preview widget")

	edit_state.toggle_inline_diff(preview_edit_id, 1)
	local preview_lines = require("opencode.ui.edit_widget").get_resolved_lines(preview_edit_id, preview_edit)
	local preview_text = table.concat(preview_lines, "\n")
	assert(preview_text:find("old line", 1, true), "apply_patch preview should expand removed diff text")
	assert(preview_text:find("new line", 1, true), "apply_patch preview should expand added diff text")
	edit_state.toggle_inline_diff(neovim_edit_preview_id, 1)
	local neovim_edit_lines =
		require("opencode.ui.edit_widget").get_resolved_lines(neovim_edit_preview_id, neovim_edit_preview)
	local neovim_edit_text = table.concat(neovim_edit_lines, "\n")
	assert(neovim_edit_text:find("old neovim edit", 1, true), "neovim_edit preview should expand removed diff text")
	assert(neovim_edit_text:find("new neovim edit", 1, true), "neovim_edit preview should expand added diff text")
	edit_state.toggle_inline_diff(neovim_patch_preview_id, 1)
	local neovim_patch_lines =
		require("opencode.ui.edit_widget").get_resolved_lines(neovim_patch_preview_id, neovim_patch_preview)
	local neovim_patch_text = table.concat(neovim_patch_lines, "\n")
	assert(
		neovim_patch_text:find("old neovim patch", 1, true),
		"neovim_patch preview should expand removed diff text"
	)
	assert(
		neovim_patch_text:find("new neovim patch", 1, true),
		"neovim_patch preview should expand added diff text"
	)

	local block_key = render_state.stream_block_key("render_contract_session", "m4", "m4_text", "text")
	assert(chat_state.stream_blocks[block_key], "full render should register streaming text block")
	assert(chat_state.spinner_footer_line == nil, "pending interaction should not register an animated footer line")
	assert(rendered:find("▣ ", 1, true), "pending interaction should retain a static processing footer")

	sync.clear_all()
	question_state.clear_all()
	permission_state.clear_all()
	edit_state.clear_all()
	app_state.remove_session("render_contract_session")
	if previous_session and previous_session.id then
		app_state.set_session(previous_session.id, previous_session.name, {
			runtime = previous_session.runtime,
		})
	else
		app_state.set_session(nil, nil)
	end
	chat_state.bufnr = previous_view.bufnr
	chat_state.winid = previous_view.winid
	chat_state.visible = previous_view.visible
	chat_state.config = previous_view.config
	chat_state.local_notices = previous_view.local_notices
	chat_state.session_stack = previous_view.session_stack
	chat_state.auto_scroll = previous_view.auto_scroll
	chat_state.stream_blocks = previous_view.stream_blocks
	chat_state.spinner_footer_line = previous_view.spinner_footer_line
	chat_state.questions = previous_view.questions
	chat_state.permissions = previous_view.permissions
	chat_state.edits = previous_view.edits
	chat_state.tasks = previous_view.tasks
	chat_state.tools = previous_view.tools
	if vim.api.nvim_buf_is_valid(previous_buf) then
		vim.api.nvim_win_set_buf(winid, previous_buf)
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end
end

do
	local edit_state = require("opencode.edit.state")
	local edit_widget = require("opencode.ui.edit_widget")
	local edit_previews = require("opencode.ui.chat.edit_previews")

	sync.clear_all()
	edit_state.clear_all()

	-- Empty-string compute: a `write` with before="" / after="content" and
	-- no diff should compute a non-empty vim.diff so add/delete previews work.
	local compute_session = "compute_session"
	sync.handle_message_updated({
		id = "m_compute",
		sessionID = compute_session,
		role = "assistant",
		time = { created = 1000, completed = 1500 },
	})
	sync.handle_part_updated({
		id = "m_write_compute",
		messageID = "m_compute",
		sessionID = compute_session,
		type = "tool",
		tool = "write",
		callID = "call_write_compute",
		state = {
			status = "completed",
			metadata = {
				status = "success",
				filepath = "compute-write.txt",
				filediff = {
					file = "compute-write.txt",
					before = "",
					after = "content line",
				},
			},
		},
	})

	local created = edit_previews.sync_session(compute_session)
	assert(created == 1, "empty-string before/after should create a preview edit via computed diff")
	local compute_id = "tool-preview:" .. compute_session .. ":m_compute:m_write_compute"
	local compute_estate = edit_state.get_edit(compute_id)
	assert(compute_estate, "empty-string compute path should create an edit estate")
	assert(#compute_estate.files == 1, "compute estate should have one file")
	local cfile = compute_estate.files[1]
	assert(#cfile.diff_lines > 0, "empty-string before/after should compute a non-empty diff")
	assert(cfile.stats.added > 0, "computed diff should report non-zero additions")
	assert(cfile.before == "", "compute estate should preserve empty before content")
	assert(cfile.after == "content line", "compute estate should preserve after content")

	edit_state.toggle_inline_diff(compute_id, 1)
	local compute_lines = edit_widget.get_resolved_lines(compute_id, compute_estate)
	local compute_text = table.concat(compute_lines, "\n")
	assert(compute_text:find("content line", 1, true), "computed diff widget should expand added content")

	sync.clear_all()
	edit_state.clear_all()
end

do
	local chat = require("opencode.ui.chat")
	local chat_state = require("opencode.ui.chat.state").state
	local app_state = require("opencode.state")
	local edit_state = require("opencode.edit.state")
	local permission_state = require("opencode.permission.state")

	local previous_buf = vim.api.nvim_get_current_buf()
	local previous_session = app_state.get_session()
	local previous_view = {
		bufnr = chat_state.bufnr,
		winid = chat_state.winid,
		visible = chat_state.visible,
		config = chat_state.config,
		local_notices = chat_state.local_notices,
		session_stack = chat_state.session_stack,
		auto_scroll = chat_state.auto_scroll,
		stream_blocks = chat_state.stream_blocks,
		spinner_footer_line = chat_state.spinner_footer_line,
		questions = chat_state.questions,
		permissions = chat_state.permissions,
		edits = chat_state.edits,
		tasks = chat_state.tasks,
		tools = chat_state.tools,
	}

	local bufnr = vim.api.nvim_create_buf(false, true)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	chat_state.bufnr = bufnr
	chat_state.winid = winid
	chat_state.visible = true
	chat_state.config = {
		max_rendered_messages = 20,
		session_tabs = { enabled = false },
	}
	chat_state.local_notices = {}
	chat_state.session_stack = {}
	chat_state.auto_scroll = false
	chat_state.stream_blocks = {}
	chat_state.spinner_footer_line = nil
	chat_state.questions = {}
	chat_state.permissions = {}
	chat_state.edits = {}
	chat_state.tasks = {}
	chat_state.tools = {}

	sync.clear_all()
	edit_state.clear_all()
	permission_state.clear_all()
	app_state.set_session("orphan_resolved_session", "Orphan Resolved")

	edit_state.add_edit("edit_orphan_resolved", "orphan_resolved_session", {
		{ filePath = "orphan-resolved.txt", before = "a", after = "b" },
	}, {
		timestamp = 1,
		review_mode = "readonly",
		file_statuses = { "accepted" },
	})
	edit_state.add_edit("edit_orphan_pending", "orphan_resolved_session", {
		{ filePath = "orphan-pending.txt", before = "a", after = "b" },
	}, {
		timestamp = 2,
		review_mode = "readonly",
	})

	permission_state.add_permission("perm_orphan_resolved", "orphan_resolved_session", "bash", {
		timestamp = 3,
		tool_input = { command = "echo resolved" },
	})
	permission_state.mark_approved("perm_orphan_resolved", "once")
	permission_state.add_permission("perm_orphan_pending", "orphan_resolved_session", "bash", {
		timestamp = 4,
		tool_input = { command = "echo pending" },
	})

	chat.render()
	assert(
		chat_state.edits.edit_orphan_resolved == nil,
		"resolved orphan edit owned by current session should not render at the orphan tail"
	)
	assert(
		chat_state.edits.edit_orphan_pending,
		"pending orphan edit owned by current session should render at the orphan tail"
	)
	assert(
		chat_state.permissions.perm_orphan_resolved == nil,
		"resolved orphan permission owned by current session should not render at the orphan tail"
	)
	assert(
		chat_state.permissions.perm_orphan_pending,
		"pending orphan permission owned by current session should render at the orphan tail"
	)

	sync.clear_all()
	edit_state.clear_all()
	permission_state.clear_all()
	app_state.remove_session("orphan_resolved_session")
	if previous_session and previous_session.id then
		app_state.set_session(previous_session.id, previous_session.name, {
			runtime = previous_session.runtime,
		})
	else
		app_state.set_session(nil, nil)
	end
	chat_state.bufnr = previous_view.bufnr
	chat_state.winid = previous_view.winid
	chat_state.visible = previous_view.visible
	chat_state.config = previous_view.config
	chat_state.local_notices = previous_view.local_notices
	chat_state.session_stack = previous_view.session_stack
	chat_state.auto_scroll = previous_view.auto_scroll
	chat_state.stream_blocks = previous_view.stream_blocks
	chat_state.spinner_footer_line = previous_view.spinner_footer_line
	chat_state.questions = previous_view.questions
	chat_state.permissions = previous_view.permissions
	chat_state.edits = previous_view.edits
	chat_state.tasks = previous_view.tasks
	chat_state.tools = previous_view.tools
	if vim.api.nvim_buf_is_valid(previous_buf) then
		vim.api.nvim_win_set_buf(winid, previous_buf)
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end
end

do
	local chat = require("opencode.ui.chat")
	local chat_state = require("opencode.ui.chat.state").state
	local app_state = require("opencode.state")
	local question_state = require("opencode.question.state")

	local previous_buf = vim.api.nvim_get_current_buf()
	local previous_session = app_state.get_session()
	local previous_view = {
		bufnr = chat_state.bufnr,
		winid = chat_state.winid,
		visible = chat_state.visible,
		config = chat_state.config,
		local_notices = chat_state.local_notices,
		session_stack = chat_state.session_stack,
		auto_scroll = chat_state.auto_scroll,
		stream_blocks = chat_state.stream_blocks,
		spinner_footer_line = chat_state.spinner_footer_line,
		questions = chat_state.questions,
		permissions = chat_state.permissions,
		edits = chat_state.edits,
		tasks = chat_state.tasks,
		tools = chat_state.tools,
	}

	local bufnr = vim.api.nvim_create_buf(false, true)
	local winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	chat_state.bufnr = bufnr
	chat_state.winid = winid
	chat_state.visible = true
	chat_state.config = {
		max_rendered_messages = 20,
		session_tabs = { enabled = false },
	}
	chat_state.local_notices = {}
	chat_state.session_stack = {}
	chat_state.auto_scroll = false
	chat_state.stream_blocks = {}
	chat_state.spinner_footer_line = nil
	chat_state.questions = {}
	chat_state.permissions = {}
	chat_state.edits = {}
	chat_state.tasks = {}
	chat_state.tools = {}

	sync.clear_all()
	question_state.clear_all()
	app_state.set_session("orphan_question_session", "Orphan Question")

	local function add_orphan_form(id, label, timestamp)
		question_state.add_form({ id = id, sessionID = "orphan_question_session",
			fields = { { key = "choice", type = "string", title = "Pick", description = "Choose one",
				options = { { label = label, value = label:lower() } } } },
			metadata = { tool = { messageID = "msg_orphan_question" } },
		}, { timestamp = timestamp })
	end
	add_orphan_form("q_orphan_pending", "A", 1)
	add_orphan_form("q_orphan_confirming", "B", 2)
	question_state.set_confirming("q_orphan_confirming")
	add_orphan_form("q_orphan_answered", "C", 3)
	question_state.mark_answered("q_orphan_answered")
	add_orphan_form("q_orphan_rejected", "D", 4)
	question_state.mark_rejected("q_orphan_rejected")

	chat.render()
	assert(
		chat_state.questions.q_orphan_pending,
		"pending orphan question owned by current session should render at the orphan tail"
	)
	assert(
		chat_state.questions.q_orphan_confirming,
		"confirming orphan question owned by current session should render at the orphan tail"
	)
	assert(
		chat_state.questions.q_orphan_answered == nil,
		"answered orphan question owned by current session should not render at the orphan tail"
	)
	assert(
		chat_state.questions.q_orphan_rejected == nil,
		"rejected orphan question owned by current session should not render at the orphan tail"
	)

	sync.clear_all()
	question_state.clear_all()
	app_state.remove_session("orphan_question_session")
	if previous_session and previous_session.id then
		app_state.set_session(previous_session.id, previous_session.name, {
			runtime = previous_session.runtime,
		})
	else
		app_state.set_session(nil, nil)
	end
	chat_state.bufnr = previous_view.bufnr
	chat_state.winid = previous_view.winid
	chat_state.visible = previous_view.visible
	chat_state.config = previous_view.config
	chat_state.local_notices = previous_view.local_notices
	chat_state.session_stack = previous_view.session_stack
	chat_state.auto_scroll = previous_view.auto_scroll
	chat_state.stream_blocks = previous_view.stream_blocks
	chat_state.spinner_footer_line = previous_view.spinner_footer_line
	chat_state.questions = previous_view.questions
	chat_state.permissions = previous_view.permissions
	chat_state.edits = previous_view.edits
	chat_state.tasks = previous_view.tasks
	chat_state.tools = previous_view.tools
	if vim.api.nvim_buf_is_valid(previous_buf) then
		vim.api.nvim_win_set_buf(winid, previous_buf)
	end
	if vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end
end

do
	local panel = require("opencode.ui.panel")
	local helpers = panel.create_helpers({
		prefix = "| ",
		blank_prefix = "|",
		border_hl = "PanelBorderTest",
		default_hl = "PanelDefaultTest",
	})
	local result = { lines = {}, highlights = {} }
	local _, _, wrapped_rows = helpers.add_line(result, "wrapped words for panel factory", nil, { width = 14 })
	assert(#wrapped_rows > 1, "panel factory add_line should preserve wrapping")
	for _, row in ipairs(wrapped_rows) do
		assert(row.line:sub(1, 2) == "| ", "panel factory wrapped rows should keep prefix")
	end
	local _, _, raw_rows = helpers.add_raw_line(result, "raw words stay together", "PanelRawTest", {
		width = 14,
		wrap = false,
	})
	assert(#raw_rows == 1, "panel factory raw lines should preserve wrap=false")
	helpers.add_blank(result)
	assert(result.lines[#result.lines]:sub(1, 1) == "|", "panel factory blank line should keep blank prefix")
	helpers.add_separator(result)
	assert(result.lines[#result.lines] == "", "panel factory separator should append a trailing blank line")
	helpers.highlight_text(result, wrapped_rows, "wrapped", "PanelWrappedTextTest")
	local saw_text_highlight = false
	local saw_prefix_highlight = false
	for _, hl in ipairs(result.highlights) do
		saw_text_highlight = saw_text_highlight or hl.hl_group == "PanelWrappedTextTest"
		saw_prefix_highlight = saw_prefix_highlight or hl.hl_group == "PanelBorderTest"
	end
	assert(saw_text_highlight, "panel factory highlight_text should add text highlights")
	assert(saw_prefix_highlight, "panel factory should preserve border prefix highlights")

	local bash = require("opencode.ui.chat.bash")
	local read = require("opencode.ui.chat.read")
	local skill = require("opencode.ui.chat.skill")

	local bash_result = bash.render_tool({
		tool = "bash",
		input = { command = "echo stale" },
		output = "stale",
		state = {
			status = "completed",
			input = { command = "echo hi" },
			output = "hi",
		},
	}, false)
	assert(bash_result and table.concat(bash_result.lines, "\n"):find("Shell", 1, true), "bash widget should render")
	assert(not render_text(bash_result):find("stale", 1, true), "bash widget should only use canonical state fields")

	local bash_error = bash.render_tool({
		tool = "bash",
		state = {
			status = "error",
			input = { command = "false" },
			error = "boom",
		},
	}, false)
	assert(render_text(bash_error):find("boom", 1, true), "bash widget should render canonical state.error")

	local read_output = {}
	for i = 1, 12 do
		table.insert(read_output, tostring(i) .. ": local value_" .. tostring(i) .. " = " .. tostring(i))
	end
	local read_collapsed = read.render_tool({
		tool = "read",
		state = {
			status = "completed",
			input = { path = "lua/opencode/init.lua" },
			output = table.concat(read_output, "\n"),
		},
	}, false)
	local read_expanded = read.render_tool({
		tool = "read",
		state = {
			status = "completed",
			input = { path = "lua/opencode/init.lua" },
			output = table.concat(read_output, "\n"),
		},
	}, true)
	assert(render_text(read_collapsed):find("Read lua/opencode/init.lua", 1, true), "read widget should render native state.input.path")
	assert(render_text(read_collapsed):find("more lines", 1, true), "read widget should show collapsed overflow")
	assert(not render_text(read_expanded):find("more lines", 1, true), "read widget should hide overflow when expanded")

	local glob_result = search.render_tool({
		tool = "glob",
		state = {
			status = "completed",
			input = { pattern = "*.lua", path = "lua/opencode" },
			output = "lua/opencode/init.lua",
		},
		metadata = { count = 1 },
	}, false)
	assert(render_text(glob_result):find("Glob", 1, true), "glob widget should render")

	local rg_result = rg.render_tool({
		tool = "rg",
		state = {
			status = "completed",
			input = { pattern = "local", path = "lua", type = "lua", column = true },
			output = "lua/opencode/init.lua:12:3:local M = {}",
		},
	}, false)
	assert(rg_result and table.concat(rg_result.lines, "\n"):find("∴ rg", 1, true), "rg widget should render")

	local rg_lines = {}
	for i = 1, 11 do
		table.insert(rg_lines, "lua/opencode/init.lua:" .. tostring(i) .. ":local value_" .. tostring(i))
	end
	local rg_collapsed = rg.render_tool({
		tool = "rg",
		state = {
			status = "completed",
			input = { pattern = "value", path = "lua" },
			output = table.concat(rg_lines, "\n"),
		},
		metadata = { matches = 11 },
	}, false)
	local rg_expanded = rg.render_tool({
		tool = "rg",
		state = {
			status = "completed",
			input = { pattern = "value", path = "lua" },
			output = table.concat(rg_lines, "\n"),
		},
		metadata = { matches = 11 },
	}, true)
	assert(not render_text(rg_collapsed):find("value_1", 1, true), "collapsed rg widget should hide successful output")
	assert(render_text(rg_expanded):find("value_1", 1, true), "expanded rg widget should show output")

	local skill_result = skill.render_tool({
		tool = "skill",
		state = {
			status = "completed",
			input = { name = "opencode-nvim-widgets" },
			output = "# Skill: opencode-nvim-widgets\n\nRender widgets cleanly.",
		},
	}, false)
	assert(render_text(skill_result):find('Skill "opencode-nvim-widgets"', 1, true), "skill widget should render")

	local question_lines = require("opencode.ui.question_widget").get_lines_for_question("question_panel_test", {
		{ header = "Pick", question = "Choose one", options = { { label = "A", value = "a" } } },
	}, {
		current_tab = 1,
		selections = { { selected_indices = { 1 } } },
	}, "pending")
	assert(table.concat(question_lines, "\n"):find("Pick", 1, true), "question widget should render")

	local permission_state = require("opencode.permission.state")
	permission_state.clear_all()
	local perm = permission_state.add_permission("permission_panel_test", "session_panel_test", "bash", {
		tool_input = { command = "echo hi" },
	})
	local permission_lines = require("opencode.ui.permission_widget").get_lines_for_permission(
		"permission_panel_test",
		perm
	)
	assert(table.concat(permission_lines, "\n"):find("Permission", 1, true), "permission widget should render")

	local edit_state_for_panel = require("opencode.edit.state")
	local changes_for_panel = require("opencode.artifact.changes")
	edit_state_for_panel.clear_all()
	changes_for_panel.clear()
	local tmp = vim.fn.tempname()
	vim.fn.writefile({ "before" }, tmp)
	local edit = edit_state_for_panel.add_edit("edit_panel_test", "session_panel_test", {
		{ filePath = tmp, before = "before\n", after = "after\n" },
	}, {})
	local edit_lines = require("opencode.ui.edit_widget").get_lines_for_edit("edit_panel_test", edit)
	assert(table.concat(edit_lines, "\n"):find(vim.fn.fnamemodify(tmp, ":t"), 1, true), "edit widget should render")
	vim.fn.delete(tmp)
	edit_state_for_panel.clear_all()
	changes_for_panel.clear()
end

do
	local schedule = require("opencode.util.schedule")
	local received
	schedule.schedule_callback(function(a, b, c)
		received = { a = a, b = b, c = c, n = select("#", a, b, c) }
	end, "one", nil, "three")
	wait_until(function()
		return received ~= nil
	end, "scheduled callback should run")
	assert(received.a == "one", "scheduled callback should receive first argument")
	assert(received.b == nil, "scheduled callback should preserve nil middle argument")
	assert(received.c == "three", "scheduled callback should receive trailing argument")
	assert(received.n == 3, "scheduled callback should receive all arguments")

	local original_notify = vim.notify
	local notifications = {}
	vim.notify = function(message, level)
		table.insert(notifications, { message = tostring(message), level = level })
	end
	schedule.schedule_pcall("schedule test label", function()
		error("schedule boom")
	end)
	wait_until(function()
		return #notifications > 0
	end, "scheduled callback errors should be reported")
	assert(
		notifications[1].message:find("schedule test label", 1, true) ~= nil,
		"scheduled callback error should include label"
	)
	vim.notify = original_notify
end

do
	local chat_edits = require("opencode.ui.chat.edits")
	local chat_state = require("opencode.ui.chat.state").state
	local edit_state = require("opencode.edit.state")
	local changes = require("opencode.artifact.changes")
	local original_finalize = chat_edits.finalize_edit
	local original_rerender = chat_edits.rerender_edit
	local original_refresh = chat_edits.refresh_edit
	local original_winid = chat_state.winid
	local original_bufnr = chat_state.bufnr
	local original_edits = chat_state.edits
	local winid = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_get_current_buf()
	local calls = { finalize = 0, rerender = 0 }

	local function reset_calls()
		calls.finalize = 0
		calls.rerender = 0
		calls.last_finalized = nil
		calls.last_rerendered = nil
	end

	chat_edits.finalize_edit = function(edit_id)
		calls.finalize = calls.finalize + 1
		calls.last_finalized = edit_id
	end
	chat_edits.rerender_edit = function(edit_id)
		calls.rerender = calls.rerender + 1
		calls.last_rerendered = edit_id
	end

	local function make_edit(edit_id, file_count, opts)
		edit_state.clear_all()
		opts = opts or {}
		changes.clear()
		local files = {}
		local paths = {}
		for index = 1, file_count do
			local path = vim.fn.tempname()
			local before = "before " .. tostring(index) .. "\n"
			local after = "after " .. tostring(index) .. "\n"
			-- writefile appends a newline per list item, so drop the trailing
			-- empty split element to keep disk bytes equal to the snapshot.
			local disk_lines = vim.split(opts.disk == "after" and after or before, "\n", { plain = true })
			if disk_lines[#disk_lines] == "" then
				table.remove(disk_lines)
			end
			vim.fn.writefile(disk_lines, path)
			table.insert(paths, path)
			table.insert(files, {
				filePath = path,
				before = before,
				after = after,
			})
		end
		edit_state.add_edit(edit_id, "session_edit_lifecycle", files, opts)
		local ranges = {}
		for index = 1, file_count do
			table.insert(ranges, {
				index = index,
				start_line = index - 1,
				end_line = index - 1,
			})
		end
		chat_state.winid = winid
		chat_state.bufnr = bufnr
		chat_state.edits = {
			[edit_id] = {
				start_line = 0,
				end_line = math.max(0, file_count - 1),
				status = "pending",
				meta = { file_ranges = ranges },
			},
		}
		local was_modifiable = vim.bo[bufnr].modifiable
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four" })
		vim.bo[bufnr].modifiable = was_modifiable
		vim.api.nvim_win_set_cursor(winid, { 1, 0 })
		return paths
	end

	local function select_file(edit_id, index)
		edit_state.move_selection_to(edit_id, index)
		vim.api.nvim_win_set_cursor(winid, { index, 0 })
	end

	local function cleanup(paths)
		for _, path in ipairs(paths or {}) do
			vim.fn.delete(path)
		end
		edit_state.clear_all()
		changes.clear()
		chat_state.edits = {}
	end

	local function run_single_file_flow(label, handler, opts)
		local edit_id = "edit_single_" .. label
		local paths = make_edit(edit_id, 2, opts)
		reset_calls()
		select_file(edit_id, 1)
		handler()
		assert(calls.rerender == 1, label .. " first single-file action should rerender while pending")
		assert(calls.finalize == 0, label .. " first single-file action should not finalize while pending")
		reset_calls()
		select_file(edit_id, 2)
		handler()
		assert(calls.finalize == 1, label .. " second single-file action should finalize once resolved")
		assert(calls.rerender == 0, label .. " final single-file action should not rerender")
		cleanup(paths)
	end

	run_single_file_flow("accept", chat_edits.handle_edit_accept_file)
	run_single_file_flow("reject", chat_edits.handle_edit_reject_file, { disk = "after" })
	run_single_file_flow("resolve", chat_edits.handle_edit_resolve_file)

	local function run_all_file_flow(label, handler, opts)
		local edit_id = "edit_all_" .. label
		local paths = make_edit(edit_id, 2, opts)
		reset_calls()
		select_file(edit_id, 1)
		handler()
		assert(calls.finalize == 1, label .. " all-file action should finalize once resolved")
		assert(calls.rerender == 0, label .. " all-file action should not rerender after all resolved")
		cleanup(paths)
	end

	run_all_file_flow("accept", chat_edits.handle_edit_accept_all)
	run_all_file_flow("reject", chat_edits.handle_edit_reject_all, { disk = "after" })
	run_all_file_flow("resolve", chat_edits.handle_edit_resolve_all)

	local original_accept = changes.accept
	local original_reject = changes.reject

	local accept_failure_paths = make_edit("edit_accept_partial_failure", 3)
	local accept_failure_edit = edit_state.get_edit("edit_accept_partial_failure")
	local failed_accept_change = accept_failure_edit.files[2].change_id
	changes.accept = function(change_id, opts)
		if change_id == failed_accept_change then
			return false, "accept write failed"
		end
		return original_accept(change_id, opts)
	end
	local accept_ok, accept_err, accept_errors = edit_state.accept_all("edit_accept_partial_failure")
	assert(not accept_ok, "accept_all should fail when a file cannot be applied")
	assert(accept_err:find("accept write failed", 1, true), "accept_all error should include failed file detail")
	assert(#accept_errors == 1, "accept_all should return one aggregated error")
	assert(accept_failure_edit.files[1].status == "accepted", "accept_all should accept successful files")
	assert(accept_failure_edit.files[2].status == "pending", "accept_all should leave failed files pending")
	assert(accept_failure_edit.files[3].status == "accepted", "accept_all should continue after a failed file")
	changes.accept = original_accept
	cleanup(accept_failure_paths)

	local reject_failure_paths = make_edit("edit_reject_partial_failure", 3, { disk = "after" })
	local reject_failure_edit = edit_state.get_edit("edit_reject_partial_failure")
	local failed_reject_change = reject_failure_edit.files[2].change_id
	changes.reject = function(change_id)
		if change_id == failed_reject_change then
			return false, "reject write failed"
		end
		return original_reject(change_id)
	end
	local reject_ok, reject_err, reject_errors = edit_state.reject_all("edit_reject_partial_failure")
	assert(not reject_ok, "reject_all should fail when a file cannot be reverted")
	assert(reject_err:find("reject write failed", 1, true), "reject_all error should include failed file detail")
	assert(#reject_errors == 1, "reject_all should return one aggregated error")
	assert(reject_failure_edit.files[1].status == "rejected", "reject_all should reject successful files")
	assert(reject_failure_edit.files[2].status == "pending", "reject_all should leave failed files pending")
	assert(reject_failure_edit.files[3].status == "rejected", "reject_all should continue after a failed file")
	changes.reject = original_reject
	cleanup(reject_failure_paths)

	local reject_file_failure_paths = make_edit("edit_reject_file_failure", 1, { disk = "after" })
	local reject_file_edit = edit_state.get_edit("edit_reject_file_failure")
	changes.reject = function()
		return false, "single reject failed"
	end
	local reject_file_ok = edit_state.reject_file("edit_reject_file_failure", 1)
	assert(not reject_file_ok, "reject_file should fail when the change cannot be reverted")
	assert(reject_file_edit.files[1].status == "pending", "reject_file should leave failed files pending")
	changes.reject = original_reject
	cleanup(reject_file_failure_paths)

	local original_notify = vim.notify
	vim.notify = noop
	local chat_failure_paths = make_edit("edit_chat_batch_failure", 2)
	local chat_failure_edit = edit_state.get_edit("edit_chat_batch_failure")
	local chat_failed_change = chat_failure_edit.files[2].change_id
	changes.accept = function(change_id, opts)
		if change_id == chat_failed_change then
			return false, "chat batch failed"
		end
		return original_accept(change_id, opts)
	end
	reset_calls()
	select_file("edit_chat_batch_failure", 1)
	chat_edits.handle_edit_accept_all()
	assert(calls.finalize == 0, "failed chat batch action should not finalize")
	assert(calls.rerender == 1, "failed chat batch action should rerender")
	assert(chat_failure_edit.files[1].status == "accepted", "failed chat batch should keep successful statuses")
	assert(chat_failure_edit.files[2].status == "pending", "failed chat batch should leave failed file pending")
	changes.accept = original_accept
	vim.notify = original_notify
	cleanup(chat_failure_paths)

	local readonly_accept_paths = make_edit("edit_readonly_accept", 2, { review_mode = "readonly" })
	reset_calls()
	select_file("edit_readonly_accept", 1)
	chat_edits.handle_edit_accept_file()
	assert(calls.finalize == 1, "readonly accept should finalize directly")
	assert(calls.rerender == 0, "readonly accept should not rerender")
	cleanup(readonly_accept_paths)

	local readonly_reject_paths = make_edit("edit_readonly_reject", 2, { review_mode = "readonly" })
	reset_calls()
	select_file("edit_readonly_reject", 1)
	chat_edits.handle_edit_reject_file()
	assert(calls.finalize == 1, "readonly reject should finalize directly")
	assert(calls.rerender == 0, "readonly reject should not rerender")
	cleanup(readonly_reject_paths)

	local native_diff = require("opencode.ui.native_diff")
	local original_native_show = native_diff.show
	local captured_native_show
	native_diff.show = function(files, opts)
		captured_native_show = { files = files, opts = opts }
	end

	local native_multifile_paths = make_edit("edit_native_multifile", 3)
	select_file("edit_native_multifile", 2)
	chat_edits.handle_edit_diff_tab()
	assert(captured_native_show, "native diff tab should open through native_diff.show")
	assert(#captured_native_show.files == 3, "native diff tab should include every pending edit file")
	assert(captured_native_show.opts.edit_id == "edit_native_multifile", "native diff should keep edit id")
	assert(captured_native_show.opts.file_index == 2, "native diff should keep selected edit file fallback")
	assert(captured_native_show.opts.start_index == 2, "native diff should start on selected file")
	assert(captured_native_show.files[2].edit_file_index == 2, "native diff files should keep original edit indices")
	cleanup(native_multifile_paths)

	captured_native_show = nil
	local native_pending_paths = make_edit("edit_native_pending_filter", 3)
	local native_pending_edit = edit_state.get_edit("edit_native_pending_filter")
	native_pending_edit.files[1].status = "accepted"
	select_file("edit_native_pending_filter", 2)
	chat_edits.handle_edit_diff_tab()
	assert(captured_native_show, "native diff tab should open when selected file is pending")
	assert(#captured_native_show.files == 2, "native diff tab should include only pending files")
	assert(captured_native_show.opts.start_index == 1, "native diff start index should be relative to pending files")
	assert(captured_native_show.files[1].edit_file_index == 2, "pending filtered native diff should keep original indices")
	native_diff.show = original_native_show
	cleanup(native_pending_paths)

	chat_edits.finalize_edit = original_finalize
	chat_edits.rerender_edit = original_rerender
	chat_edits.refresh_edit = original_refresh
	chat_state.winid = original_winid
	chat_state.bufnr = original_bufnr
	chat_state.edits = original_edits
end

local setup_ok, setup_err = pcall(function()
	local opencode = require("opencode")
	opencode.setup({
		server = {
			auto_start = false,
		},
		chat = {
			session_tabs = {
				colors = {
					active_fg = "#ffffff",
					active_bg = "#3b82f6",
					inactive_bg = "#1f2937",
					running_fg = "#22c55e",
					active_running_fg = "#86efac",
				},
			},
		},
		lualine = {
			enabled = true,
		},
	})
	assert(type(opencode.open_input_at_end) == "function", "open_input_at_end is not exported")
	assert(type(opencode.add_current_line) == "function", "add_current_line is not exported")
	assert(type(opencode.add_current_line_and_open_input) == "function", "add_current_line_and_open_input is not exported")
	assert(type(opencode.add_visual_selection) == "function", "add_visual_selection is not exported")
	assert(
		type(opencode.add_visual_selection_and_open_input) == "function",
		"add_visual_selection_and_open_input is not exported"
	)
	assert(type(opencode.active_sessions) == "function", "active_sessions is not exported")
	assert(type(opencode.toggle_danger_mode) == "function", "toggle_danger_mode is not exported")
	assert(type(opencode.new_session) == "function", "new_session is not exported")
	assert(type(opencode.close_session) == "function", "close_session is not exported")
	assert(type(opencode.is_danger_mode_enabled) == "function", "is_danger_mode_enabled is not exported")
	opencode.enable_danger_mode({ silent = true })
	assert(opencode.is_danger_mode_enabled() == true, "danger mode did not enable")
	opencode.disable_danger_mode({ silent = true })
	assert(opencode.is_danger_mode_enabled() == false, "danger mode did not disable")
	local permission_state = require("opencode.permission.state")
	local danger = require("opencode.permission.danger")
	local client = require("opencode.client")
	permission_state.clear_all()
	danger.clear()
	local original_respond_permission = client.respond_permission
	local approved = {}
	client.respond_permission = function(permission_id, reply, opts, callback)
		table.insert(approved, { permission_id = permission_id, reply = reply, opts = opts })
		callback(nil, true)
	end
	permission_state.add_permission("perm_danger_pending", "session_danger", "bash", {})
	assert(danger.approve_pending() == 1, "danger mode should queue active permission approval")
	assert(#approved == 1, "danger mode should call respond_permission for active permission")
	assert(approved[1].permission_id == "perm_danger_pending", "danger mode approved wrong permission")
	assert(approved[1].reply == "once", "danger mode should approve permissions once")
	local edit_state = require("opencode.edit.state")
	local changes = require("opencode.artifact.changes")
	local original_accept = changes.accept
	local original_notify = vim.notify
	local danger_path = vim.fn.tempname()
	vim.fn.writefile({ "before" }, danger_path)
	approved = {}
	permission_state.clear_all()
	edit_state.clear_all()
	changes.clear()
	danger.clear()
	edit_state.add_edit("edit_danger_failed", "session_danger", {
		{ filePath = danger_path, before = "before\n", after = "after\n" },
	}, {})
	local danger_edit = edit_state.get_edit("edit_danger_failed")
	local danger_failed_change = danger_edit.files[1].change_id
	changes.accept = function(change_id, opts)
		if change_id == danger_failed_change then
			return false, "danger accept failed"
		end
		return original_accept(change_id, opts)
	end
	vim.notify = noop
	assert(danger.approve_pending() == 0, "danger mode should not queue edit approval after local failure")
	assert(#approved == 0, "danger mode should not call respond_permission after local edit failure")
	assert(danger_edit.files[1].status == "pending", "danger mode should leave failed edit files pending")
	vim.notify = original_notify
	changes.accept = original_accept
	vim.fn.delete(danger_path)
	edit_state.clear_all()
	changes.clear()
	client.respond_permission = original_respond_permission
	permission_state.clear_all()
	danger.clear()
	local component = opencode.lualine_component()
	assert(type(component) == "string", "lualine component did not return a string")
	local app_state = require("opencode.state")
	local lualine = require("opencode.components.lualine")
	lualine.setup({
		show_attention = true,
		attention_icon = "◈",
		show_diff_stats = false,
	})
	app_state.set_session("attention-session", "Attention session")
	app_state.set_session_pending_counts("attention-session", { questions = 1 })
	local attention_component = lualine.component()
	assert(attention_component:find("◈1", 1, true), "lualine component did not show attention count")
	assert(not attention_component:find("idle", 1, true), "lualine component should not show status text")
	app_state.set_session_pending_counts("attention-session", { questions = 0 })
	if vim.fn.executable("git") == 1 then
		local original_cwd = vim.fn.getcwd()
		local tmp = vim.fn.tempname()
		vim.fn.mkdir(tmp, "p")
		vim.fn.system({ "git", "-C", tmp, "init" })
		if vim.v.shell_error == 0 then
			vim.fn.writefile({ "one", "two", "three" }, tmp .. "/new.txt")
			vim.cmd("lcd " .. vim.fn.fnameescape(tmp))

			lualine.setup({
				show_attention = false,
				show_diff_stats = true,
				diff_stats_cache_ms = 0,
				diff_stats_include_untracked = true,
			})
			local diff_component = lualine.component()
			assert(diff_component:find("+3", 1, true), "lualine component did not show git additions")
			assert(diff_component:find("-0", 1, true), "lualine component did not show git deletions")
			assert(
				diff_component:find("OpenCodeLualineDiffAdd", 1, true),
				"lualine additions were not highlighted"
			)
			assert(
				diff_component:find("OpenCodeLualineDiffDelete", 1, true),
				"lualine deletions were not highlighted"
			)
		end
		vim.cmd("lcd " .. vim.fn.fnameescape(original_cwd))
		vim.fn.delete(tmp, "rf")
	end

	local slash = require("opencode.slash")
	local slash_commands = {}
	for _, command in ipairs(slash.get_commands()) do
		slash_commands[command.name] = command
	end
	assert(slash_commands.clear ~= nil, "/clear is not registered")
	assert(slash_commands.new ~= nil, "/new is not registered")
	for _, alias in ipairs(slash_commands.new.aliases or {}) do
		assert(alias ~= "clear", "/clear must not be an alias for /new")
	end

	local app_state = require("opencode.state")
	app_state.set_session("runtime-session", "Runtime Session")
	slash_commands = {}
	for _, command in ipairs(slash.get_commands()) do
		slash_commands[command.name] = command
	end
	assert(slash_commands.close ~= nil, "/close is not registered")
	app_state.set_recent_sessions({
		{ id = "historical-session", title = "Historical Session", message_count = 5 },
	}, 30)
	assert(
		app_state.get_session_record("historical-session").message_count == 5,
		"backend message_count did not update session record"
	)
	app_state.upsert_session({ id = "remembered-session", title = "Remembered Session" }, { touch = false })
	local active_by_id = {}
	for _, session in ipairs(app_state.get_active_sessions()) do
		active_by_id[session.id] = true
	end
	assert(active_by_id["runtime-session"] == true, "runtime session is missing from active sessions")
	assert(active_by_id["historical-session"] ~= true, "historical session leaked into active sessions")
	assert(active_by_id["remembered-session"] ~= true, "untouched remembered session leaked into active sessions")
	vim.cmd("new")
	local winid = vim.api.nvim_get_current_win()
	require("opencode.ui.chat.state").state.winid = winid
	require("opencode.ui.chat").update_winbar()
	assert(vim.wo[winid].winbar:match("Runtime Session"), "chat winbar did not render runtime session tab")
	local current_tab_hl = vim.api.nvim_get_hl(0, { name = "OpenCodeWinbarCurrent", link = false })
	assert(current_tab_hl.fg == 0xffffff, "configured active tab foreground was not applied")
	assert(current_tab_hl.bg == 0x3b82f6, "configured active tab background was not applied")
	local running_tab_hl = vim.api.nvim_get_hl(0, { name = "OpenCodeWinbarRunning", link = false })
	assert(running_tab_hl.fg == 0x22c55e, "configured running tab foreground was not applied")
	assert(running_tab_hl.bg == 0x1f2937, "configured inactive tab background was not applied")
	vim.cmd("bwipeout!")
	app_state.set_session("second-session", "Second Session")
	assert(opencode.close_session({ silent = true }) == true, "close_session did not close current tab")
	assert(app_state.get_session().id == "runtime-session", "close_session did not activate neighboring tab")
	assert(app_state.get_session_record("second-session") ~= nil, "close_session deleted the session record")
	active_by_id = {}
	for _, session in ipairs(app_state.get_active_sessions()) do
		active_by_id[session.id] = true
	end
	assert(active_by_id["second-session"] ~= true, "closed session leaked into active sessions")
	app_state.set_session("child-session", "Child Session", { runtime = false })
	active_by_id = {}
	for _, session in ipairs(app_state.get_active_sessions()) do
		active_by_id[session.id] = true
	end
	assert(active_by_id["runtime-session"] == true, "runtime root disappeared while viewing child session")
	assert(active_by_id["child-session"] ~= true, "child session leaked into active sessions")
	local sync = require("opencode.sync")
	sync.handle_message_updated({
		id = "task-message",
		sessionID = "runtime-session",
		role = "assistant",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "task-part",
		messageID = "task-message",
		sessionID = "runtime-session",
		type = "tool",
		tool = "task",
		metadata = { sessionId = "child-session" },
	})
	local widget_support = require("opencode.ui.chat.widget_support")
	assert(
		widget_support.should_render("child-session", "pending", "runtime-session", false) == true,
		"runtime root should render pending widgets from its task child"
	)
	assert(
		widget_support.should_render("historical-session", "pending", "runtime-session", false) == false,
		"unrelated root session widget leaked into selected chat"
	)
	app_state.remove_session("runtime-session")
	active_by_id = {}
	for _, session in ipairs(app_state.get_active_sessions()) do
		active_by_id[session.id] = true
	end
	assert(active_by_id["runtime-session"] ~= true, "removed session leaked into active sessions")
	app_state.set_message_count(7)
	app_state.set_session(nil, nil)
	assert(app_state.get_message_count() == 0, "clearing active session should reset message count")
end)

if not setup_ok then
	print("Smoke setup failure:")
	print("  " .. tostring(setup_err))
	error("Smoke setup failure: " .. tostring(setup_err), 0)
end

print("Smoke require/setup passed")
	end)
end)
