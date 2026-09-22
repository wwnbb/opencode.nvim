-- Real model tool -> native policy -> persistent plugin store -> SSE -> dock.
local opencode, client = require("opencode"), require("opencode.client")
local state, sync, chat = require("opencode.state"), require("opencode.sync"), require("opencode.ui.chat")
local events, session = require("opencode.events"), require("opencode.session")
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local provider, model = assert(vim.env.OPENCODE_V2_MODEL):match("^([^/]+)/(.+)$")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
vim.cmd.cd(vim.fn.fnameescape(directory)); vim.o.columns, vim.o.lines = 120, 36
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 15000, predicate, 20), why) end
local function await(register)
	local done, result, failure
	register(function(err, data) failure, result, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return result
end
opencode.setup({ server = { host = host, port = tonumber(port), auto_start = false, use_shell_env = false,
	auth = { username = "opencode", password = "opencode-nvim-test-only" }, config_dir = vim.env.OPENCODE_CONFIG_DIR },
	session = { default_agent = "build", default_model = { providerID = provider, modelID = model } },
	chat = { layout = "vertical", width = 80, close_on_focus_lost = false }, lualine = { enabled = false } })
require("opencode.lifecycle").ensure_connected(function() end)
wait(function() return state.is_connected() and #sync.get_agents() > 0 and sync.get_model(provider, model) end, "Catalog timeout")
local info = await(function(cb) client.create_session({ location = { directory = directory }, model = { providerID = provider, id = model },
	permissions = { { action = "todowrite", resource = "*", effect = "allow" }, { action = "todoread", resource = "*", effect = "allow" } } }, cb) end)
session.remember(info)
session.set_active(info.id, "Todo smoke", { preserve_cache = true })
chat.open()
local function rpc(method, input) return await(function(cb) client.review_rpc(method, input, directory, cb) end) end
assert(rpc("todoGet", { sessionID = info.id }).revision == 0)
local prompt = 'Call the direct top-level todowrite tool exactly once. Pass revision=0 and todos=[{"id":"read","content":"Read fixture","status":"completed"},{"id":"check","content":"Check persistent dock","status":"pending"}]. Then call the top-level todoread tool once. Do not use the execute wrapper, tools namespace, shell or any other tool. Finally say TODO_READY.'
assert(require("opencode.send").send(prompt, { agent = "build", model = { providerID = provider, id = model } }))
wait(function()
	for _, message in ipairs(sync.get_messages(info.id)) do if message.type == "idle" then return true end end
	return false
end, "Todo model timeout", 120000)
local record = rpc("todoGet", { sessionID = info.id })
assert(record.revision == 1 and #record.todos == 2, vim.inspect(record))
wait(function() return #sync.get_todos(info.id) == 2 end, "Todo event not applied")
local cs = require("opencode.ui.chat.state").state
local function dock_text()
	local buf = cs.todo_bufnr
	if not buf or not vim.api.nvim_buf_is_valid(buf) then return "" end
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end
wait(function() return dock_text():find("Check persistent dock", 1, true) end, "Todo dock not rendered")
local rendered = dock_text()
if vim.env.OPENCODE_V2_ATTACHED_UI then
	vim.cmd("redraw")
	vim.rpcnotify(1, "opencode_screenshot", "todo-dock")
end
local history = await(function(cb) client.get_all_messages(info.id, cb) end)
local seen = {}
for _, message in ipairs(history) do for _, part in ipairs(message.parts) do
	if part.tool == "todowrite" or part.tool == "todoread" then assert(part.state.status == "completed", vim.inspect(part)); seen[part.tool] = true end
end end
assert(seen.todoread and seen.todowrite, "Both todo tools must complete")
-- A conflicting writer cannot erase the persisted list.
local rejected, conflict
client.review_rpc("todoSet", { protocolVersion = 1, sessionID = info.id, revision = 0, todos = {} }, directory,
	function(err) conflict, rejected = err, true end)
wait(function() return rejected end, "Conflict response timeout"); assert(conflict and conflict.rpc_type == "conflict", vim.inspect(conflict))
-- Location reload recreates the plugin and must retain its storage.
await(function(cb) require("opencode.client.v2").request("location_reload", {}, cb) end)
local reloaded = rpc("todoGet", { sessionID = info.id })
assert(vim.deep_equal(record, reloaded), vim.inspect(reloaded))
chat.close(); sync.clear_session(info.id)
events.emit("session_change", { id = info.id, preserve_cache = true }); chat.open()
wait(function() return #sync.get_todos(info.id) == 2 and dock_text():find("Check persistent dock", 1, true) end, "Todo reconnect recovery failed")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", model = provider .. "/" .. model, record = record, rendered = rendered,
	tools = seen, conflict = conflict.rpc_type, plugin_reload_persisted = true, reopened_dock = dock_text() }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); require("opencode.lifecycle").disconnect()
print("Persistent todo tools, conflict, plugin reload and reopened dock passed")
