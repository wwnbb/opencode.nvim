-- Wire-level route coverage. Source: the pinned contract inventory and recorded
-- 2.0.11 envelopes. Facade semantics have separate send/auth/history/review specs.
local location = { directory = "/project space" }
local session = { id = "s", location = location }
local model = { providerID = "provider", id = "model" }
local time = { created = 100, expires = 200 }
local responses = {
	empty = false,
	info = { version = "2.0.11", pid = 1, urls = {}, paths = { tmp = "/tmp" } },
	session = { data = session },
	page = { data = {}, cursor = { next = vim.NIL, previous = "opaque/+%" } },
	list = { data = {} },
	object = { data = { marker = false } },
	catalog = { data = {}, location = location },
	model = { data = model, location = location },
	integration = { data = { id = "integration", methods = {} }, location = location },
	oauth = { data = { attemptID = "attempt", mode = "code", url = "https://example.invalid", instructions = "test", time = time }, location = location },
	command_attempt = { data = { attemptID = "attempt", time = time }, location = location },
	attempt_status = { data = { status = "pending", time = time }, location = location },
	array = {},
	inbox = { data = { id = "inbox", sessionID = "s", type = "prompt", payload = { attachments = {} } } },
	interrupt = { interrupted = false },
	permission = { data = { id = "request", effect = "ask" } },
	rpc = { output = { protocolVersion = 1, review = true } },
}
-- Operation, HTTP method, native path, envelope, optional request body/query.
local cases = {
	{ "info", "GET", "/api/info", "info" },
	{ "location_reload", "POST", "/api/location/reload", "empty", nil, { location = location } },
	{ "session_list", "GET", "/api/session", "page", nil, { parentID = vim.NIL, limit = 1 } },
	{ "session_create", "POST", "/api/session", "session", { location = location, model = model } },
	{ "session_get", "GET", "/api/session/{sessionID}", "session" },
	{ "session_update", "PATCH", "/api/session/{sessionID}", "empty", { title = "renamed" } },
	{ "session_delete", "DELETE", "/api/session/{sessionID}", "empty" },
	{ "session_active", "GET", "/api/session/active", "object" },
	{ "session_fork", "POST", "/api/session/{sessionID}/fork", "session", { messageID = "message" } },
	{ "session_diff", "GET", "/api/session/{sessionID}/diff", "list", nil, { from = "message", to = "message2" } },
	{ "session_compact", "POST", "/api/session/{sessionID}/compact", "inbox", {} },
	{ "revert_stage", "POST", "/api/session/{sessionID}/revert/stage", "object", { messageID = "message", files = true } },
	{ "revert_clear", "DELETE", "/api/session/{sessionID}/revert", "empty" },
	{ "revert_commit", "POST", "/api/session/{sessionID}/revert/commit", "empty" },
	{ "message_list", "GET", "/api/session/{sessionID}/message", "page", nil, { cursor = "opaque/+%", limit = 1 } },
	{ "agent_list", "GET", "/api/agent", "catalog", nil, { location = location } },
	{ "model_list", "GET", "/api/model", "catalog", nil, { location = location } },
	{ "model_default", "GET", "/api/model/default", "model", nil, { location = location } },
	{ "provider_list", "GET", "/api/provider", "catalog", nil, { location = location } },
	{ "integration_list", "GET", "/api/integration", "catalog", nil, { location = location } },
	{ "integration_get", "GET", "/api/integration/{integrationID}", "integration", nil, { location = location } },
	{ "integration_key", "POST", "/api/integration/{integrationID}/connect/key", "empty", { key = "public-test-only" }, { location = location } },
	{ "integration_oauth_start", "POST", "/api/integration/{integrationID}/connect/oauth", "oauth", { methodID = "oauth" }, { location = location } },
	{ "integration_oauth_status", "GET", "/api/integration/{integrationID}/connect/oauth/{attemptID}", "attempt_status", nil, { location = location } },
	{ "integration_oauth_complete", "POST", "/api/integration/{integrationID}/connect/oauth/{attemptID}/complete", "empty", { code = "public-test-code" }, { location = location } },
	{ "integration_oauth_cancel", "DELETE", "/api/integration/{integrationID}/connect/oauth/{attemptID}", "empty", nil, { location = location } },
	{ "integration_command_start", "POST", "/api/integration/{integrationID}/connect/command", "command_attempt", { methodID = "command" }, { location = location } },
	{ "integration_command_status", "GET", "/api/integration/{integrationID}/connect/command/{attemptID}", "attempt_status", nil, { location = location } },
	{ "integration_command_cancel", "DELETE", "/api/integration/{integrationID}/connect/command/{attemptID}", "empty", nil, { location = location } },
	{ "credential_remove", "DELETE", "/api/credential/{credentialID}", "empty" },
	{ "credential_update", "PATCH", "/api/credential/{credentialID}", "empty", { label = "Renamed account" } },
	{ "credential_activate", "POST", "/api/credential/{credentialID}/activate", "empty" },
	{ "skill_list", "GET", "/api/skill", "catalog", nil, { location = location } },
	{ "plugin_list", "GET", "/api/plugin", "catalog", nil, { location = location } },
	{ "command_list", "GET", "/api/command", "catalog", nil, { location = location } },
	{ "mcp_connect", "POST", "/api/experimental/mcp/{server}/connect", "empty", nil, { location = location } },
	{ "mcp_disconnect", "POST", "/api/experimental/mcp/{server}/disconnect", "empty", nil, { location = location } },
	{ "mcp_list", "GET", "/api/mcp", "catalog", nil, { location = location } },
	{ "config_list", "GET", "/api/config", "array", nil, { location = location } },
	{ "command", "POST", "/api/session/{sessionID}/command", "empty", { name = "review", text = "--staged" } },
	{ "prompt", "POST", "/api/session/{sessionID}/prompt", "inbox", { id = "msg_prompt", text = "Привет", files = {} } },
	{ "session_agent", "POST", "/api/session/{sessionID}/agent", "empty", { agent = "build" } },
	{ "session_model", "POST", "/api/session/{sessionID}/model", "empty", { model = model } },
	{ "interrupt", "POST", "/api/session/{sessionID}/interrupt", "interrupt", nil, { resume = false } },
	{ "inbox_list", "GET", "/api/session/{sessionID}/inbox", "list" },
	{ "inbox_update", "PATCH", "/api/session/{sessionID}/inbox/{inboxID}", "empty", { delivery = "steer" } },
	{ "inbox_delete", "DELETE", "/api/session/{sessionID}/inbox/{inboxID}", "empty" },
	{ "permission_all", "GET", "/api/permission/request", "list" },
	{ "permission_list", "GET", "/api/session/{sessionID}/permission", "list" },
	{ "permission_create", "POST", "/api/session/{sessionID}/permission", "permission", { action = "edit", resources = { "/file" } } },
	{ "permission_get", "GET", "/api/session/{sessionID}/permission/{requestID}", "object" },
	{ "permission_reply", "POST", "/api/session/{sessionID}/permission/{requestID}/reply", "empty", { decision = "once" } },
	{ "form_all", "GET", "/api/form", "list" },
	{ "form_list", "GET", "/api/session/{sessionID}/form", "list" },
	{ "form_get", "GET", "/api/session/{sessionID}/form/{formID}", "object" },
	{ "form_reply", "POST", "/api/session/{sessionID}/form/{formID}/reply", "empty", { answer = { count = 0, enabled = false } } },
	{ "form_cancel", "DELETE", "/api/session/{sessionID}/form/{formID}", "empty" },
	{ "rpc_call", "POST", "/api/rpc/{rpcID}/{method}", "rpc", { input = { sessionID = "s", reviewID = "r" } }, { location = location } },
}
describe("v2 operation wire matrix", function()
	local saved, schedule, v2, wire, response
	local names = { "opencode.client.v2", "opencode.client.http", "opencode.client.transport" }
	before_each(function()
		saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		schedule = vim.schedule; vim.schedule = function(fn) fn() end
		package.loaded["opencode.client.transport"] = { request = function(opts, callback) wire = opts; callback(nil, response) end }
		v2 = require("opencode.client.v2")
		require("opencode.client.http").setup({ host = "127.0.0.1", port = 4096, auth = { password = "public-test-only" } })
	end)
	after_each(function() vim.schedule = schedule; for _, name in ipairs(names) do package.loaded[name] = saved[name] end end)
	it("covers every registered operation and agrees with the pinned HTTP route inventory", function()
		local inventory = vim.json.decode(table.concat(vim.fn.readfile("plans/opencode-v2/reference/contract-inventory.json"), "\n"))
		local covered = {}
		for _, case in ipairs(cases) do
			assert.is_true(vim.tbl_contains(inventory.http_paths[case[3]] or {}, case[2]), case[1])
			covered[case[1]] = true
		end
		-- Only coverage is read from implementation; request expectations above
		-- are checked independently against the published contract inventory.
		for line in io.lines("lua/opencode/client/v2.lua") do
			local name = line:match('^\t([%w_]+) = { "%u+", "/api/')
			if name then assert.is_true(covered[name], "Missing wire case: " .. name) end
		end
	end)
	for _, case in ipairs(cases) do
		it(case[1] .. " encodes its request, accepts the native envelope and preserves HTTP failure", function()
			local args = { path = {}, body = case[5], query = case[6] }
			local route = case[3]:gsub("{([^}]+)}", function(key) args.path[key] = key .. "/%"; return key .. "%2F%25" end)
			local body, status = responses[case[4]], case[4] == "empty" and 204 or 200
			response = { status = status, headers = { ["content-type"] = "application/json" }, body = body == false and "" or vim.json.encode(body) }
			local callbacks, result = 0
			local function invoke()
				v2.request(case[1], args, function(err, data, meta) callbacks = callbacks + 1; result = { err = err, data = data, meta = meta } end)
			end
			invoke()
			assert.equals(1, callbacks); assert.is_nil(result.err, case[1]); assert.equals(status, result.meta.status)
			assert.equals(case[2], wire.method); assert.equals(route, wire.path:match("^[^?]+"))
			if args.query and args.query.location then assert.truthy(wire.path:find("location%%5Bdirectory%%5D=%%2Fproject%%20space")) end
			if case[2] == "POST" or case[2] == "PATCH" then assert.same(args.body or vim.empty_dict(), vim.json.decode(wire.body)) end
			if case[4] == "empty" then assert.is_true(result.data) end
			if case[4] == "page" then assert.equals("opaque/+%", result.meta.cursor.previous) end
			if case[4] == "interrupt" then assert.is_false(result.data.interrupted) end
			response = { status = 401, headers = { ["content-type"] = "application/json" }, body = vim.json.encode({ _tag = "UnauthorizedError", message = "Authentication required" }) }
			invoke(); assert.equals(2, callbacks)
			assert.is_nil(result.data); assert.equals(401, result.err.status); assert.equals("UnauthorizedError", result.err.code); assert.is_false(result.err.retryable)
		end)
	end
end)
