-- Real native REST/SSE and persistent WebSocket through a verified TLS/base-path proxy.
local app, client, state, session = require("opencode"), require("opencode.client"), require("opencode.state"), require("opencode.session")
local lifecycle = require("opencode.lifecycle")
local function wait(predicate, why) assert(vim.wait(20000, predicate, 20), why) end
local function await(register, expected_error)
	local done, failure, value
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "Native TLS request timed out")
	if expected_error then assert(failure and failure.retryable == false, "Untrusted TLS must fail terminally"); return failure end
	assert(not failure, failure and failure.message); return value
end
local url = assert(vim.env.OPENCODE_V2_SERVER_URL)
local auth = { username = "opencode", password = assert(vim.env.OPENCODE_V2_PASSWORD) }
client.setup({ url = url, auth = auth })
local untrusted = await(client.health, true); assert(untrusted.code == "tls_verification_failed", untrusted.message)
local tls = { ca_file = assert(vim.env.OPENCODE_V2_CA_FILE) }
app.setup({ server = { url = url, tls = tls, auth = auth, auto_start = false, use_shell_env = false,
	config_dir = vim.env.OPENCODE_CONFIG_DIR }, lualine = { enabled = false }, chat = { session_tabs = { persist = false } } })
local ready = false
lifecycle.ensure_connected(function() ready = true end)
wait(function() return ready and state.is_connected() end, "Native HTTPS/SSE readiness failed")
local info = await(client.health)
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
assert(#await(function(cb) client.list_providers(cb, { directory = directory }) end) == 0, "Offline provider catalog must be empty")
assert(#await(function(cb) require("opencode.client.v2").request("model_list", { query = { location = { directory = directory } } }, cb) end) == 0,
	"Offline model catalog must be empty")
local record = await(function(cb) client.create_session({ title = "TLS transport", location = { directory = assert(vim.env.OPENCODE_V2_PROJECT) } }, cb) end)
session.remember(record); session.set_active(record.id, record.title, { preserve_cache = true })
await(function(cb) client.set_session_environment(record.id, { PATH = "/bin:/usr/bin", TLS_TEST = "native-environment" }, cb) end)
await(function(cb) client.run_session_shell(record.id, "printf '%s' \"$TLS_TEST\"", cb) end)
local messages = await(function(cb) client.get_messages(record.id, {}, cb) end)
local environment = false
for _, message in ipairs(messages) do
	local output = message.info.output
	if type(output) == "table" and output.output == "native-environment" then environment = true end
end
assert(environment, "Native TLS environment replacement did not reach shell output")
local terminal = await(function(cb) client.create_terminal(record.id, { command = "/bin/sh", args = {}, title = "TLS terminal", env = vim.empty_dict(), size = { cols = 80, rows = 24 } }, cb) end)
local output, failure = "", nil
local handle = assert(require("opencode.client.pty").connect({ id = terminal.id, session_id = record.id, directory = record.location.directory,
	attachment_id = "tls-native-test", on_data = function(data) output = output .. data end, on_error = function(err) failure = err end }))
wait(function() return handle.is_ready() or failure end, "Native WSS attachment timed out"); assert(not failure, failure and failure.message)
assert(handle.input("printf 'native-wss-utf8-привет\\n'\n", 80, 24), "Native WSS input rejected")
wait(function() return output:find("native-wss-utf8-привет", 1, true) or failure end, "Native WSS output missing"); assert(not failure, failure and failure.message)
handle.close(); await(function(cb) client.remove_terminal(terminal.id, cb) end)
await(function(cb) client.delete_session(record.id, cb) end)
vim.fn.writefile({ vim.json.encode({ version = info.version, https_rest = true, https_sse = true, base_path = true, basic_auth = true,
	untrusted_certificate_rejected = true, session_environment = true, native_wss = true, offline_model_catalog = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
lifecycle.disconnect()
print("Native verified HTTPS, SSE, environment and WSS passed")
