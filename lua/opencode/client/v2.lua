-- OpenCode 2 wire contracts. No state mutation belongs in this module.
local M = {}
local http = require("opencode.client.http")
local schedule_callback = require("opencode.util.schedule").schedule_callback

local operations = {
	rpc_call = { "POST", "/api/rpc/{rpcID}/{method}", "rpc" },
	info = { "GET", "/api/info", "info" },
	location_reload = { "POST", "/api/location/reload", "empty" },
	session_fork = { "POST", "/api/session/{sessionID}/fork", "session" },
	session_diff = { "GET", "/api/session/{sessionID}/diff", "list" },
	session_compact = { "POST", "/api/session/{sessionID}/compact", "inbox" },
	revert_stage = { "POST", "/api/session/{sessionID}/revert/stage", "object" },
	revert_clear = { "DELETE", "/api/session/{sessionID}/revert", "empty" },
	revert_commit = { "POST", "/api/session/{sessionID}/revert/commit", "empty" },
	session_list = { "GET", "/api/session", "page" },
	session_create = { "POST", "/api/session", "session" },
	session_get = { "GET", "/api/session/{sessionID}", "session" },
	session_update = { "PATCH", "/api/session/{sessionID}", "empty" },
	session_delete = { "DELETE", "/api/session/{sessionID}", "empty" },
	session_active = { "GET", "/api/session/active", "object" },
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
	plugin_list = { "GET", "/api/plugin", "catalog" },
	command_list = { "GET", "/api/command", "catalog" },
	mcp_connect = { "POST", "/api/experimental/mcp/{server}/connect", "empty" },
	mcp_disconnect = { "POST", "/api/experimental/mcp/{server}/disconnect", "empty" },
	mcp_list = { "GET", "/api/mcp", "catalog" },
	config_list = { "GET", "/api/config", "array" },
	command = { "POST", "/api/session/{sessionID}/command", "empty" },
	prompt = { "POST", "/api/session/{sessionID}/prompt", "inbox" },
	session_agent = { "POST", "/api/session/{sessionID}/agent", "empty" },
	session_model = { "POST", "/api/session/{sessionID}/model", "empty" },
	interrupt = { "POST", "/api/session/{sessionID}/interrupt", "interrupt" },
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

function M.encode_segment(value)
	return (tostring(value):gsub("[^A-Za-z0-9%-_.~]", function(c)
		return string.format("%%%02X", c:byte())
	end))
end

local function object(value)
	return type(value) == "table" and not vim.islist(value)
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
	if shape == "array" then
		if type(body) ~= "table" or not vim.islist(body) then return nil, "Invalid v2 array response" end
		return body
	end
	if shape == "interrupt" then
		if not object(body) or type(body.interrupted) ~= "boolean" then return nil, "Invalid interrupt response" end
		return body
	end
	if not object(body) or body.data == nil then return nil, "Missing v2 response data" end
	local data = body.data
	if shape == "permission_effect" then
		if not object(data) or type(data.id) ~= "string" or not vim.tbl_contains({ "allow", "ask", "deny" }, data.effect) then
			return nil, "Invalid permission evaluation response"
		end
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
	elseif shape == "catalog" or shape == "nullable_catalog_object" or shape == "catalog_object"
		or shape == "attempt" or shape == "command_attempt" or shape == "attempt_status" then
		if not object(body.location) or type(body.location.directory) ~= "string" then
			return nil, "Missing v2 response location"
		end
		meta.location = body.location
		if shape == "catalog" and (type(data) ~= "table" or not vim.islist(data)) then
			return nil, "Invalid v2 catalog response"
		end
		if shape == "nullable_catalog_object" and data ~= vim.NIL and not object(data) then
			return nil, "Invalid v2 default model response"
		end
		if shape ~= "catalog" and shape ~= "nullable_catalog_object" and not object(data) then
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
	if method == "get" or method == "delete" then
		http[method](path, done, opts)
	else
		http[method](path, args.body or vim.empty_dict(), done, opts)
	end
end

return M
