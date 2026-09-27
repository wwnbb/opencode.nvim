-- Real background child execution, overlapping status, UI linkage and completion.
local app, client, state = require("opencode"), require("opencode.client"), require("opencode.state")
local sync, session, chat = require("opencode.sync"), require("opencode.session"), require("opencode.ui.chat")
local cs, tasks = require("opencode.ui.chat.state").state, require("opencode.ui.chat.tasks")
local animation = require("opencode.ui.chat.task_animation")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 20000, predicate, 20), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing mapping " .. name); map.callback()
end
local function text() chat.do_render(); return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n") end
local function shot(name)
	chat.do_render(); vim.cmd("redraw!")
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.rpcnotify(1, "opencode_screenshot", name) end
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Requested model not discovered")
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model } }, cb) end)
session.remember(info); session.set_active(info.id, "Background subagents", { preserve_cache = true }); chat.open()
local prompt = 'This is a background delegation test. Use the direct subagent tool twice with background=true and agent="general". Both calls must have exactly description="Small test" and model=' .. vim.json.encode(provider .. "/" .. model)
	.. '. Launch both without waiting for the first. First child prompt: Call shell once with command "sleep 20", then reply exactly CHILD_ONE. Second child prompt: Call shell once with command "sleep 20", then reply exactly CHILD_TWO. These are two independent test tasks. Do not read or modify files. After both launches reply PARENT_LAUNCHED. When completion notifications arrive, acknowledge them without any further tool calls.'
assert(require("opencode.send").send(prompt, {}))
local entries = {}
wait(function()
	chat.do_render(); entries = {}
	for id, pos in pairs(cs.tasks) do
		local part = tasks.resolve_tool_part(pos)
		if part.raw_tool == "subagent" and part.state.input.background == true then
			local child = (part.state.metadata or {}).sessionID
			if child and part.state.status == "completed" and animation.task_status(part) == "running" then entries[#entries + 1] = { id = id, child = child } end
		end
	end
	return #entries == 2
end, "Two completed background launches never overlapped with running children", 150000)
assert(entries[1].child ~= entries[2].child, "Identical descriptions collapsed distinct children")
shot("background-children-running")
local frame = cs.task_anim_frame
wait(function() return cs.task_anim_frame ~= frame end, "Background spinner did not advance")
for _, entry in ipairs(entries) do
	chat.focus(); chat.do_render(); local pos = assert(cs.tasks[entry.id])
	vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 }); key("gd")
	wait(function() return state.get_session().id == entry.child end, "gd chose wrong child")
	key("<BS>"); wait(function() return state.get_session().id == info.id end, "Backspace lost parent")
end
-- Reconnect while both children are in flight; exact IDs must survive hydration.
client.disconnect_events(); state.set_connection("idle"); assert(client.connect_events())
wait(state.is_connected, "No SSE reconnect")
local children = {}
wait(function()
	for _, entry in ipairs(entries) do
		local status = sync.get_session_status(entry.child)
		if not status or status.type ~= "idle" then return false end
	end
	return true
end, "Background children did not finish", 150000)
for index, entry in ipairs(entries) do
	local child = await(function(cb) client.get_session(entry.child, cb) end)
	assert(child.model.providerID == provider and child.model.id == model, "Child used another model")
	local history = await(function(cb) client.get_all_messages(entry.child, cb) end)
	local answer, shell_calls, idle = "", 0, false
	for _, message in ipairs(history) do
		if message.info.type == "idle" then assert(message.info.outcome == "succeeded", vim.inspect(message.info)); idle = true end
		if message.info.role == "assistant" then
			for _, part in ipairs(message.parts) do
				if part.type == "text" then answer = answer .. part.text end
				if part.type == "tool" then assert(part.raw_tool == "shell" and part.state.status == "completed"); shell_calls = shell_calls + 1 end
			end
		end
	end
	answer = vim.trim(answer)
	assert(idle and shell_calls == 1 and (answer == "CHILD_ONE" or answer == "CHILD_TWO"), "Incomplete child: " .. answer)
	children[#children + 1] = { session = child, history = history, answer = answer }
	chat.focus(); chat.do_render(); local pos = assert(cs.tasks[entry.id])
	assert(animation.task_status(tasks.resolve_tool_part(pos)) == "completed", "Finished child still spins")
	vim.api.nvim_win_set_cursor(chat.get_winid(), { pos.start_line + 1, 0 }); key("gd")
	wait(function() return state.get_session().id == entry.child and text():find(answer, 1, true) end, "Completed child result not visible")
	shot("background-child-completed-" .. index); key("<BS>")
	wait(function() return state.get_session().id == info.id end, "Backspace did not restore parent")
end
assert(children[1].answer ~= children[2].answer, "Two children returned the same task result")
wait(function()
	local notified = {}
	for _, message in ipairs(sync.get_messages(info.id)) do
		if message.type == "synthetic" then
			for _, child in ipairs(children) do
				if (message.text or ""):find(child.session.id, 1, true) then notified[child.session.id] = true end
			end
		end
	end
	return vim.tbl_count(notified) == 2 and state.get_session_status(info.id).type == "idle"
end, "Parent did not receive both background completions", 60000)
shot("background-children-completed")
vim.fn.writefile({ vim.json.encode({ session = info, children = children, parent = await(function(cb) client.get_all_messages(info.id, cb) end),
	actual_background_overlap = true, running_animation = true, gd_back = true, reconnected = true, rendered = text() }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); require("opencode.lifecycle").disconnect()
print("Two background children succeeded with real tools, animation, reconnect and exact navigation")
