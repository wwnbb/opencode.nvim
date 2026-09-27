-- Actual libuv HTTP/version rejection, then a real 2.0.11 plugin capability check.
local app, client = require("opencode"), require("opencode.client")
local state, lifecycle = require("opencode.state"), require("opencode.lifecycle")
local chat = require("opencode.ui.chat")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local function wait(predicate, why) assert(vim.wait(15000, predicate, 20), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local notices, old_notify = {}, vim.notify
-- Collect expected failure notifications while exercising both connection paths.
-- Display the final real warning once, avoiding nested native hit-enter pagers.
vim.notify = function(message) notices[#notices + 1] = tostring(message) end
vim.o.cmdheight = 6
vim.cmd.cd(vim.fn.fnameescape(directory))
local seen, sockets = {}, {}
local fixture_pid = vim.fn.getpid()
local server = assert(vim.uv.new_tcp()); assert(server:bind("127.0.0.1", 0))
assert(server:listen(8, function(err)
	assert(not err)
	local socket = assert(vim.uv.new_tcp()); sockets[#sockets + 1] = socket; assert(server:accept(socket))
	local request = ""
	socket:read_start(function(read_err, data)
		assert(not read_err)
		if not data then if not socket:is_closing() then socket:close() end; return end
		request = request .. data
		if not request:find("\r\n\r\n", 1, true) then return end
		socket:read_stop()
		seen[#seen + 1] = request:match("^[^\r\n]+")
		local body = vim.json.encode({ version = "1.9.0", pid = fixture_pid, urls = {}, paths = { tmp = directory } })
		socket:write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body,
			function() if not socket:is_closing() then socket:close() end end)
	end)
end))
app.setup({ server = { host = "127.0.0.1", port = server:getsockname().port, auto_start = true,
	command = "/fixture-must-not-spawn", config_dir = vim.env.OPENCODE_CONFIG_DIR, use_shell_env = false }, lualine = { enabled = false } })
app.toggle()
wait(function() return state.get_connection() == "error" end, "Unsupported backend not rejected")
assert(not state.is_server_managed() and state.get_server_pid() == nil and not client.sse.is_connected(), "Version rejection started a server/SSE")
assert(#seen == 1 and seen[1] == "GET /api/info HTTP/1.1", vim.inspect(seen))
assert(table.concat(notices, "\n"):find("2.0.11 or newer 2.x is required (server: 1.9.0)", 1, true), vim.inspect(notices))
local version_notices = vim.deepcopy(notices)
chat.close(); lifecycle.disconnect(); server:close()
for _, socket in ipairs(sockets) do if not socket:is_closing() then socket:close() end end

local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, config_dir = vim.env.OPENCODE_CONFIG_DIR,
	use_shell_env = false, auth = { username = "opencode", password = "opencode-nvim-test-only" } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end); wait(state.is_connected, "Actual v2 did not connect")
local info = await(function(cb) client.create_session({ location = { directory = directory } }, cb) end)
require("opencode.session").remember(info)
notices = {}
require("opencode.session").set_active(info.id, "Compatibility check", { preserve_cache = true })
chat.open(); chat.focus()
wait(function() return table.concat(notices, "\n"):find("scripts/install-tools.sh", 1, true) end, "Missing plugin update instructions")
local capability, capability_error, done
client.review_rpc("capabilities", vim.empty_dict(), directory, function(err, data) capability_error, capability, done = err, data, true end)
wait(function() return done end, "Capability query timeout")
local mode = assert(vim.env.OPENCODE_V2_COMPATIBILITY)
if mode == "missing" then assert(capability_error, "Absent plugin unexpectedly advertised capabilities")
else assert(not capability_error and capability.protocolVersion == 0, vim.inspect(capability or capability_error)) end
assert(state.is_connected() and #await(function(cb) client.get_all_messages(info.id, cb) end) == 0, "Missing plugin broke native history")
assert(#require("opencode.edit.state").get_all_active() == 0, "Obsolete plugin created pending edits")
old_notify(notices[#notices], vim.log.levels.WARN)
if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw!"); vim.rpcnotify(1, "opencode_screenshot", "plugin-" .. mode .. "-notice") end
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", mode = mode, version_probe = {
	fixture_version = "1.9.0", simulated_info_only = true, requests = seen, notices = version_notices,
	no_spawn_no_sse = true }, capability = capability, capability_error = capability_error,
	notices = notices, native_history_readable = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Unsupported version rejected; missing/obsolete plugin warning remains actionable")
