local app, client, state = require("opencode"), require("opencode.client"), require("opencode.state")
local chat, session, sync = require("opencode.ui.chat"), require("opencode.session"), require("opencode.sync")
local actions, cs = require("opencode.actions"), require("opencode.ui.chat.state").state
local sid, directory = assert(vim.env.OPENCODE_V2_SESSION), assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
vim.cmd.cd(vim.fn.fnameescape(directory))
local function wait(predicate, why) assert(vim.wait(20000, predicate, 20), why) end
local function await(register)
	local done, result, failure
	register(function(err, data) failure, result, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return result
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing key " .. name); map.callback()
end
local function text() return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n") end
local function shot(name)
	-- Session-change listeners schedule a surface reset after the state callback.
	-- Let it finish before capturing the actual linegrid.
	vim.wait(80, function() return false end, 10)
	chat.do_render(); vim.cmd("redraw!")
	vim.wait(30, function() return false end, 10)
	vim.rpcnotify(1, "opencode_screenshot", name)
end
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(state.is_connected, "No connection")
local parent = await(function(cb) client.get_session(sid, cb) end)
session.remember(parent); session.set_active(sid, "Reopened native history", { preserve_cache = true })
local history = await(function(cb) actions.load_session_messages(sid, { all = true }, cb) end)
chat.open(); chat.focus(); chat.do_render()
local result = { session = parent, history = history, fresh_neovim = true, new_model_requests = 0 }
local function save() vim.fn.writefile({ vim.json.encode(result) }, assert(vim.env.OPENCODE_V2_OUTPUT)) end
if vim.env.OPENCODE_V2_SCENARIO == "navigation" or vim.env.OPENCODE_V2_SCENARIO == "background" then
	local children = await(function(cb) client.get_session_children(sid, cb) end)
	assert(#children == 2, "Expected the two recorded native children")
	result.children = {}
	for _, child in ipairs(children) do session.remember(child) end
	local tasks = {}
	for part_id, position in pairs(cs.tasks) do
		local part = require("opencode.ui.chat.tasks").resolve_tool_part(position)
		if part and part.raw_tool == "subagent" then tasks[#tasks + 1] = part_id end
	end
	assert(#tasks == 2, "Native subagents did not restore their task widgets")
	local visited = {}
	for index, part_id in ipairs(tasks) do
		chat.do_render(); local pos = assert(cs.tasks[part_id])
		vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 })
		local part = require("opencode.ui.chat.tasks").resolve_tool_part(pos)
		local expected = part.state.metadata.sessionID
		assert(expected and not visited[expected], "Duplicate or missing exact child linkage")
		key("gd")
		wait(function() return state.get_session().id == expected end, "gd selected the wrong child")
		chat.do_render()
		if vim.env.OPENCODE_V2_SCENARIO == "background" then
			assert(text():find("CHILD_ONE", 1, true) or text():find("CHILD_TWO", 1, true), "Successful child result disappeared")
		else
			assert(text():find("free tier", 1, true), "Recorded provider failure disappeared from child history")
		end
		shot("reopened-child-" .. index)
		if vim.env.OPENCODE_V2_SCENARIO == "navigation" then
			assert(vim.api.nvim_win_call(chat.get_winid(), vim.fn.winsaveview).topline == 1, "Short child history is scrolled past its content")
		end
		visited[expected] = true
		result.children[#result.children + 1] = { session = await(function(cb) client.get_session(expected, cb) end),
			history = await(function(cb) client.get_all_messages(expected, cb) end), rendered = text(),
			view = vim.api.nvim_win_call(chat.get_winid(), vim.fn.winsaveview),
			window_buffer = vim.api.nvim_win_get_buf(chat.get_winid()), chat_buffer = chat.get_bufnr(),
			screen = (function()
				local rows = {}
				for row = 1, vim.o.lines do
					local columns = {}; for column = 1, vim.o.columns do columns[#columns + 1] = vim.fn.screenstring(row, column) end
					rows[#rows + 1] = table.concat(columns)
				end
				return table.concat(rows, "\n")
			end)() }
		key("<BS>"); wait(function() return state.get_session().id == sid end, "Backspace did not restore parent")
	end
	if vim.env.OPENCODE_V2_SCENARIO == "background" then
		wait(function()
			chat.do_render()
			for _, part_id in ipairs(tasks) do
				local part = require("opencode.ui.chat.tasks").resolve_tool_part(cs.tasks[part_id])
				if require("opencode.ui.chat.task_animation").task_status(part) ~= "completed" then return false end
			end
			return true
		end, "Reopened completed children still show running spinners")
		result.completed_child_spinners_stopped = true
	end
	shot("reopened-parent"); result.gd_back_exact_children = true; save()
	-- Hold native HTTP callbacks for both children, delete the root, then release.
	local original, delayed, child_ids = client.http.get, {}, {}
	for _, child in ipairs(children) do child_ids[child.id] = true end
	client.http.get = function(path, callback, opts)
		local child_id = path:match("^/api/session/(.-)/message$")
		if child_ids[child_id] then return original(path, function(err, data, meta)
			delayed[child_id] = function() callback(err, data, meta) end
		end, opts) end
		return original(path, callback, opts)
	end
	for _, child in ipairs(children) do actions.load_session_messages(child.id, function() error("Deleted child callback ran") end) end
	wait(function() return vim.tbl_count(delayed) == #children end, "Missing delayed child snapshots")
	client.http.get = original
	await(function(cb) client.delete_session(sid, cb) end)
	wait(function() return state.get_session_record(sid) == nil end, "Root deletion did not arrive")
	for _, release in pairs(delayed) do release() end
	vim.wait(100, function() return false end, 10)
	for _, child in ipairs(children) do
		assert(state.get_session_record(child.id) == nil and #sync.get_messages(child.id) == 0, "Deleted child resurrected")
		local done, failure
		client.get_session(child.id, function(err) failure, done = err, true end)
		wait(function() return done end, "Deleted child lookup timeout")
		assert(failure and failure.status == 404, vim.inspect(failure))
		assert(not require("opencode.session.lock").is_locked(child.id), "Deleted child kept execution lock")
	end
	assert(state.get_session().id ~= sid and not child_ids[state.get_session().id])
	assert(#cs.session_stack == 0)
	result.deleted_tree_callbacks_ignored = true
elseif vim.env.OPENCODE_V2_SCENARIO == "review" then
	local edits = require("opencode.edit.state")
	local entry_id, entry
	for id in pairs(cs.edits) do
		local candidate = edits.get_edit(id)
		-- Final metadata represents the move as one file; pending review used two choices.
		if candidate and #candidate.files == 7 then entry_id, entry = id, candidate; break end
	end
	assert(entry and edits.is_readonly(entry_id), "Completed review did not restore as a readonly widget")
	assert(text():find("R moved.txt -> renamed.txt", 1, true), "Cold move widget lost its destination")
	local before = {}
	local function bytes(path)
		local file = io.open(path, "rb")
		if not file then return false end
		local content = file:read("*a"); file:close(); return content
	end
	for _, file in ipairs(entry.files) do before[file.filepath] = bytes(file.filepath) end
	for _, name in ipairs({ "accepted.txt", "rejected.txt", "manual.txt", "added.txt", "deleted.txt", "moved.txt", "renamed.txt", "bom.txt" }) do
		assert(text():find(name, 1, true), "Completed review lost " .. name)
	end
	local pos = cs.edits[entry_id]
	vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 })
	shot("reopened-review")
	key("="); chat.do_render()
	assert(text():find("before", 1, true) and text():find("after", 1, true), "Stored inline diff missing")
	shot("reopened-review-diff")
	key("<C-a>"); key("<C-x>"); key("<C-m>")
	for path, content in pairs(before) do assert(bytes(path) == content, "Readonly review changed " .. path) end
	result.completed_review_readonly = true; result.inline_diff_available = true; result.file_bytes_unchanged = true
	result.rendered = text()
else
	local forms = require("opencode.question.state")
	assert(#forms.get_all_active() == 0, "Completed form restored as pending")
	local _, count = text():gsub("History: Blue answer", "")
	assert(count == 1, "Completed native question lost or duplicated its answer")
	local pos
	for _, value in pairs(cs.tools) do
		local part = require("opencode.ui.chat.tasks").resolve_tool_part(value)
		if part and part.tool == "question" then pos = value; break end
	end
	assert(pos, "Completed question tool missing")
	vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 })
	local before, writes = text(), 0
	local original = client.http.post
	client.http.post = function(...) writes = writes + 1; return original(...) end
	key("1"); key("<CR>"); key("<Space>"); key("<Tab>")
	client.http.post = original
	assert(writes == 0 and #forms.get_all_active() == 0 and text() == before, "Completed form remained interactive")
	shot("reopened-form-answer"); result.completed_question_readonly = true; result.rendered = text()
end
save(); chat.close(); require("opencode.lifecycle").disconnect()
print("Reopened native history scenario passed")
