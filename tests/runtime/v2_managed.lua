-- Real native daemon registration, PID/version discovery and host restart.
local app, state, lifecycle = require("opencode"), require("opencode.state"), require("opencode.lifecycle")
local function wait(predicate, why) assert(vim.wait(20000, predicate, 20), why) end
app.setup({ server = { managed = true, service_file = assert(vim.env.OPENCODE_V2_SERVICE_FILE), command = assert(vim.env.OPENCODE_V2_CLI),
	auto_start = true, use_shell_env = false, config_dir = vim.env.OPENCODE_CONFIG_DIR }, lualine = { enabled = false }, chat = { session_tabs = { persist = false } } })
local callbacks = 0
lifecycle.ensure_connected(function() callbacks = callbacks + 1 end)
wait(function() return callbacks == 1 and state.is_connected() end, "Managed service native readiness failed")
local first = lifecycle.managed_status()
assert(first.discovered and not state.is_server_managed() and state.get_server_pid() == nil, "Discovered daemon must not be plugin-owned")
assert(first.password == nil and first.auth == nil, "Managed status exposed credentials")
local restarted = false
if first.can_manage then
	local finished, failure
	lifecycle.manage_service("restart", function(err) failure, finished = err, true end)
	wait(function() return finished end, "Native restart timed out"); assert(not failure, failure and failure.message)
	wait(state.is_connected, "Restarted native service did not reconnect")
	local second = lifecycle.managed_status()
	assert(second.pid ~= first.pid and second.can_manage, "Native restart did not refresh identity")
	restarted = true
end
vim.fn.writefile({ vim.json.encode({ version = first.version, native_service_autostart = true, native_managed_discovery = true, host_restart = restarted, plugin_ownership = false }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
lifecycle.disconnect()
print("Native managed discovery and managing-host checks passed")
