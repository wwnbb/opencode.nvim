-- Wire-level route coverage. Source: the pinned contract inventory and recorded
-- 2.0.11 envelopes. Facade semantics have separate send/auth/history/review specs.
local location = { directory = "/project space" }
local session = { id = "s", location = location }
local model = { providerID = "provider", id = "model" }
local time = { created = 100, expires = 200 }
local shell = { id = "sh_1", status = "running", command = "echo test", cwd = location.directory,
	shell = "/bin/sh", file = "/tmp/output", metadata = { sessionID = "s" }, time = { started = 100 } }
local terminal = { id = "pty_one", sessionID = "s", title = "Terminal", command = "/bin/sh", args = {}, cwd = location.directory,
	status = "running", pid = 10, foregroundProcess = vim.NIL, size = { cols = 80, rows = 24 }, output = { head = 0, tail = 4 } }
local responses = {
	empty = false,
	info = { version = "2.0.11", pid = 1, urls = {}, paths = { tmp = "/tmp" } },
	pairing = { code = "public-test-code", expires_in = 300 },
	plugins = { data = { { id = "plugin", source = { type = "package", target = "test-plugin", version = "1.0.0", outdated = true }, state = { status = "active" } } }, location = location },
	vcs_info = { data = { provider = "git", branch = { current = "feature", default = "main" } }, location = location },
	vcs_base = { data = { name = "main", ref = "main", source = "default" }, location = location },
	session = { data = session },
	transfer = { data = { info = session, messages = { { id = "msg_1", type = "user", text = "Hello" } } } },
	page = { data = {}, cursor = { next = vim.NIL, previous = "opaque/+%" } },
	list = { data = {} },
	object = { data = { marker = false } },
	catalog = { data = {}, location = location },
	model = { data = model, location = location },
	integration = { data = { id = "integration", methods = {} }, location = location },
	oauth = { data = { attemptID = "attempt", mode = "code", url = "https://example.invalid", instructions = "test", time = time }, location = location },
	command_attempt = { data = { attemptID = "attempt", time = time }, location = location },
	shell_list = { data = { shell }, location = location },
	shell_info = { data = shell, location = location },
	shell_output = { data = { output = "Привет", cursor = 12, size = 12, truncated = false }, location = location },
	attempt_status = { data = { status = "pending", time = time }, location = location },
	array = {},
	location = { directory = "/project space", project = { id = "project", directory = "/project space", canonical = "/project space" } },
	projects = { { id = "project", canonical = "/project space" } },
	worktrees = { { directory = "/project tree" } },
	worktree = { directory = "/project tree" },
	pty_list = { data = { terminal } },
	pty_info = { data = terminal },
	pty_snapshot = { data = { info = terminal, text = "test", checkpoint = "dGVzdA==", cursor = { x = 4, y = 0 } } },
	inbox = { data = { id = "inbox", sessionID = "s", type = "prompt", payload = { attachments = {} } } },
	generated_text = { data = { text = "Transient answer" } },
	interrupt = { interrupted = false },
	permission = { data = { id = "request", effect = "ask" } },
	rpc = { output = { protocolVersion = 2, review = true } },
}
-- Operation, HTTP method, native path, envelope, optional request body/query.
local cases = {
	{ "info", "GET", "/api/info", "info" },
	{ "server_pair", "POST", "/api/pair", "pairing" },
	{ "vcs_info", "GET", "/api/vcs", "vcs_info", nil, { location = location } },
	{ "vcs_base", "GET", "/api/vcs/base", "vcs_base", nil, { location = location } },
	{ "vcs_branches", "GET", "/api/vcs/branch", "catalog", nil, { location = location, search = "feature", limit = 100 } },
	{ "vcs_diff", "GET", "/api/vcs/diff", "catalog", nil, { location = location, mode = "committed", base = "main", context = 12 } },
	{ "location_get", "GET", "/api/location", "location", nil, { location = location } },
	{ "project_list", "GET", "/api/project", "projects" },
	{ "worktree_list", "GET", "/api/worktree", "worktrees", nil, { projectID = "project" } },
	{ "worktree_create", "POST", "/api/worktree", "worktree", { projectID = "project", name = "feature" } },
	{ "worktree_remove", "DELETE", "/api/worktree", "empty", { projectID = "project", directory = "/project tree", force = false } },
	{ "worktree_refresh", "POST", "/api/worktree/refresh", "empty", { projectID = "project" } },
	{ "location_reload", "POST", "/api/location/reload", "empty", nil, { location = location } },
	{ "session_list", "GET", "/api/session", "page", nil, { parentID = vim.NIL, limit = 1 } },
	{ "session_stats", "GET", "/api/experimental/session/stats", "object" },
	{ "session_create", "POST", "/api/session", "session", { location = location, model = model } },
	{ "session_get", "GET", "/api/session/{sessionID}", "session" },
	{ "session_update", "PATCH", "/api/session/{sessionID}", "empty", { title = "renamed" } },
	{ "session_move", "POST", "/api/session/{sessionID}/move", "empty", { directory = "/project tree" } },
	{ "session_view", "POST", "/api/session/{sessionID}/view", "empty", { idle = 123 } },
	{ "pty_list", "GET", "/api/experimental/session/{sessionID}/terminal", "pty_list" },
	{ "pty_create", "POST", "/api/experimental/session/{sessionID}/terminal", "pty_info", { args = {}, env = vim.empty_dict(), title = "Terminal", cwd = location.directory } },
	{ "pty_get", "GET", "/api/experimental/persistent-pty/{ptyID}", "pty_info" },
	{ "pty_update", "PUT", "/api/experimental/persistent-pty/{ptyID}", "pty_info", { size = { cols = 80, rows = 24 }, attachmentID = "attachment" } },
	{ "pty_snapshot", "GET", "/api/experimental/persistent-pty/{ptyID}/snapshot", "pty_snapshot" },
	{ "pty_remove", "DELETE", "/api/experimental/persistent-pty/{ptyID}", "empty" },
	{ "session_delete", "DELETE", "/api/session/{sessionID}", "empty" },
	{ "session_active", "GET", "/api/session/active", "object" },
	{ "session_shell", "POST", "/api/session/{sessionID}/shell", "empty", { command = "echo test" } },
	{ "session_background", "POST", "/api/session/{sessionID}/background", "empty" },
	{ "session_environment", "PUT", "/api/session/{sessionID}/environment", "empty", { variables = { TEST = "value" } } },
	{ "shell_list", "GET", "/api/shell", "shell_list", nil, { location = location } },
	{ "shell_get", "GET", "/api/shell/{id}", "shell_info", nil, { location = location } },
	{ "shell_output", "GET", "/api/shell/{id}/output", "shell_output", nil, { location = location, cursor = 0, limit = 65536 } },
	{ "shell_remove", "DELETE", "/api/shell/{id}", "empty", nil, { location = location } },
	{ "session_fork", "POST", "/api/session/{sessionID}/fork", "session", { before = "message" } },
	{ "session_export", "GET", "/api/experimental/session/{sessionID}/export", "transfer", nil, { sanitize = true } },
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
	{ "plugin_list", "GET", "/api/plugin", "plugins", nil, { location = location } },
	{ "plugin_check", "POST", "/api/plugin/check", "plugins", { target = "test-plugin" }, { location = location } },
	{ "plugin_update", "POST", "/api/plugin/update", "empty", { targets = { "test-plugin" } }, { location = location } },
	{ "command_list", "GET", "/api/command", "catalog", nil, { location = location } },
	{ "mcp_connect", "POST", "/api/experimental/mcp/{server}/connect", "empty", nil, { location = location } },
	{ "mcp_disconnect", "POST", "/api/experimental/mcp/{server}/disconnect", "empty", nil, { location = location } },
	{ "mcp_list", "GET", "/api/mcp", "catalog", nil, { location = location } },
	{ "config_list", "GET", "/api/config", "array", nil, { location = location } },
	{ "command", "POST", "/api/session/{sessionID}/command", "empty", { name = "review", text = "--staged" } },
	{ "prompt", "POST", "/api/session/{sessionID}/prompt", "inbox", { id = "msg_prompt", text = "Привет", files = {} } },
	{ "generate", "POST", "/api/session/{sessionID}/generate", "generated_text", { prompt = "Quick question" } },
	{ "completion", "POST", "/api/experimental/generate", "generated_text", { prompt = "Complete at cursor", model = model } },
	{ "session_agent", "POST", "/api/session/{sessionID}/agent", "empty", { agent = "build" } },
	{ "session_model", "POST", "/api/session/{sessionID}/model", "empty", { model = model } },
	{ "interrupt", "POST", "/api/session/{sessionID}/interrupt", "interrupt", nil, { resume = false } },
	{ "session_wait", "POST", "/api/experimental/session/{sessionID}/wait", "empty" },
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
describe("HTTP operation wire matrix", function()
	local saved, schedule, api, wire, response
	local names = { "opencode.client.api", "opencode.client.http", "opencode.client.transport" }
	before_each(function()
		saved = {}; for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		schedule = vim.schedule; vim.schedule = function(fn) fn() end
		package.loaded["opencode.client.transport"] = { request = function(opts, callback) wire = opts; callback(nil, response) end }
		api = require("opencode.client.api")
		require("opencode.client.http").setup({ host = "127.0.0.1", port = 4096, auth = { password = "public-test-only" } })
	end)
	after_each(function() vim.schedule = schedule; for _, name in ipairs(names) do package.loaded[name] = saved[name] end end)
	it("covers every registered operation and agrees with the pinned HTTP route inventory", function()
		local inventory = vim.json.decode(table.concat(vim.fn.readfile("tests/contracts/v2-http-events.json"), "\n"))
		local covered = {}
		for _, case in ipairs(cases) do
			assert.is_true(vim.tbl_contains(inventory.http_paths[case[3]] or {}, case[2]), case[1])
			covered[case[1]] = true
		end
		-- Only coverage is read from implementation; request expectations above
		-- are checked independently against the published contract inventory.
		for line in io.lines("lua/opencode/client/api.lua") do
			local name = line:match('^\t([%w_]+) = { "%u+", "/api/')
			if name then assert.is_true(covered[name], "Missing wire case: " .. name) end
		end
	end)
	for _, case in ipairs(cases) do
		it(case[1] .. " encodes its request and accepts the native envelope", function()
			local args = { path = {}, body = case[5], query = case[6] }
			local route = case[3]:gsub("{([^}]+)}", function(key) args.path[key] = key .. "/%"; return key .. "%2F%25" end)
			local body, status = responses[case[4]], case[4] == "empty" and 204 or 200
			response = { status = status, headers = { ["content-type"] = "application/json" }, body = body == false and "" or vim.json.encode(body) }
			local callbacks, result = 0
			local function invoke()
				api.request(case[1], args, function(err, data, meta) callbacks = callbacks + 1; result = { err = err, data = data, meta = meta } end)
			end
			invoke()
			assert.equals(1, callbacks); assert.is_nil(result.err, case[1]); assert.equals(status, result.meta.status)
			assert.equals(case[2], wire.method); assert.equals(route, wire.path:match("^[^?]+"))
			if args.query and args.query.location then assert.truthy(wire.path:find("location%%5Bdirectory%%5D=%%2Fproject%%20space")) end
			if case[2] == "POST" or case[2] == "PATCH" or case[2] == "PUT" or (case[2] == "DELETE" and args.body ~= nil) then
				assert.same(args.body or vim.empty_dict(), vim.json.decode(wire.body))
			end
			if case[4] == "empty" then assert.is_true(result.data) end
			if case[4] == "page" then assert.equals("opaque/+%", result.meta.cursor.previous) end
			if case[4] == "interrupt" then assert.is_false(result.data.interrupted) end
			if case[4] == "generated_text" then assert.equals("Transient answer", result.data) end
		end)
	end
	it("preserves HTTP failures across GET, POST, PATCH and DELETE", function()
		response = { status = 401, headers = { ["content-type"] = "application/json" }, body = vim.json.encode({ _tag = "UnauthorizedError", message = "Authentication required" }) }
		for _, operation in ipairs({ "session_get", "session_create", "session_update", "session_delete" }) do
			local callbacks = 0
			api.request(operation, { path = { sessionID = "s" } }, function(err, data, meta)
				callbacks = callbacks + 1
				assert.is_nil(data)
				assert.equals(401, err.status)
				assert.equals("UnauthorizedError", err.code)
				assert.is_false(err.retryable)
				assert.equals(401, meta.status)
			end)
			assert.equals(1, callbacks)
		end
	end)
end)
