-- OpenCode 2 wire contracts. No state mutation belongs in this module.
local M = {}
local http = require("opencode.client.http")
local schedule_callback = require("opencode.util.schedule").schedule_callback

local operations = {
	rpc_call = { "POST", "/api/rpc/{rpcID}/{method}", "rpc" },
	info = { "GET", "/api/info", "info" },
	server_pair = { "POST", "/api/pair", "pairing" },
	vcs_info = { "GET", "/api/vcs", "catalog_object" },
	vcs_base = { "GET", "/api/vcs/base", "nullable_catalog_object" },
	vcs_branches = { "GET", "/api/vcs/branch", "catalog" },
	vcs_diff = { "GET", "/api/vcs/diff", "catalog" },
	project_list = { "GET", "/api/project", "projects" },
	location_get = { "GET", "/api/location", "location" },
	worktree_list = { "GET", "/api/worktree", "worktrees" },
	worktree_create = { "POST", "/api/worktree", "worktree" },
	worktree_remove = { "DELETE", "/api/worktree", "empty" },
	worktree_refresh = { "POST", "/api/worktree/refresh", "empty" },
	location_reload = { "POST", "/api/location/reload", "empty" },
	session_fork = { "POST", "/api/session/{sessionID}/fork", "session" },
	session_export = { "GET", "/api/experimental/session/{sessionID}/export", "transfer" },
	session_diff = { "GET", "/api/session/{sessionID}/diff", "list" },
	session_compact = { "POST", "/api/session/{sessionID}/compact", "inbox" },
	revert_stage = { "POST", "/api/session/{sessionID}/revert/stage", "object" },
	revert_clear = { "DELETE", "/api/session/{sessionID}/revert", "empty" },
	revert_commit = { "POST", "/api/session/{sessionID}/revert/commit", "empty" },
	session_list = { "GET", "/api/session", "page" },
	session_stats = { "GET", "/api/experimental/session/stats", "object" },
	session_create = { "POST", "/api/session", "session" },
	session_get = { "GET", "/api/session/{sessionID}", "session" },
	session_update = { "PATCH", "/api/session/{sessionID}", "empty" },
	session_move = { "POST", "/api/session/{sessionID}/move", "empty" },
	session_view = { "POST", "/api/session/{sessionID}/view", "empty" },
	pty_list = { "GET", "/api/experimental/session/{sessionID}/terminal", "pty_list" },
	pty_create = { "POST", "/api/experimental/session/{sessionID}/terminal", "pty_info" },
	pty_get = { "GET", "/api/experimental/persistent-pty/{ptyID}", "pty_info" },
	pty_update = { "PUT", "/api/experimental/persistent-pty/{ptyID}", "pty_info" },
	pty_snapshot = { "GET", "/api/experimental/persistent-pty/{ptyID}/snapshot", "pty_snapshot" },
	pty_remove = { "DELETE", "/api/experimental/persistent-pty/{ptyID}", "empty" },
	session_delete = { "DELETE", "/api/session/{sessionID}", "empty" },
	session_active = { "GET", "/api/session/active", "object" },
	session_shell = { "POST", "/api/session/{sessionID}/shell", "empty" },
	session_background = { "POST", "/api/session/{sessionID}/background", "empty" },
	session_environment = { "PUT", "/api/session/{sessionID}/environment", "empty" },
	shell_list = { "GET", "/api/shell", "shell_list" },
	shell_get = { "GET", "/api/shell/{id}", "shell_info" },
	shell_output = { "GET", "/api/shell/{id}/output", "shell_output" },
	shell_remove = { "DELETE", "/api/shell/{id}", "empty" },
	message_list = { "GET", "/api/session/{sessionID}/message", "page" },
	agent_list = { "GET", "/api/agent", "catalog" },
	model_list = { "GET", "/api/model", "catalog" },
	model_default = { "GET", "/api/model/default", "nullable_catalog_object" },
	provider_list = { "GET", "/api/provider", "catalog" },
	integration_list = { "GET", "/api/integration", "catalog" },
	integration_get = { "GET", "/api/integration/{integrationID}", "catalog_object" },
	integration_key = { "POST", "/api/integration/{integrationID}/connect/key", "empty" },
	integration_oauth_start = { "POST", "/api/integration/{integrationID}/connect/oauth", "attempt" },
	integration_oauth_status = { "GET", "/api/integration/{integrationID}/connect/oauth/{attemptID}", "attempt_status" },
	integration_oauth_complete = { "POST", "/api/integration/{integrationID}/connect/oauth/{attemptID}/complete", "empty" },
	integration_oauth_cancel = { "DELETE", "/api/integration/{integrationID}/connect/oauth/{attemptID}", "empty" },
	integration_command_start = { "POST", "/api/integration/{integrationID}/connect/command", "command_attempt" },
	integration_command_status = { "GET", "/api/integration/{integrationID}/connect/command/{attemptID}", "attempt_status" },
	integration_command_cancel = { "DELETE", "/api/integration/{integrationID}/connect/command/{attemptID}", "empty" },
	credential_remove = { "DELETE", "/api/credential/{credentialID}", "empty" },
	credential_update = { "PATCH", "/api/credential/{credentialID}", "empty" },
	credential_activate = { "POST", "/api/credential/{credentialID}/activate", "empty" },
	skill_list = { "GET", "/api/skill", "catalog" },
	plugin_list = { "GET", "/api/plugin", "plugins" },
	plugin_check = { "POST", "/api/plugin/check", "plugins" },
	plugin_update = { "POST", "/api/plugin/update", "empty" },
	command_list = { "GET", "/api/command", "catalog" },
	mcp_connect = { "POST", "/api/experimental/mcp/{server}/connect", "empty" },
	mcp_disconnect = { "POST", "/api/experimental/mcp/{server}/disconnect", "empty" },
	mcp_list = { "GET", "/api/mcp", "catalog" },
	config_list = { "GET", "/api/config", "array" },
	command = { "POST", "/api/session/{sessionID}/command", "empty" },
	prompt = { "POST", "/api/session/{sessionID}/prompt", "inbox" },
	generate = { "POST", "/api/session/{sessionID}/generate", "generated_text" },
	completion = { "POST", "/api/experimental/generate", "generated_text" },
	session_agent = { "POST", "/api/session/{sessionID}/agent", "empty" },
	session_model = { "POST", "/api/session/{sessionID}/model", "empty" },
	interrupt = { "POST", "/api/session/{sessionID}/interrupt", "interrupt" },
	session_wait = { "POST", "/api/experimental/session/{sessionID}/wait", "empty" },
	inbox_list = { "GET", "/api/session/{sessionID}/inbox", "list" },
	inbox_update = { "PATCH", "/api/session/{sessionID}/inbox/{inboxID}", "empty" },
	inbox_delete = { "DELETE", "/api/session/{sessionID}/inbox/{inboxID}", "empty" },
	permission_all = { "GET", "/api/permission/request", "list" },
	permission_list = { "GET", "/api/session/{sessionID}/permission", "list" },
	permission_create = { "POST", "/api/session/{sessionID}/permission", "permission_effect" },
	permission_get = { "GET", "/api/session/{sessionID}/permission/{requestID}", "object" },
	permission_reply = { "POST", "/api/session/{sessionID}/permission/{requestID}/reply", "empty" },
	form_all = { "GET", "/api/form", "list" },
	form_list = { "GET", "/api/session/{sessionID}/form", "list" },
	form_get = { "GET", "/api/session/{sessionID}/form/{formID}", "object" },
	form_reply = { "POST", "/api/session/{sessionID}/form/{formID}/reply", "empty" },
	form_cancel = { "DELETE", "/api/session/{sessionID}/form/{formID}", "empty" },
}

M.encode_segment = require("opencode.util.text").encode_uri_component

local function object(value)
	return type(value) == "table" and not vim.islist(value)
end

local function integer(value, positive)
	return type(value) == "number" and value >= (positive and 1 or 0) and value <= 9007199254740991 and value % 1 == 0
end

function M.validate_pty(info)
	if not object(info) or type(info.id) ~= "string" or not info.id:match("^pty") or type(info.sessionID) ~= "string"
		or type(info.title) ~= "string" or type(info.command) ~= "string" or not require("opencode.util.path").is_absolute(info.cwd)
		or not vim.tbl_contains({ "running", "exited" }, info.status) or not integer(info.pid)
		or type(info.args) ~= "table" or not vim.islist(info.args) or not object(info.size)
		or not integer(info.size.cols, true) or not integer(info.size.rows, true) or info.size.cols > 65535 or info.size.rows > 65535
		or not object(info.output) or not integer(info.output.head) or not integer(info.output.tail) or info.output.head > info.output.tail then
		return "Invalid persistent PTY response"
	end
end

function M.validate_info(info)
	if not object(info) or type(info.version) ~= "string" or type(info.pid) ~= "number"
		or type(info.urls) ~= "table" or not object(info.paths) or type(info.paths.tmp) ~= "string" then
		return "Invalid OpenCode /api/info response"
	end
	local major, minor, patch = info.version:match("^(%d+)%.(%d+)%.(%d+)$")
	if tonumber(major) ~= 2 or not minor or (tonumber(minor) == 0 and tonumber(patch) < 11) then
		return "OpenCode 2.0.11 or newer 2.x is required (server: " .. info.version .. ")"
	end
end

-- Preserve the original DTO fields; directory is the existing internal alias.
function M.session(info)
	if not object(info) or type(info.id) ~= "string" or not object(info.location)
		or type(info.location.directory) ~= "string" then
		return nil, "Invalid v2 session response"
	end
	local value = vim.deepcopy(info)
	value.directory = info.location.directory
	value.revert = info.revert or vim.NIL
	return value
end

local function decode(shape, body, meta)
	if shape == "rpc" then
		if not object(body) or body.output == nil then return nil, "Missing RPC output" end
		return body.output
	end
	if shape == "empty" then
		if meta.status ~= 204 then return nil, "Expected HTTP 204" end
		return true
	end
	if shape == "info" then
		local err = M.validate_info(body)
		if err then return nil, err end
		return body
	end
	if shape == "location" then
		local path = require("opencode.util.path")
		if not object(body) or not path.is_absolute(body.directory) or not object(body.project)
			or type(body.project.id) ~= "string" or not path.is_absolute(body.project.directory)
			or not path.is_absolute(body.project.canonical) then return nil, "Invalid location response" end
		return body
	end
	if shape == "pairing" then
		if not object(body) or type(body.code) ~= "string" or not body.code:match("^[%w_%-]+$")
			or type(body.expires_in) ~= "number" or body.expires_in <= 0 or body.expires_in >= math.huge
			or body.expires_in % 1 ~= 0 then return nil, "Invalid server pairing response" end
		return body
	end
	if shape == "worktree" then
		if not object(body) or not require("opencode.util.path").is_absolute(body.directory) then return nil, "Invalid worktree response" end
		return body
	end
	if shape == "array" or shape == "projects" or shape == "worktrees" then
		if type(body) ~= "table" or not vim.islist(body) then return nil, "Invalid v2 array response" end
		if shape ~= "array" then
			local path = require("opencode.util.path")
			for _, entry in ipairs(body) do
				if not object(entry) or (shape == "projects" and (type(entry.id) ~= "string" or not path.is_absolute(entry.canonical)))
					or (shape == "worktrees" and not path.is_absolute(entry.directory)) then return nil, "Invalid " .. shape .. " entry" end
			end
		end
		return body
	end
	if shape == "interrupt" then
		if not object(body) or type(body.interrupted) ~= "boolean" then return nil, "Invalid interrupt response" end
		return body
	end
	if not object(body) or body.data == nil then return nil, "Missing v2 response data" end
	local data = body.data
	if shape == "pty_list" or shape == "pty_info" or shape == "pty_snapshot" then
		if shape == "pty_list" and (type(data) ~= "table" or not vim.islist(data)) then return nil, "Invalid persistent PTY list" end
		if shape == "pty_snapshot" then
			if not object(data) or type(data.text) ~= "string" or type(data.checkpoint) ~= "string" or #data.checkpoint > 12 * 1024 * 1024
				or not object(data.cursor) or not integer(data.cursor.x) or not integer(data.cursor.y) then return nil, "Invalid persistent PTY snapshot" end
		end
		for _, info in ipairs(shape == "pty_list" and data or { shape == "pty_snapshot" and data.info or data }) do
			local err = M.validate_pty(info); if err then return nil, err end
		end
		return data
	end
	if shape == "shell_list" or shape == "shell_info" or shape == "shell_output" then
		if not object(body.location) or not require("opencode.util.path").is_absolute(body.location.directory) then return nil, "Missing shell location" end
		meta.location = body.location
		if shape == "shell_output" then
			local function count(value) return type(value) == "number" and value >= 0 and value < math.huge and value % 1 == 0 end
			if not object(data) or type(data.output) ~= "string" or not count(data.cursor) or not count(data.size)
				or data.cursor > data.size or type(data.truncated) ~= "boolean" then return nil, "Invalid shell output" end
		else
			if shape == "shell_list" and (type(data) ~= "table" or not vim.islist(data)) then return nil, "Invalid shell list" end
			for _, info in ipairs(shape == "shell_list" and data or { data }) do
				if not object(info) or type(info.id) ~= "string" or not info.id:match("^sh_") or type(info.command) ~= "string"
					or type(info.cwd) ~= "string" or type(info.shell) ~= "string" or type(info.file) ~= "string"
					or not object(info.metadata) or not object(info.time) or type(info.time.started) ~= "number"
					or not vim.tbl_contains({ "running", "exited", "timeout", "killed" }, info.status) then return nil, "Invalid shell info" end
			end
		end
		return data
	end
	if shape == "permission_effect" then
		if not object(data) or type(data.id) ~= "string" or not vim.tbl_contains({ "allow", "ask", "deny" }, data.effect) then
			return nil, "Invalid permission evaluation response"
		end
	elseif shape == "generated_text" then
		if not object(data) or type(data.text) ~= "string" then
			return nil, "Invalid session generation response"
		end
		return data.text
	elseif shape == "inbox" then
		if not object(data) or type(data.id) ~= "string" or type(data.sessionID) ~= "string"
			or type(data.type) ~= "string" or not object(data.payload) then return nil, "Invalid prompt admission" end
	elseif shape == "list" then
		if type(data) ~= "table" or not vim.islist(data) then return nil, "Invalid v2 list response" end
	elseif shape == "page" then
		if type(data) ~= "table" or not vim.islist(data) or not object(body.cursor) then
			return nil, "Invalid v2 page response"
		end
		meta.cursor = body.cursor
	elseif shape == "transfer" then
		if not object(data) or not object(data.info) or type(data.info.id) ~= "string"
			or not object(data.info.location) or type(data.info.location.directory) ~= "string"
			or type(data.messages) ~= "table" or not vim.islist(data.messages) then
			return nil, "Invalid v2 session export response"
		end
		for _, message in ipairs(data.messages) do
			if not object(message) or type(message.id) ~= "string" or type(message.type) ~= "string" then
				return nil, "Invalid v2 session export message"
			end
		end
	elseif shape == "catalog" or shape == "plugins" or shape == "nullable_catalog_object" or shape == "catalog_object"
		or shape == "attempt" or shape == "command_attempt" or shape == "attempt_status" then
		if not object(body.location) or type(body.location.directory) ~= "string" then
			return nil, "Missing v2 response location"
		end
		meta.location = body.location
		if (shape == "catalog" or shape == "plugins") and (type(data) ~= "table" or not vim.islist(data)) then
			return nil, "Invalid v2 catalog response"
		end
		if shape == "plugins" then
			for _, plugin in ipairs(data) do
				if not object(plugin) or not object(plugin.source) or not object(plugin.state)
					or (plugin.id ~= nil and type(plugin.id) ~= "string")
					or not vim.tbl_contains({ "builtin", "package", "local", "sdk" }, plugin.source.type)
					or not vim.tbl_contains({ "active", "failed" }, plugin.state.status)
					or (plugin.state.status == "failed" and type(plugin.state.error) ~= "string")
					or (plugin.source.type == "package" and type(plugin.source.target) ~= "string")
					or (plugin.source.type == "local" and type(plugin.source.path) ~= "string")
					or (plugin.source.outdated ~= nil and plugin.source.outdated ~= true)
					or (plugin.source.updating ~= nil and plugin.source.updating ~= true)
					or (plugin.source.version ~= nil and type(plugin.source.version) ~= "string") then
					return nil, "Invalid server plugin response"
				end
			end
		end
		if shape == "nullable_catalog_object" and data ~= vim.NIL and not object(data) then
			return nil, "Invalid v2 default model response"
		end
		if shape ~= "catalog" and shape ~= "plugins" and shape ~= "nullable_catalog_object" and not object(data) then
			return nil, "Invalid v2 catalog object"
		end
		if shape == "attempt" or shape == "command_attempt" or shape == "attempt_status" then
			if not object(data.time) or type(data.time.expires) ~= "number" or type(data.time.created) ~= "number" then
				return nil, "Invalid integration attempt time"
			end
			if shape == "attempt_status" then
				if not vim.tbl_contains({ "pending", "complete", "failed", "expired" }, data.status) then
					return nil, "Invalid integration attempt status"
				end
			elseif type(data.attemptID) ~= "string" or data.attemptID == "" then
				return nil, "Missing integration attempt ID"
			end
			if shape == "attempt" and (type(data.url) ~= "string" or type(data.instructions) ~= "string"
				or not vim.tbl_contains({ "auto", "code" }, data.mode)) then return nil, "Invalid OAuth attempt" end
		end
	elseif shape == "session" then
		return M.session(data)
	elseif shape == "object" and not object(data) then
		return nil, "Invalid v2 object response"
	end
	return data
end

-- Metadata (status/headers/cursor/location) is the third callback argument.
function M.request(name, args, callback)
	args = args or {}
	local operation = assert(operations[name], "Unknown v2 operation: " .. tostring(name))
	local invalid
	local path = operation[2]:gsub("{([^}]+)}", function(key)
		local value = args.path and args.path[key]
		if type(value) ~= "string" or value == "" then invalid = key end
		return M.encode_segment(value)
	end)
	if invalid then
		schedule_callback(callback, { code = "invalid_request", message = "Missing " .. invalid, retryable = false })
		return
	end
	local opts = { query = args.query, timeout = args.timeout }
	local function done(err, body, meta)
		if err then callback(err, nil, meta); return end
		meta = meta or {}
		local value, decode_err = decode(operation[3], body, meta)
		if decode_err then
			callback({ status = meta.status, code = "incompatible_response", message = decode_err, retryable = false }, nil, meta)
			return
		end
		callback(nil, value, meta)
	end
	local method = operation[1]:lower()
	if method == "delete" then opts.body = args.body end
	if method == "get" or method == "delete" then
		return http[method](path, done, opts)
	else
		return http[method](path, args.body or vim.empty_dict(), done, opts)
	end
end

return M
