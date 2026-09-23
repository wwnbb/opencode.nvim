-- Native busy queue and explicit steering, including actual input/palette keys.
local app, client = require("opencode"), require("opencode.client")
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local session, lifecycle = require("opencode.session"), require("opencode.lifecycle")
local input, pending = require("opencode.ui.input"), require("opencode.session.pending")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing mapping " .. name); map.callback()
end
local function text()
	chat.do_render(); return table.concat(vim.api.nvim_buf_get_lines(chat.get_bufnr(), 0, -1, false), "\n")
end
local function shot(name)
	chat.do_render()
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw!"); vim.rpcnotify(1, "opencode_screenshot", name) end
end
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "No catalogs")
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model },
	permissions = { { action = "rg", resource = "*", effect = "allow" } } }, cb) end)
session.remember(info); session.set_active(info.id, "Queue and steering", { preserve_cache = true }); chat.open()
local fifo = directory .. "/queue.fifo"
assert(vim.system({ "mkfifo", fifo }):wait().code == 0)
local function start_fifo()
	assert(require("opencode.send").send('Call direct top-level rg once with pattern="needle" and path=' .. vim.json.encode(fifo)
		.. '. This is an intentionally waiting FIFO fixture. Do not use other tools, do not change the path, do not retry. After it completes reply FIFO_DONE.', {}))
	local child
	wait(function()
		local result = vim.system({ "pgrep", "-f", "queue[.]fifo" }, { text = true }):wait()
		for pid in (result.stdout or ""):gmatch("%d+") do
			local cmd = vim.system({ "ps", "-p", pid, "-o", "comm=" }, { text = true }):wait()
			if vim.fn.fnamemodify(vim.trim(cmd.stdout or ""), ":t") == "rg" then child = tonumber(pid); return true end
		end
		return false
	end, "No blocked rg", 120000)
	return child
end
local function keyboard_send(value)
	app.focus_input(); wait(input.is_visible, "No input")
	vim.api.nvim_buf_set_lines(vim.api.nvim_get_current_buf(), 0, -1, false, { value })
	vim.cmd("stopinsert"); key("<C-g>")
	local id
	wait(function()
		for candidate, item in pairs(pending.list(info.id)) do
			if item.text == value and item.status == "queued" then id = candidate; return true end
		end
	end, "Input not queued")
	chat.focus(); assert(text():find("Queued · C cancel · E edit", 1, true), "Queue badge missing")
	return id
end
local function cancel_menu(id)
	require("opencode.ui.palette").trigger("prompt.cancel_pending")
	wait(function() return vim.api.nvim_get_current_win() ~= chat.get_winid() end, "No cancellation menu")
	vim.cmd("stopinsert"); shot("queue-cancel-menu"); key("<CR>")
	wait(function() return pending.get(info.id, id).status == "cancelled" end, "Queue cancellation failed")
	chat.focus(); assert(not sync.get_message(info.id, id), "Cancelled input still in chat")
end
local child = start_fifo()
local cancelled = keyboard_send("CANCELLED_MUST_NOT_RUN")
shot("queue-pending")
cancel_menu(cancelled)
assert(vim.uv.kill(child, 0), "Cancelling input interrupted rg")
local retained = keyboard_send("INTERRUPT_MUST_KEEP_QUEUED")
chat.focus(); key("<C-c>")
wait(function() return not vim.uv.kill(child, 0) and state.get_session_status(info.id).type == "idle" end, "Interrupt did not settle")
local inbox = await(function(cb) client.get_inbox(info.id, cb) end)
assert(#inbox == 1 and inbox[1].id == retained, "Interrupt silently cleared queue")
client.disconnect_events(); state.set_connection("idle"); assert(client.connect_events())
wait(state.is_connected, "No reconnect")
-- Allow the full history recovery to finish before checking the pending input.
vim.wait(700, function() return false end, 20)
assert(text():find("INTERRUPT_MUST_KEEP_QUEUED", 1, true), "Reconnect lost queued message")
assert(text():find("Queued · C cancel · E edit", 1, true), "Reconnect lost queue badge")
shot("queue-after-interrupt-reconnect"); cancel_menu(retained)
child = start_fifo()
assert(require("opencode.send").send("Additional instruction: after the pending rg completes, reply exactly STEERING_APPLIED. Do not call any more tools.", { delivery = "steer" }))
local steered
wait(function()
	for id, item in pairs(pending.list(info.id)) do if item.payload and item.payload.delivery == "steer" and item.status == "accepted" then steered = id; return true end end
end, "Steering not admitted")
assert(text():find("Steering pending", 1, true), "Steering badge missing")
assert(vim.uv.kill(child, 0), "Steering unexpectedly interrupted the running tool")
shot("steering-pending")
local writer = vim.system({ "/bin/sh", "-c", 'printf "needle\\n" > "$1"', "fixture", fifo })
wait(function() return pending.get(info.id, steered).status == "delivered" and state.get_session_status(info.id).type == "idle" end, "Steering did not finish", 120000)
assert(writer:wait().code == 0)
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local answer, users = "", {}
for _, message in ipairs(history) do
	if message.info.role == "user" then users[message.info.id] = true end
	if message.info.role == "assistant" then for _, part in ipairs(message.parts) do if part.type == "text" then answer = answer .. part.text end end end
end
assert(not users[cancelled] and not users[retained] and users[steered], "Incorrect delivered inputs")
assert(answer:find("STEERING_APPLIED", 1, true), answer)
assert(not text():find("Steering pending", 1, true) and not text():find("Queued ·", 1, true), "Stale queue status")
shot("steering-completed")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", history = history, cancelled = cancelled, retained = retained,
	steered = steered, keyboard_queue = true, palette_cancel = true, interrupt_preserves_queue = true,
	reconnect_preserves_queue = true, explicit_steering = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Actual queue, palette cancel, interrupt, reconnect and steering passed")
