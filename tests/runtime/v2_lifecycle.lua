-- Own a separate server within the harness's disposable profile, then reconnect
-- to the harness's external server without stopping that process.
local app, lifecycle, state, client = require("opencode"), require("opencode.lifecycle"), require("opencode.state"), require("opencode.client")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
vim.cmd.cd(vim.fn.fnameescape(directory))
local function wait(predicate, why, timeout) assert(vim.wait(timeout or 25000, predicate, 20), why) end
local function health()
	local done, result, failure
	client.health(function(err, info) result, failure, done = info, err, true end)
	wait(function() return done end, "Health timeout"); assert(not failure, vim.inspect(failure)); return result
end
local owned_root = assert(vim.env.OPENCODE_TEST_HOME) .. "/owned-lifecycle"
local owned_env = {}
for variable, relative in pairs({ XDG_CONFIG_HOME = "config", XDG_DATA_HOME = "data", XDG_STATE_HOME = "state",
	XDG_CACHE_HOME = "cache", TMPDIR = "tmp", OPENCODE_TEST_HOME = "home" }) do
	owned_env[variable] = owned_root .. "/" .. relative; vim.fn.mkdir(owned_env[variable], "p")
end
local owned_config = owned_root .. "/config/opencode"; vim.fn.mkdir(owned_config, "p")
app.setup({ server = { command = assert(vim.env.OPENCODE_V2_CLI), auto_start = true, use_shell_env = false, env = owned_env, debug = true,
	config_dir = owned_config, shutdown_on_exit = true,
	auth = { username = "opencode" } }, lualine = { enabled = false } })
lifecycle.setup({ debug = true })
local chat, input = require("opencode.ui.chat"), require("opencode.ui.input")
app.toggle()
wait(function() return state.is_connected() and client.sse.is_connected() and chat.is_visible() end, "First toggle startup timeout")
local first = health()
assert(first.version == "2.0.11" and state.is_server_managed() and first.pid == state.get_server_pid())
assert(type(client.http.opts.auth.password) == "string" and #client.http.opts.auth.password == 64, "Missing ephemeral owned-server authentication")
chat.focus()
assert(type(vim.fn.maparg("i", "n", false, true).callback) == "function")
vim.fn.maparg("i", "n", false, true).callback()
wait(input.is_visible, "First-toggle input did not open")
assert(vim.api.nvim_get_current_win() ~= chat.get_winid(), "Input did not receive focus")
assert(health().pid == first.pid, "Input started another server")
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw"); vim.rpcnotify(1, "opencode_screenshot", "first-toggle-input") end
input.close(); chat.close()
lifecycle.restart()
wait(function() return state.is_connected() and state.get_server_pid() ~= first.pid end, "Owned restart timeout")
local second = health(); assert(second.pid ~= first.pid and state.is_server_managed())
local stopped
assert(lifecycle.stop(function() stopped = true end))
wait(function() return stopped and state.get_server_pid() == nil end, "Owned stop timeout")
assert(not pcall(vim.uv.kill, first.pid, 0) or vim.uv.kill(first.pid, 0) == nil, "Old owned process still alive")
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
client.setup({ host = host, port = tonumber(port), auth = { username = "opencode", password = "opencode-nvim-test-only" } })
state.set_server_info({ host = host, port = tonumber(port) })
lifecycle.setup({ host = host, port = tonumber(port), auto_start = true })
lifecycle.ensure_connected(function() end)
wait(function() return state.is_connected() end, "External connection timeout")
local external = health(); assert(not state.is_server_managed() and external.pid ~= second.pid)
lifecycle.restart()
wait(function() return state.is_connected() end, "External reconnect timeout")
assert(health().pid == external.pid, "External reconnect replaced the server")
lifecycle.disconnect()
assert(health().pid == external.pid, "Disconnect stopped external server")
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", owned_start = true, owned_restart = true, owned_stop = true,
	first_toggle_input = true,
	external_reconnect = true, external_disconnect_preserved_process = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
print("Owned startup/restart/stop and external reconnect/disconnect passed")
