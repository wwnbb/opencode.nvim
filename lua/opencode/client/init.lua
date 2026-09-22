-- opencode.nvim - Client module (HTTP + SSE)
-- Combined interface for OpenCode server communication

local M = {}

local http = require("opencode.client.http")
local sse = require("opencode.client.sse")
local v2 = require("opencode.client.v2")
local catalogs = require("opencode.protocol.v2.catalogs")
local configuration_generation = 0

---@param directory? string
---@return string|nil
local function normalize_directory(directory)
	local dir = directory
	if not dir or dir == "" then
		dir = vim.fn.getcwd()
	end

	local absolute = vim.fn.fnamemodify(dir, ":p")
	if absolute == "" then
		return nil
	end

	if vim.fs and vim.fs.normalize then
		return vim.fs.normalize(absolute)
	end

	return absolute
end

---@param segment string
---@return string
local function encode_path_segment(segment)
	local encoded = tostring(segment):gsub("[^A-Za-z0-9%-_.~]", function(c)
		return string.format("%%%02X", c:byte())
	end)
	return encoded
end

-- Configure both clients
---@param opts table Configuration options
function M.setup(opts)
	configuration_generation = configuration_generation + 1
	opts = opts or {}

	local config = {
		host = opts.host or "localhost",
		port = opts.port,
		auth = opts.auth or { username = "opencode", password = nil },
		timeout = opts.timeout or 30000,
	}

	http.setup(config)
	sse.setup(vim.tbl_deep_extend("force", config, {
		reconnect = opts.reconnect ~= false,
		reconnect_delay = opts.reconnect_delay or 5000,
		max_reconnects = opts.max_reconnects or 5,
	}))
end

-- HTTP API shortcuts

-- Health check
---@param callback function(err, data)
function M.health(callback)
	http.health(callback)
end

-- Get all sessions
---@param opts? table { roots?, directory?, search?, limit?, start? }
---@param callback function(err, sessions)
function M.list_sessions(opts, callback)
	if type(opts) == "function" then
		-- backwards compatibility: list_sessions(callback)
		callback = opts
		opts = nil
	end
	local query = vim.deepcopy(opts or {})
	if query.roots then query.parentID = "null" end
	query.roots = nil
	v2.request("session_list", { query = query }, function(err, sessions, meta)
		if err then callback(err, nil, meta); return end
		local result = {}
		for _, info in ipairs(sessions) do
			local normalized, decode_err = v2.session(info)
			if decode_err then callback({ message = decode_err, code = "incompatible_response" }); return end
			result[#result + 1] = normalized
		end
		callback(nil, result, meta)
	end)
end

-- Get session details
-- A session picker needs the full catalog, not the first default-sized page.
function M.get_all_sessions(opts, callback)
	local generation, queue, seen, by_id, head = configuration_generation, { false }, {}, {}, 1
	local function read()
		if generation ~= configuration_generation then callback({ code = "stale_connection", message = "Server connection changed" }); return end
		local cursor = queue[head]
		if cursor == nil then
			local values = vim.tbl_values(by_id)
			table.sort(values, function(a, b) return a.id > b.id end)
			callback(nil, values); return
		end
		head = head + 1
		local query = vim.tbl_extend("force", opts or {}, { limit = 100 })
		query.cursor = cursor or nil
		M.list_sessions(query, function(err, values, meta)
			if err then callback(err); return end
			for _, item in ipairs(values) do by_id[item.id] = item end
			for _, key in ipairs({ "previous", "next" }) do
				local next_cursor = meta and meta.cursor and meta.cursor[key]
				if #values > 0 and type(next_cursor) == "string" and not seen[next_cursor] then
					seen[next_cursor] = true; queue[#queue + 1] = next_cursor
				end
			end
			read()
		end)
	end
	read()
end

-- Get session details
---@param session_id string
---@param callback function(err, session)
function M.get_session(session_id, callback)
	v2.request("session_get", { path = { sessionID = session_id } }, callback)
end

-- Get current status for all non-idle sessions
---@param opts? table { directory? }
---@param callback function(err, statuses)
function M.get_session_statuses(opts, callback)
	if type(opts) == "function" then
		callback = opts
		opts = nil
	end
	v2.request("session_active", {}, function(err, active, meta)
		if err then callback(err, nil, meta); return end
		local statuses = {}
		for id in pairs(active) do statuses[id] = { type = "busy" } end
		callback(nil, statuses, meta)
	end)
end

-- Get child sessions for a parent session
---@param session_id string
---@param callback function(err, sessions)
function M.get_session_children(session_id, callback)
	local children, query, seen = {}, { parentID = session_id }, {}
	local function page()
		M.list_sessions(query, function(err, data, meta)
			if err then callback(err); return end
			vim.list_extend(children, data)
			local cursor = meta.cursor.next
			if type(cursor) == "string" and not seen[cursor] then
				seen[cursor] = true; query.cursor = cursor; page(); return
			end
			callback(nil, children, meta)
		end)
	end
	page()
end

-- Create new session
---@param opts? table { parentID?, title?, permission? }
---@param callback function(err, session)
function M.create_session(opts, callback)
	opts = opts or {}

	-- Ensure opts is an object (not empty array) for JSON encoding
	-- An empty Lua table {} encodes as [] in JSON, but we need {}
	-- Use vim.empty_dict() as base and merge any provided opts
	local body = vim.empty_dict()
	if next(opts) then
		-- Merge non-empty opts into the empty_dict base
		for k, v in pairs(opts) do
			body[k] = v
		end
	end

	if body.parentID ~= nil then
		require("opencode.util.schedule").schedule_callback(callback, { code = "invalid_request", message = "V2 session creation does not accept parentID" })
		return
	end
	body.location = body.location or { directory = normalize_directory(body.directory) }
	body.directory = nil
	v2.request("session_create", { body = body }, callback)
end

-- Delete session
---@param session_id string
---@param callback function(err, success)
function M.delete_session(session_id, callback)
	v2.request("session_delete", { path = { sessionID = session_id } }, callback)
end

-- Fork session
---@param session_id string
---@param opts? table { messageID? }
---@param callback function(err, session)
function M.fork_session(session_id, opts, callback)
	v2.request("session_fork", { path = { sessionID = session_id }, body = { before = opts and opts.before } }, callback)
end

-- Get session messages
---@param session_id string
---@param opts? table { limit? }
---@param callback function(err, messages)
function M.get_messages(session_id, opts, callback)
	opts = opts or {}
	v2.request("message_list", { path = { sessionID = session_id }, query = opts }, function(err, data, meta)
		if err then callback(err, nil, meta); return end
		local ok, messages = pcall(require("opencode.protocol.v2.messages").page, session_id, data)
		if not ok then callback({ code = "incompatible_response", message = "Invalid v2 message history" }); return end
		callback(nil, messages, meta)
	end)
end

-- Get session todos
---@param session_id string
---@param callback function(err, todos)
function M.get_session_todos(session_id, callback)
	local directory = require("opencode.state").get_session_directory(session_id)
	local generation = configuration_generation
	M.review_rpc("todoGet", { sessionID = session_id }, directory, function(err, record)
		if generation ~= configuration_generation then callback({ code = "stale_connection", message = "Server connection changed" }); return end
		if err then callback(err); return end
		if not require("opencode.protocol.v2.todos").valid(record, session_id, directory) then
			callback({ code = "incompatible_response", message = "Update the bundled opencode-nvim plugin: todo protocol 1 required" }); return
		end
		callback(nil, record.todos, record)
	end)
end

-- Traverse both opaque cursor directions. Only this complete snapshot may prune
-- absent v2 messages; ordinary pages remain merge-only.
function M.get_all_messages(session_id, callback)
	local generation = configuration_generation
	local queue, seen, by_id, head = { false }, {}, {}, 1
	local function read()
		if generation ~= configuration_generation then callback({ message = "Server connection changed", code = "stale_connection" }); return end
		local cursor = queue[head]
		if cursor == nil then
			local result = vim.tbl_values(by_id)
			table.sort(result, function(a, b) return a.info.id < b.info.id end)
			callback(nil, result, { complete = true }); return
		end
		head = head + 1
		M.get_messages(session_id, { limit = 100, cursor = cursor or nil }, function(err, page, meta)
			if err then callback(err); return end
			for _, message in ipairs(page) do by_id[message.info.id] = message end
			for _, key in ipairs({ "previous", "next" }) do
				local next_cursor = meta and meta.cursor and meta.cursor[key]
				if type(next_cursor) == "string" and not seen[next_cursor] then
					seen[next_cursor] = true; queue[#queue + 1] = next_cursor
				end
			end
			read()
		end)
	end
	read()
end

-- Send message to session
---@param session_id string
---@param message table { parts, model?, agent?, noReply?, system?, tools?, messageID? }
---@param opts_or_callback? table|function
---@param callback? function(err, response)
function M.send_message(session_id, message, opts_or_callback, callback)
	local opts = opts_or_callback
	if type(opts_or_callback) == "function" then
		callback = opts_or_callback
		opts = nil
	end
	v2.request("prompt", { path = { sessionID = session_id }, body = message, timeout = opts and opts.timeout }, callback)
end

-- Send async message (no wait for response)
---@param session_id string
---@param message table
---@param callback function(err)
function M.send_message_async(session_id, message, callback)
	M.send_message(session_id, message, callback)
end

-- Abort session
---@param session_id string
---@param callback function(err, success)
function M.abort_session(session_id, callback)
	v2.request("interrupt", { path = { sessionID = session_id }, query = { resume = false } }, callback)
end

function M.switch_agent(session_id, agent, callback)
	v2.request("session_agent", { path = { sessionID = session_id }, body = { agent = agent } }, callback)
end

function M.switch_model(session_id, model, callback)
	v2.request("session_model", { path = { sessionID = session_id }, body = { model = model } }, callback)
end

function M.get_inbox(session_id, callback)
	v2.request("inbox_list", { path = { sessionID = session_id } }, callback)
end

function M.cancel_input(session_id, inbox_id, callback)
	v2.request("inbox_delete", { path = { sessionID = session_id, inboxID = inbox_id } }, callback)
end

-- Native diff defaults to the last user turn. Explicit from/to cover a range.
function M.get_diff(session_id, opts, callback)
	opts = opts or {}
	v2.request("session_diff", { path = { sessionID = session_id },
		query = { from = opts.from, to = opts.to, context = opts.context } }, callback)
end

-- Stage reversible undo. Committing discarded history is a separate action.
function M.revert_message(session_id, message_id, opts, callback)
	v2.request("revert_stage", { path = { sessionID = session_id },
		body = { messageID = message_id, files = opts and opts.files } }, callback)
end
function M.clear_revert(session_id, callback)
	v2.request("revert_clear", { path = { sessionID = session_id } }, callback)
end
function M.commit_revert(session_id, callback)
	v2.request("revert_commit", { path = { sessionID = session_id } }, callback)
end

function M.summarize_session(session_id, opts, callback)
	v2.request("session_compact", { path = { sessionID = session_id },
		body = { id = opts and opts.id, delivery = opts and opts.delivery } }, callback)
end

-- Interaction routing always uses the immutable owning session, never cwd.
function M.respond_permission(permission_id, reply, opts, callback)
	opts = opts or {}
	v2.request("permission_reply", { path = { sessionID = opts.session_id, requestID = permission_id },
		body = { decision = reply, message = opts.message } }, callback)
end

function M.list_permissions(opts, callback)
	if type(opts) == "function" then callback, opts = opts, {} end
	opts = opts or {}
	v2.request(opts.session_id and "permission_list" or "permission_all", { path = { sessionID = opts.session_id } }, callback)
end

function M.create_permission(session_id, request, callback)
	v2.request("permission_create", { path = { sessionID = session_id }, body = request }, callback)
end

function M.get_permission(session_id, request_id, callback)
	v2.request("permission_get", { path = { sessionID = session_id, requestID = request_id } }, callback)
end

function M.reply_to_question(request_id, answer, opts, callback)
	if type(opts) == "function" then callback, opts = opts, {} end
	opts = opts or {}
	v2.request("form_reply", { path = { sessionID = opts.session_id, formID = request_id }, body = { answer = answer } }, callback)
end

function M.list_questions(opts, callback)
	if type(opts) == "function" then callback, opts = opts, {} end
	opts = opts or {}
	v2.request(opts.session_id and "form_list" or "form_all", { path = { sessionID = opts.session_id } }, callback)
end

function M.get_form(session_id, form_id, callback)
	v2.request("form_get", { path = { sessionID = session_id, formID = form_id } }, callback)
end

function M.reject_question(session_id, request_id, opts, callback)
	if type(opts) == "function" then callback = opts end
	v2.request("form_cancel", { path = { sessionID = session_id, formID = request_id } }, callback)
end

-- Get list of providers (basic list with all/connected/default info)
---@param callback function(err, providers)
function M.list_providers(callback, opts)
	v2.request("provider_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

-- Get configured providers with models (the main endpoint for provider/model selection)
-- Returns { providers: Provider[], default: { providerID: modelID } }
---@param callback function(err, data)
function M.get_config_providers(callback, opts)
	local directory = normalize_directory(opts and opts.directory)
	local query = { location = { directory = directory } }
	local results, remaining, first_error, location = {}, 3, nil, nil
	for key, operation in pairs({ providers = "provider_list", models = "model_list", default = "model_default" }) do
		v2.request(operation, { query = query }, function(err, data, meta)
			if err then first_error = first_error or err
			else
				if location and location.directory ~= meta.location.directory then
					first_error = { code = "location_mismatch", message = "Catalog responses belong to different locations" }
				end
				location, results[key] = meta.location, data
			end
			remaining = remaining - 1
			if remaining == 0 then
				if first_error then callback(first_error); return end
				callback(nil, catalogs.providers(results.providers, results.models, results.default), { location = location })
			end
		end)
	end
end

-- Integration IDs, stable method IDs and credential IDs are separate identities.
function M.list_integrations(callback, opts)
	v2.request("integration_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

function M.integration(operation, integration_id, body, opts, callback)
	opts = opts or {}
	if body and type(body.answer) == "table" and next(body.answer) == nil then
		body = vim.tbl_extend("force", body, { answer = vim.empty_dict() })
	end
	v2.request("integration_" .. operation, {
		path = { integrationID = integration_id, attemptID = opts.attempt_id },
		query = { location = { directory = normalize_directory(opts.directory) } }, body = body,
	}, function(err, data, meta)
		-- Authentication errors can echo submitted secrets. Never expose their body.
		if err then err = { status = err.status, code = "integration_error", message = "Integration request failed"
			.. (err.status and (" (HTTP " .. err.status .. ")") or ""), retryable = false } end
		callback(err, data, meta)
	end)
end

function M.credential(operation, credential_id, body, callback)
	v2.request("credential_" .. operation, { path = { credentialID = credential_id }, body = body }, callback)
end

-- Get config
---@param callback function(err, config)
function M.get_config(callback, opts)
	v2.request("config_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, function(err, sources, meta)
		if err then callback(err); return end
		-- Config sources are not an authoritative merged runtime configuration.
		callback(nil, { sources = sources }, meta)
	end)
end

-- Get list of agents
---@param callback function(err, agents)
function M.list_agents(callback, opts)
	v2.request("agent_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, function(err, data, meta)
		if err then callback(err); return end
		callback(nil, catalogs.agents(data), meta)
	end)
end

-- Get list of skills
---@param callback function(err, skills)
function M.list_skills(callback, opts)
	v2.request("skill_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

function M.list_commands(callback, opts)
	v2.request("command_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

-- Get MCP status
---@param callback function(err, mcp_status)
function M.get_mcp_status(callback, opts)
	v2.request("mcp_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, function(err, data, meta)
		if err then callback(err); return end
		callback(nil, catalogs.mcp(data), meta)
	end)
end

-- Connect MCP server
---@param name string MCP server name
---@param callback function(err, success)
function M.connect_mcp(name, callback, opts)
	v2.request("mcp_connect", { path = { server = name }, query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

-- Disconnect MCP server
---@param name string MCP server name
---@param callback function(err, success)
function M.disconnect_mcp(name, callback, opts)
	v2.request("mcp_disconnect", { path = { server = name }, query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

-- Read actual v2 runtime catalogs. Configured LSP/formatters are not runtime status.
function M.get_status(callback, opts)
	local results, remaining = { errors = {} }, 3
	local query = { location = { directory = normalize_directory(opts and opts.directory) } }
	for domain, operation in pairs({ version = "info", mcp = "mcp_list", plugins = "plugin_list" }) do
		v2.request(operation, { query = operation ~= "info" and query or nil }, function(err, data)
			if err then results.errors[domain] = err.message
			elseif domain == "version" then results.version = data.version
			elseif domain == "mcp" then results.mcp = catalogs.mcp(data)
			else results.plugins = data end
			remaining = remaining - 1
			if remaining == 0 then
				if results.version or results.mcp or results.plugins then callback(nil, results)
				else callback({ message = "Failed to fetch OpenCode server status", errors = results.errors }) end
			end
		end)
	end
end

-- Command admission is HTTP 204, not an assistant message. Selection is prepared
-- by send.command before calling this wire-level facade.
function M.execute_command(session_id, name, text, opts, callback)
	opts = opts or {}
	if type(text) ~= "string" then text = type(text) == "table" and next(text) and vim.json.encode(text) or "" end
	local body = { name = name, text = text, files = opts.files, agents = opts.agents, skills = opts.skills, delivery = opts.delivery }
	v2.request("command", { path = { sessionID = session_id }, body = body }, callback)
end

-- Dispose instance
---@param callback function(err, success)
function M.dispose(callback)
	v2.request("location_reload", {}, callback)
end

-- SSE Event handling

-- Subscribe to SSE events
---@param event_type string Event type or "*" for all
---@param callback function(data, event_id)
function M.on_event(event_type, callback)
	sse.on(event_type, callback)
end

-- Start SSE connection
function M.connect_events()
	return sse.connect()
end

-- Stop SSE connection
function M.disconnect_events()
	sse.disconnect()
end

-- Expose raw clients for advanced usage
M.http = http
M.sse = sse

-- Official plugin RPC transport; protocol validation belongs to the review owner.
function M.review_rpc(method, input, directory, callback)
	v2.request("rpc_call", { path = { rpcID = "opencode_nvim", method = method },
		query = { location = { directory = directory } }, body = { input = input or vim.empty_dict() } }, callback)
end

return M
