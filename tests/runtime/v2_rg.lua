-- Actual rg subprocess, native queue/cancel and reconnect during a running tool.
local app, client = require("opencode"), require("opencode.client")
local state, sync, lifecycle = require("opencode.state"), require("opencode.sync"), require("opencode.lifecycle")
local session, chat = require("opencode.session"), require("opencode.ui.chat")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
vim.cmd.cd(vim.fn.fnameescape(directory))
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function await(register)
	local done, data, failure
	register(function(err, result) failure, data, done = err, result, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return data
end
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR, auth = { username = "opencode", password = "opencode-nvim-test-only" } },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end)
wait(function() return state.is_connected() and sync.get_model(provider, model) end, "Catalogs unavailable")
vim.fn.writefile({ "-needle", "-needle second", "tail" }, directory .. "/search fixture.txt")
local fifo = directory .. "/blocked-search.fifo"
assert(vim.system({ "mkfifo", fifo }):wait().code == 0, "FIFO fixture unavailable")
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model },
	permissions = { { action = "rg", resource = "*", effect = "allow" } } }, cb) end)
session.remember(info); session.set_active(info.id, "rg runtime matrix", { preserve_cache = true }); chat.open()
local function idle_count()
	local count = 0
	for _, message in ipairs(sync.get_messages(info.id)) do if message.type == "idle" then count = count + 1 end end
	return count
end
assert(require("opencode.send").send([[Call the direct top-level rg function three times. These are independent tests and may run together, each with path="search fixture.txt":
1. pattern="-needle", fixed_strings=true, max_results=1.
2. pattern="ABSENT_TOKEN_783".
3. pattern="[" (an intentionally invalid regex).
Do not use execute or any other tool, do not correct or retry the invalid regex. After the third call, reply briefly that the test is complete.]], {}))
wait(function() return idle_count() == 1 end, "rg result matrix did not finish", 180000)
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local results = {}
for _, message in ipairs(history) do for _, part in ipairs(message.parts) do
	if part.type == "tool" and part.tool == "rg" then results[#results + 1] = part.state end
end end
local rank = { ["-needle"] = 1, ABSENT_TOKEN_783 = 2, ["["] = 3 }
table.sort(results, function(a, b) return (rank[a.input.pattern] or 4) < (rank[b.input.pattern] or 4) end)
assert(#results == 3, vim.inspect(results))
assert(results[1].status == "completed" and results[1].metadata.truncated == true and results[1].output:find("-needle", 1, true))
assert(results[2].status == "completed" and results[2].metadata.exitCode == 1 and results[2].output == "No matches found.")
assert(results[3].status == "error" and results[3].error:find("ripgrep failed", 1, true))
chat.do_render()
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "rg-results") end
assert(require("opencode.send").send('Call the direct top-level rg exactly once with pattern="needle" and path=' .. vim.json.encode(fifo)
	.. '. This is an intentionally waiting FIFO fixture. Do not use other tools, do not change the path, and do not retry.', {}))
local child_pid
wait(function()
	local running = false
	for _, message in ipairs(sync.get_messages(info.id)) do for _, part in ipairs(sync.get_parts(message.id)) do
		if part.type == "tool" and part.tool == "rg" and part.state.status == "running" and part.state.input.path == fifo then running = true end
	end end
	if not running then return false end
	local result = vim.system({ "pgrep", "-f", fifo:gsub("([.%(%)%[%]*+?^$\\|])", "\\%1") }, { text = true }):wait()
	for pid in (result.stdout or ""):gmatch("%d+") do
		local process = vim.system({ "ps", "-p", pid, "-o", "comm=" }, { text = true }):wait()
		if vim.fn.fnamemodify(vim.trim(process.stdout or ""), ":t") == "rg" then child_pid = tonumber(pid); return true end
	end
	return false
end, "rg did not open the FIFO", 100000)
client.disconnect_events(); state.set_connection("idle")
assert(client.connect_events()); wait(state.is_connected, "Tool reconnect failed")
local queued = await(function(cb) client.send_message(info.id, { id = "msg_queue_cancel_fixture", text = "QUEUED_SHOULD_NOT_RUN", delivery = "queue" }, cb) end)
local inbox = await(function(cb) client.get_inbox(info.id, cb) end)
local found = false
for _, entry in ipairs(inbox) do if entry.id == queued.id then found = true end end
assert(found, "Busy prompt did not remain queued")
await(function(cb) client.cancel_input(info.id, queued.id, cb) end)
inbox = await(function(cb) client.get_inbox(info.id, cb) end)
for _, entry in ipairs(inbox) do assert(entry.id ~= queued.id, "Cancelled input still queued") end
await(function(cb) client.abort_session(info.id, cb) end)
wait(function() return not vim.uv.kill(child_pid, 0) end, "Interrupted rg subprocess survived", 10000)
wait(function() return idle_count() >= 2 end, "Interrupted session did not become idle", 30000)
local final = await(function(cb) client.get_all_messages(info.id, cb) end)
for _, message in ipairs(final) do for _, part in ipairs(message.parts) do
	assert(not (part.type == "text" and part.text == "QUEUED_SHOULD_NOT_RUN"), "Cancelled queue input ran")
end end
chat.do_render()
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "rg-interrupted") end
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", results = results, child_pid = child_pid,
	child_exited_after_interrupt = true, queued_input_cancelled = true, reconnected_during_tool = true, history = final }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Native rg success/empty/error, running subprocess cancellation, queue cancellation and SSE reconnect passed")
