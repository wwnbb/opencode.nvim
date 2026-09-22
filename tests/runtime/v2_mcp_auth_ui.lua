-- A disposable HTTP MCP endpoint requests OAuth; OpenCode derives needs_auth.
local app, client, state = require("opencode"), require("opencode.client"), require("opencode.state")
local chat, lifecycle, actions = require("opencode.ui.chat"), require("opencode.lifecycle"), require("opencode.actions")
local directory = assert(vim.env.OPENCODE_V2_PROJECT)
local host, port = assert(vim.env.OPENCODE_V2_SERVER_URL):match("^http://([^:]+):(%d+)$")
local function wait(predicate, why) assert(vim.wait(15000, predicate, 20), why) end
local function await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	wait(function() return done end, "HTTP timeout"); assert(not failure, vim.inspect(failure)); return value
end
local function key(name)
	local map = vim.fn.maparg(name, "n", false, true)
	assert(type(map.callback) == "function", "Missing mapping " .. name); map.callback()
end
local function screen_text()
	local lines = {}
	for _, win in ipairs(vim.api.nvim_list_wins()) do vim.list_extend(lines, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) end
	return table.concat(lines, "\n")
end
local function shot(name)
	if vim.env.OPENCODE_V2_ATTACHED_UI then vim.cmd("redraw!"); vim.rpcnotify(1, "opencode_screenshot", name) end
end
local fixture = assert(vim.uv.new_tcp()); assert(fixture:bind("127.0.0.1", 0))
local base = "http://127.0.0.1:" .. fixture:getsockname().port
local oauth = vim.json.encode({ issuer = base, authorization_endpoint = base .. "/authorize", token_endpoint = base .. "/token",
	response_types_supported = { "code" }, grant_types_supported = { "authorization_code", "refresh_token" }, code_challenge_methods_supported = { "S256" } })
local resource = vim.json.encode({ resource = base .. "/mcp", authorization_servers = { base }, bearer_methods_supported = { "header" } })
local sockets, requests = {}, {}
assert(fixture:listen(16, function(err)
	assert(not err)
	local socket = assert(vim.uv.new_tcp()); sockets[#sockets + 1] = socket; assert(fixture:accept(socket))
	local received = ""
	socket:read_start(function(read_err, data)
		assert(not read_err)
		if not data then if not socket:is_closing() then socket:close() end; return end
		received = received .. data
		if not received:find("\r\n\r\n", 1, true) then return end
		socket:read_stop()
		local line = received:match("^[^\r\n]+"); requests[#requests + 1] = line
		local path = line:match("^%S+ (%S+)")
		local body, status, extra = '{"error":"unauthorized"}', "401 Unauthorized", 'WWW-Authenticate: Bearer resource_metadata="' .. base .. '/.well-known/oauth-protected-resource"\r\n'
		if path:find("oauth-authorization-server", 1, true) then body, status, extra = oauth, "200 OK", ""
		elseif path:find("oauth-protected-resource", 1, true) then body, status, extra = resource, "200 OK", "" end
		socket:write("HTTP/1.1 " .. status .. "\r\nContent-Type: application/json\r\nConnection: close\r\n" .. extra .. "Content-Length: " .. #body .. "\r\n\r\n" .. body,
			function() if not socket:is_closing() then socket:close() end end)
	end)
end))
vim.cmd.cd(vim.fn.fnameescape(directory))
app.setup({ server = { host = host, port = tonumber(port), auto_start = false, config_dir = vim.env.OPENCODE_CONFIG_DIR,
	use_shell_env = false, auth = { username = "opencode", password = "opencode-nvim-test-only" } }, lualine = { enabled = false } })
lifecycle.ensure_connected(function() end); wait(state.is_connected, "No connection")
local opts = { directory = directory }
await(function(cb) client.http.put("/api/experimental/mcp/auth-fixture", { config = { type = "remote", url = base .. "/mcp",
	protocol = "legacy", oauth = { client_id = "public-fixture-client", auth_server_metadata_url = base .. "/.well-known/oauth-authorization-server" } } }, cb,
	{ query = { location = { directory = directory } } }) end)
local status
for _ = 1, 100 do
	status = await(function(cb) actions.get_mcp_status(cb, opts) end)
	if status["auth-fixture"] and status["auth-fixture"].status ~= "pending" then break end
	vim.wait(100, function() return false end, 10)
end
assert(status["auth-fixture"].status == "needs_auth", vim.inspect(status))
assert(status["auth-fixture"].integrationID, "Native MCP omitted its auth integration")
local linked = await(function(cb) client.integration("get", status["auth-fixture"].integrationID, nil, opts, cb) end)
assert(linked.methods[1].type == "oauth", vim.inspect(linked.methods))
chat.open(); chat.focus(); require("opencode.ui.palette").trigger("mcp.status")
wait(function() return screen_text():find("Needs auth", 1, true) end, "MCP menu lost the server auth state")
vim.cmd("stopinsert"); shot("mcp-needs-auth"); key("i")
wait(function() return screen_text():find("Status: Needs auth", 1, true) end, "MCP info status incorrect")
shot("mcp-auth-info"); key("q")
chat.focus(); require("opencode.ui.palette").trigger("mcp.status")
wait(function() return screen_text():find("Needs auth", 1, true) end, "MCP menu did not reopen")
vim.cmd("stopinsert"); local mcp_buffer = vim.api.nvim_get_current_buf(); key("a")
wait(function() return vim.api.nvim_get_current_buf() ~= mcp_buffer and screen_text():find(linked.methods[1].label, 1, true) end,
	"MCP auth key did not open linked integration methods")
shot("mcp-linked-auth"); vim.cmd("stopinsert"); key("<Esc>")
await(function(cb) client.http.delete("/api/experimental/mcp/auth-fixture", cb, { query = { location = { directory = directory } } }) end)
fixture:close(); for _, socket in ipairs(sockets) do if not socket:is_closing() then socket:close() end end
vim.fn.writefile({ vim.json.encode({ version = "2.0.11", native_mcp = status, requests = requests,
	status_from_real_401 = true, linked_auth_menu = true, linked_integration = linked,
	no_browser_or_token_request = true }) }, assert(vim.env.OPENCODE_V2_OUTPUT))
chat.close(); lifecycle.disconnect()
print("Native MCP needs_auth, info and linked integration menu passed")
