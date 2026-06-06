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
local parse_grep_line
for i = 1, math.huge do
	local name, value = debug.getupvalue(search.render_tool, i)
	if not name then
		break
	end
	if name == "parse_grep_line" then
		parse_grep_line = value
		break
	end
end
assert(type(parse_grep_line) == "function", "grep parser upvalue should be available")
local grep_path, grep_body, grep_body_col = parse_grep_line("path:with:colon/file.lua:12:3:local x = 1")
assert(grep_path == "path:with:colon/file.lua", "grep parser should preserve colon-containing path")
assert(grep_body == "local x = 1", "grep parser should return body after line and column")
assert(grep_body_col == #"path:with:colon/file.lua:12:3:", "grep parser should return correct body offset")
grep_path, grep_body, grep_body_col = parse_grep_line("path:with:colon/file.lua:12:body")
assert(grep_path == "path:with:colon/file.lua", "grep parser should preserve colon path without column")
assert(grep_body == "body", "grep parser should return no-column body")
assert(grep_body_col == #"path:with:colon/file.lua:12:", "grep parser should return no-column body offset")

local rg = require("opencode.ui.chat.rg")
local function find_function_upvalue(fn, target, seen)
	seen = seen or {}
	if type(fn) ~= "function" or seen[fn] then
		return nil
	end
	seen[fn] = true
	for i = 1, math.huge do
		local name, value = debug.getupvalue(fn, i)
		if not name then
			break
		end
		if name == target then
			return value
		end
		if type(value) == "function" then
			local nested = find_function_upvalue(value, target, seen)
			if nested then
				return nested
			end
		end
	end
	return nil
end
local parse_rg_line = find_function_upvalue(rg.render_tool, "parse_rg_line")
assert(type(parse_rg_line) == "function", "rg parser upvalue should be available")
local rg_path, rg_body, rg_body_col = parse_rg_line("path:with:colon/file.lua:12:3:local x = 1")
assert(rg_path == "path:with:colon/file.lua", "rg parser should preserve colon-containing path")
assert(rg_body == "local x = 1", "rg parser should return body after line and column")
assert(rg_body_col == #"path:with:colon/file.lua:12:3:", "rg parser should return correct body offset")
rg_path, rg_body, rg_body_col = parse_rg_line("path:with:colon/file.lua-12-local x = 1")
assert(rg_path == "path:with:colon/file.lua", "rg parser should preserve context path")
assert(rg_body == "local x = 1", "rg parser should return context body")
assert(rg_body_col == #"path:with:colon/file.lua-12-", "rg parser should return context body offset")

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
local wrapped_binary = render.wrap_text_with_ranges(binary_line, 80)
assert(wrapped_binary[1].text == "PAR1<NUL>data", "binary line did not wrap as sanitized text")
local panel_result = { lines = {}, highlights = {} }
assert(
	pcall(render.add_panel_line, panel_result, binary_line, "Normal", { width = 40 }),
	"panel line render failed on binary text"
)
assert(not panel_result.lines[1]:find(string.char(0), 1, true), "panel line kept a raw NUL byte")

local function wait_until(predicate, message)
	assert(vim.wait(500, predicate, 10), message)
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

	local bash_result = require("opencode.ui.chat.bash").render_tool({
		tool = "bash",
		state = {
			status = "completed",
			input = { command = "echo hi" },
			output = "hi",
		},
	}, false)
	assert(bash_result and table.concat(bash_result.lines, "\n"):find("Shell", 1, true), "bash widget should render")

	local rg_result = rg.render_tool({
		tool = "rg",
		state = {
			status = "completed",
			input = { pattern = "local", path = "lua", type = "lua", column = true },
			output = "lua/opencode/init.lua:12:3:local M = {}",
		},
	}, false)
	assert(rg_result and table.concat(rg_result.lines, "\n"):find("Ripgrep", 1, true), "rg widget should render")

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
