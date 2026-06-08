-- Headless module-load smoke test for opencode.nvim.
-- Run with: nvim --headless --clean --cmd "set rtp+=." -l scripts/smoke-require.lua

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
	os.exit(1)
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
assert(thinking.extract_topic("**Planning** next") == "Planning", "thinking topic extraction should trim markdown header")
local thinking_hl_ok, thinking_hl = pcall(thinking.get_highlights, 0)
assert(thinking_hl_ok, "thinking highlights should not crash: " .. tostring(thinking_hl))
assert(thinking_hl[1].hl_group == "Title", "thinking highlights should default header highlight")

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
				{ line = 1, col_start = 0, col_end = 10, hl_group = "OpenCodeTodoHeader" },
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
	sync.handle_message_updated({
		id = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		role = "assistant",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "text_part",
		messageID = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		type = "text",
		text = "",
	})
	for _, delta in ipairs({ "hel", "lo", " world" }) do
		sync.handle_part_delta({
			messageID = "msg_buffered_delta",
			partID = "text_part",
			field = "text",
			delta = delta,
			sessionID = "session_buffered_delta",
		})
	end
	assert(sync.get_part("msg_buffered_delta", "text_part").text == "hello world", "get_part should materialize deltas")

	sync.handle_part_updated({
		id = "parts_text",
		messageID = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		type = "text",
		text = "",
	})
	sync.handle_part_delta({
		messageID = "msg_buffered_delta",
		partID = "parts_text",
		field = "text",
		delta = "from parts",
		sessionID = "session_buffered_delta",
	})
	local parts = sync.get_parts("msg_buffered_delta")
	local saw_parts_text = false
	for _, part in ipairs(parts) do
		saw_parts_text = saw_parts_text or (part.id == "parts_text" and part.text == "from parts")
	end
	assert(saw_parts_text, "get_parts should materialize deltas")

	sync.handle_part_updated({
		id = "reason_part",
		messageID = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		type = "reasoning",
		text = "",
	})
	sync.handle_part_delta({
		messageID = "msg_buffered_delta",
		partID = "reason_part",
		field = "text",
		delta = "because",
		sessionID = "session_buffered_delta",
	})
	assert(sync.get_message_reasoning("msg_buffered_delta") == "because", "reasoning should materialize deltas")

	sync.handle_part_updated({
		id = "updated_part",
		messageID = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		type = "text",
		text = "base",
	})
	sync.handle_part_delta({
		messageID = "msg_buffered_delta",
		partID = "updated_part",
		field = "text",
		delta = " plus",
		sessionID = "session_buffered_delta",
	})
	sync.handle_part_updated({
		id = "updated_part",
		messageID = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		type = "text",
		text = "base plus",
	})
	assert(sync.get_part("msg_buffered_delta", "updated_part").text == "base plus", "part.updated should not double append")

	sync.handle_part_updated({
		id = "stale_part",
		messageID = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		type = "text",
		text = "fresh",
	})
	sync.handle_part_delta({
		messageID = "msg_buffered_delta",
		partID = "stale_part",
		field = "text",
		delta = " text",
		sessionID = "session_buffered_delta",
	})
	sync.handle_part_updated({
		id = "stale_part",
		messageID = "msg_buffered_delta",
		sessionID = "session_buffered_delta",
		type = "text",
		text = "fresh",
	})
	assert(sync.get_message_text("msg_buffered_delta"):find("fresh text", 1, true), "stale part update erased buffered text")
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
	local saved_client = package.loaded["opencode.client"]
	local saved_http = package.loaded["opencode.client.http"]
	local saved_sse = package.loaded["opencode.client.sse"]
	package.loaded["opencode.client"] = nil
	package.loaded["opencode.client.http"] = {
		health = function(callback)
			callback(nil, { version = "test-version" })
		end,
		get = function(path, callback)
			if path == "/global/config" then
				callback(nil, { plugin = { "test-plugin" } })
			else
				callback(nil, {})
			end
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
		status_result and status_result.plugins and status_result.plugins[1] == "test-plugin",
		"client.get_status should include plugins from global config"
	)

	package.loaded["opencode.client"] = saved_client
	package.loaded["opencode.client.http"] = saved_http
	package.loaded["opencode.client.sse"] = saved_sse
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
	assert(log_text:find("new update", 1, true), "log viewer rebuild should render latest part update")
	assert(not log_text:find("old update", 1, true), "log viewer rebuild should replace older part update")
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

	local rendered_task = chat_tasks.render_task_tool(task_part, false)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, rendered_task.lines)
	render.apply_extmark_highlights(bufnr, chat_state_mod.chat_hl_ns, rendered_task.highlights, 0)
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
	input = {
		description = "Generated\nheader",
	},
	state = {
		status = "running",
		input = {
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
	bus.clear_history()
end

do
	local bus = require("opencode.events.bus")
	local message_handler = require("opencode.events.handlers.message")
	local app_state = require("opencode.state")
	local previous_session = app_state.get_session()

	bus.clear()
	bus.clear_history()
	message_handler.setup(bus)

	sync.clear_all()
	app_state.set_session("todo_filter_parent", "Todo Filter Parent")
	sync.handle_message_updated({
		id = "todo_filter_msg",
		sessionID = "todo_filter_parent",
		role = "assistant",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "todo_filter_task",
		messageID = "todo_filter_msg",
		sessionID = "todo_filter_parent",
		type = "tool",
		tool = "task",
		state = {
			status = "running",
			input = { subagent_type = "build", description = "child" },
			metadata = { sessionId = "todo_filter_child" },
		},
	})

	local todo_update_count = 0
	bus.on("todo_update", function(data)
		todo_update_count = todo_update_count + 1
		assert(data.session_id ~= "todo_filter_unrelated", "unrelated todo updates should not request chat render")
	end)

	bus.emit("todo_updated", {
		sessionID = "todo_filter_unrelated",
		todos = { { content = "ignore", status = "pending" } },
	})
	assert(vim.wait(100, function()
		return todo_update_count > 0
	end, 10) == false, "unrelated todo update should be filtered")

	bus.emit("todo_updated", {
		sessionID = "todo_filter_child",
		todos = { { content = "child", status = "in_progress" } },
	})
	wait_until(function()
		return todo_update_count == 1
	end, "task-child todo update should request chat render")

	sync.clear_all()
	if previous_session and previous_session.id then
		app_state.set_session(previous_session.id, previous_session.name, {
			runtime = previous_session.runtime,
		})
	else
		app_state.set_session(nil, nil)
	end
	bus.clear()
	bus.clear_history()
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
	local chat_render = require("opencode.ui.chat.render")
	local app_state = require("opencode.state")
	local previous_session = app_state.get_session()
	local previous_buf = vim.api.nvim_get_current_buf()
	local previous_state = {
		bufnr = chat_state.bufnr,
		winid = chat_state.winid,
		visible = chat_state.visible,
		stream_blocks = chat_state.stream_blocks,
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
	sync.handle_message_updated({
		id = "stream_message",
		sessionID = "stream_session",
		role = "assistant",
		time = { created = 1 },
	})
	sync.handle_part_updated({
		id = "stream_part",
		messageID = "stream_message",
		sessionID = "stream_session",
		type = "text",
		text = "hello",
	})
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "hello" })
	vim.bo[bufnr].modifiable = false

	local block_key = render_state.stream_block_key("stream_session", "stream_message", "stream_part", "text")
	chat_state.stream_blocks[block_key] = {
		start_line = 0,
		end_line = 0,
		session_id = "stream_session",
		message_id = "stream_message",
		part_id = "stream_part",
		kind = "text",
		chat_width = chat_render.get_chat_text_width(),
		text_length = #"hello",
	}
	sync.handle_part_delta({
		messageID = "stream_message",
		partID = "stream_part",
		field = "text",
		delta = " world",
		sessionID = "stream_session",
	})
	assert(
		chat.update_stream_part_block("stream_session", "stream_message", "stream_part", {
			field = "text",
			delta = " world",
		}),
		"same-line stream delta should update in place"
	)
	assert(
		vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "hello world",
		"same-line stream delta did not append visibly"
	)
	assert(chat_state.stream_blocks[block_key].end_line == 0, "same-line stream delta should not grow block")

	sync.handle_part_delta({
		messageID = "stream_message",
		partID = "stream_part",
		field = "text",
		delta = "\nnext",
		sessionID = "stream_session",
	})
	assert(
		chat.update_stream_part_block("stream_session", "stream_message", "stream_part", {
			field = "text",
			delta = "\nnext",
		}),
		"newline stream delta should fall back to block replacement"
	)
	local updated_stream_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	assert(#updated_stream_lines == 2, "newline stream delta should grow rendered block")
	assert(updated_stream_lines[1] == "hello world", "newline fallback should preserve first line")
	assert(updated_stream_lines[2] == "next", "newline fallback should render next line")

	sync.clear_all()
	chat_state.bufnr = previous_state.bufnr
	chat_state.winid = previous_state.winid
	chat_state.visible = previous_state.visible
	chat_state.stream_blocks = previous_state.stream_blocks
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
	local spinner = require("opencode.ui.spinner")

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

	question_state.add_question("q_anchor", "render_contract_session", {
		{ question = "Anchor?", options = { { label = "Yes", value = "yes" } } },
	}, { message_id = "m1", timestamp = 1 })
	question_state.add_question("q_tool", "render_contract_session", {
		{ question = "Tool question?", options = { { label = "Yes", value = "yes" } } },
	}, { message_id = "m4", call_id = "call_question", timestamp = 5 })
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

	spinner.start()
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
	assert(chat_state.tools.m4_question_tool == nil, "question tool row should be suppressed by widget")
	assert(chat_state.tools.m4_edit_tool == nil, "edit tool row should be suppressed by widget")

	local block_key = render_state.stream_block_key("render_contract_session", "m4", "m4_text", "text")
	assert(chat_state.stream_blocks[block_key], "full render should register streaming text block")
	assert(type(chat_state.spinner_footer_line) == "number", "full render should register spinner footer line")

	spinner.stop()
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
	local chat = require("opencode.ui.chat")
	local chat_state_mod = require("opencode.ui.chat.state")
	local chat_state = chat_state_mod.state
	local app_state = require("opencode.state")
	local previous_buf = vim.api.nvim_get_current_buf()
	local previous_session = app_state.get_session()
	local previous_config = app_state.get_config()
	local previous_bufnr = chat_state.bufnr
	local previous_winid = chat_state.winid
	local previous_visible = chat_state.visible
	local previous_chat_config = chat_state.config
	local previous_local_notices = chat_state.local_notices
	local previous_session_stack = chat_state.session_stack
	local previous_auto_scroll = chat_state.auto_scroll
	local previous_stream_blocks = chat_state.stream_blocks
	local previous_spinner_footer_line = chat_state.spinner_footer_line
	local previous_questions = chat_state.questions
	local previous_permissions = chat_state.permissions
	local previous_edits = chat_state.edits
	local previous_tasks = chat_state.tasks
	local previous_tools = chat_state.tools
	local previous_force_full_render = chat_state.force_full_render
	local previous_render_scheduled = chat_state.render_scheduled
	local previous_render_in_progress = chat_state.render_in_progress
	local previous_render_generation = chat_state.render_generation
	local previous_applied_render_generation = chat_state.applied_render_generation
	local previous_last_render_highlight_signature = chat_state.last_render_highlight_signature
	local previous_render_highlights_dirty_start = chat_state.render_highlights_dirty_start

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
	chat_state.force_full_render = true
	chat_state.render_scheduled = false
	chat_state.render_in_progress = false
	chat_state.render_generation = 0
	chat_state.applied_render_generation = 0
	chat_state.last_render_highlight_signature = nil
	chat_state.render_highlights_dirty_start = nil

	app_state.set_config({ chat = { todo = { show_dock = false } } })
	sync.clear_all()
	app_state.set_session("todo_widget_parent", "Todo Widget Parent")
	app_state.set_session_status("todo_widget_parent", { type = "busy" })
	sync.handle_message_updated({
		id = "todo_widget_msg",
		sessionID = "todo_widget_parent",
		role = "assistant",
		time = { created = 1 },
		finish = "tool-calls",
	})
	sync.handle_part_updated({
		id = "todo_widget_task",
		messageID = "todo_widget_msg",
		sessionID = "todo_widget_parent",
		type = "tool",
		tool = "task",
		state = {
			status = "completed",
			input = { subagent_type = "grep_slave", description = "child todos" },
			metadata = { sessionId = "todo_widget_child" },
		},
	})
	sync.handle_part_updated({
		id = "todo_widget_tool",
		messageID = "todo_widget_msg",
		sessionID = "todo_widget_parent",
		type = "tool",
		tool = "todowrite",
		state = {
			status = "running",
			input = {
				todos = {
					{ content = "Keep first", status = "in_progress" },
					{ content = "Remove second", status = "pending" },
					{ content = "Remove third", status = "pending" },
				},
			},
		},
	})

	chat.do_render()
	assert(chat_state.tools.todo_widget_tool, "todowrite widget should be tracked after render")

	for i = 1, 12 do
		sync.handle_todo_updated("todo_widget_child", {
			{ content = "child tick " .. tostring(i), status = i == 12 and "completed" or "in_progress" },
		})
		chat.do_render()
	end

	local rendered_before = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local header_count = 0
	for _ in rendered_before:gmatch("Updating todos%.%.%.") do
		header_count = header_count + 1
	end
	assert(header_count == 1, "child todo churn should not duplicate the parent todowrite widget")

	sync.handle_part_updated({
		id = "todo_widget_tool",
		messageID = "todo_widget_msg",
		sessionID = "todo_widget_parent",
		type = "tool",
		tool = "todowrite",
		state = {
			status = "completed",
			input = {
				todos = {
					{ content = "Keep first", status = "completed" },
				},
			},
		},
	})
	chat_state.tools.todo_widget_tool.tool_part = sync.get_part("todo_widget_msg", "todo_widget_tool")
	chat.rerender_tool("todo_widget_tool")

	local rendered_after = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	assert(rendered_after:find("Keep first", 1, true), "shrunk todowrite widget should keep current todo")
	assert(not rendered_after:find("Remove second", 1, true), "shrunk todowrite widget should remove stale todo text")
	assert(not rendered_after:find("Remove third", 1, true), "shrunk todowrite widget should remove stale trailing todo text")

	local todo_pos = chat_state.tools.todo_widget_tool
	assert(todo_pos and todo_pos.start_line <= todo_pos.end_line, "shrunk todowrite widget should keep valid range")
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, chat_state_mod.chat_hl_ns, 0, -1, { details = true })) do
		local row = mark[2]
		local details = mark[4] or {}
		local hl_group = details.hl_group
		if type(hl_group) == "string" and hl_group:find("^OpenCodeTodo") then
			assert(
				row >= todo_pos.start_line and row <= todo_pos.end_line,
				"todo highlight extmark leaked outside the current widget range"
			)
		end
	end

	require("opencode.ui.chat.tasks").stop_task_animation_timer()
	sync.clear_all()
	app_state.set_config(previous_config)
	if previous_session and previous_session.id then
		app_state.set_session(previous_session.id, previous_session.name, {
			runtime = previous_session.runtime,
		})
	else
		app_state.set_session(nil, nil)
	end
	chat_state.bufnr = previous_bufnr
	chat_state.winid = previous_winid
	chat_state.visible = previous_visible
	chat_state.config = previous_chat_config
	chat_state.local_notices = previous_local_notices
	chat_state.session_stack = previous_session_stack
	chat_state.auto_scroll = previous_auto_scroll
	chat_state.stream_blocks = previous_stream_blocks
	chat_state.spinner_footer_line = previous_spinner_footer_line
	chat_state.questions = previous_questions
	chat_state.permissions = previous_permissions
	chat_state.edits = previous_edits
	chat_state.tasks = previous_tasks
	chat_state.tools = previous_tools
	chat_state.force_full_render = previous_force_full_render
	chat_state.render_scheduled = previous_render_scheduled
	chat_state.render_in_progress = previous_render_in_progress
	chat_state.render_generation = previous_render_generation
	chat_state.applied_render_generation = previous_applied_render_generation
	chat_state.last_render_highlight_signature = previous_last_render_highlight_signature
	chat_state.render_highlights_dirty_start = previous_render_highlights_dirty_start
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
	local todos = require("opencode.ui.chat.todos")

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
			input = { filePath = "lua/opencode/init.lua" },
			output = table.concat(read_output, "\n"),
		},
	}, false)
	local read_expanded = read.render_tool({
		tool = "read",
		state = {
			status = "completed",
			input = { filePath = "lua/opencode/init.lua" },
			output = table.concat(read_output, "\n"),
		},
	}, true)
	assert(render_text(read_collapsed):find("Read lua/opencode/init.lua", 1, true), "read widget should render state.input.filePath")
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
	assert(rg_result and table.concat(rg_result.lines, "\n"):find("Ripgrep", 1, true), "rg widget should render")

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
	assert(render_text(rg_collapsed):find("more lines", 1, true), "rg widget should show collapsed overflow")
	assert(not render_text(rg_expanded):find("more lines", 1, true), "rg widget should hide overflow when expanded")

	local skill_result = skill.render_tool({
		tool = "skill",
		state = {
			status = "completed",
			input = { name = "opencode-nvim-widgets" },
			output = "# Skill: opencode-nvim-widgets\n\nRender widgets cleanly.",
		},
	}, false)
	assert(render_text(skill_result):find('Skill "opencode-nvim-widgets"', 1, true), "skill widget should render")

	local todo_write_result = todos.render_tool({
		tool = "todowrite",
		state = {
			status = "completed",
			input = {
				todos = {
					{ content = "Write helper", status = "completed", priority = "high" },
					{ content = "Use helper", status = "in_progress" },
				},
			},
		},
	}, false)
	assert(render_text(todo_write_result):find("Updated todos", 1, true), "todowrite widget should render")
	assert(
		not chat_tasks.is_animating_tool_part({
			tool = "todowrite",
			state = { status = "running" },
		}),
		"todowrite widget should use scheduled renders instead of animation in-place updates"
	)

	local todo_read_result = todos.render_tool({
		tool = "todoread",
		state = {
			status = "completed",
			output = {
				todos = {
					{ content = "Read helper", status = "pending" },
				},
			},
		},
	}, false)
	assert(render_text(todo_read_result):find("Read todos", 1, true), "todoread widget should render")

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
		changes.clear()
		local files = {}
		local paths = {}
		for index = 1, file_count do
			local path = vim.fn.tempname()
			local before = "before " .. tostring(index) .. "\n"
			local after = "after " .. tostring(index) .. "\n"
			vim.fn.writefile(vim.split(before, "\n", { plain = true }), path)
			table.insert(paths, path)
			table.insert(files, {
				filePath = path,
				before = before,
				after = after,
			})
		end
		edit_state.add_edit(edit_id, "session_edit_lifecycle", files, opts or {})
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

	local function run_single_file_flow(label, handler)
		local edit_id = "edit_single_" .. label
		local paths = make_edit(edit_id, 2)
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
	run_single_file_flow("reject", chat_edits.handle_edit_reject_file)
	run_single_file_flow("resolve", chat_edits.handle_edit_resolve_file)

	local function run_all_file_flow(label, handler)
		local edit_id = "edit_all_" .. label
		local paths = make_edit(edit_id, 2)
		reset_calls()
		select_file(edit_id, 1)
		handler()
		assert(calls.finalize == 1, label .. " all-file action should finalize once resolved")
		assert(calls.rerender == 0, label .. " all-file action should not rerender after all resolved")
		cleanup(paths)
	end

	run_all_file_flow("accept", chat_edits.handle_edit_accept_all)
	run_all_file_flow("reject", chat_edits.handle_edit_reject_all)
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

	local reject_failure_paths = make_edit("edit_reject_partial_failure", 3)
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

	local reject_file_failure_paths = make_edit("edit_reject_file_failure", 1)
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
	local native_state
	for index = 1, math.huge do
		local name, value = debug.getupvalue(native_diff.show, index)
		if not name then
			break
		end
		if name == "state" then
			native_state = value
			break
		end
	end
	local sync_edit_action
	for index = 1, math.huge do
		local name, value = debug.getupvalue(native_diff._confirm_current, index)
		if not name then
			break
		end
		if name == "sync_edit_action" then
			sync_edit_action = value
			break
		end
	end
	assert(type(native_state) == "table", "native diff state upvalue should be available")
	assert(type(sync_edit_action) == "function", "native diff sync action upvalue should be available")
	local native_paths = make_edit("edit_native_refresh", 2)
	local refresh_calls = 0
	chat_edits.refresh_edit = function(edit_id)
		refresh_calls = refresh_calls + 1
		calls.last_refreshed = edit_id
	end
	native_state.edit_id = "edit_native_refresh"
	native_state.edit_file_index = 1
	sync_edit_action("resolve")
	wait_until(function()
		return refresh_calls == 1
	end, "native diff sync should refresh through shared edit path")
	assert(calls.last_refreshed == "edit_native_refresh", "native diff refresh should target originating edit")
	native_state.edit_id = nil
	native_state.edit_file_index = nil
	cleanup(native_paths)

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
		{ id = "historical-session", title = "Historical Session", messageCount = 5 },
	}, 30)
	assert(
		app_state.get_session_record("historical-session").message_count == 5,
		"backend messageCount did not update session record"
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
	os.exit(1)
end

print("Smoke require/setup passed")
