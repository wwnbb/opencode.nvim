local M = {}

local http = require("opencode.client.http")
local sse = require("opencode.client.sse")
local api = require("opencode.client.api")
local catalogs = require("opencode.protocol.catalogs")
local configuration_generation = 0

---@param directory? string
---@return string|nil
local function normalize_directory(directory)
	local dir = directory
	if not dir or dir == "" then
		dir = vim.fn.getcwd()
	end

	return require("opencode.util.path").absolute(dir)
end

local function collect_pages(fetch_page, get_id, callback)
	local generation, queue, seen, by_id, head = configuration_generation, { false }, {}, {}, 1
	local function read()
		if generation ~= configuration_generation then callback({ code = "stale_connection", message = "Server connection changed" }); return end
		local cursor = queue[head]
		if cursor == nil then callback(nil, vim.tbl_values(by_id)); return end
		head = head + 1
		fetch_page(cursor or nil, function(err, page, meta)
			if err then callback(err); return end
			for _, item in ipairs(page) do by_id[get_id(item)] = item end
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

---@param opts table Configuration options
function M.setup(opts)
	if package.loaded["opencode.client.explanation"] then require("opencode.client.explanation").cancel_all() end
	configuration_generation = configuration_generation + 1
	opts = opts or {}

	local config = {
		url = opts.url or false,
		host = opts.host or "localhost",
		port = opts.port,
		tls = opts.tls or {},
		auth = opts.auth or { username = "opencode", password = nil },
		timeout = opts.timeout or 30000,
	}

	http.setup(config)
	sse.setup(vim.tbl_deep_extend("force", config, {
		reconnect = opts.reconnect ~= false,
		reconnect_delay = opts.reconnect_delay or 5000,
		max_reconnects = opts.max_reconnects or false,
		resolve_endpoint = opts.resolve_endpoint or false,
	}))
end

function M.endpoint_config()
	return vim.deepcopy({ generation = configuration_generation, url = http.opts.url, host = http.opts.host, port = http.opts.port, auth = http.opts.auth, tls = http.opts.tls })
end

-- Managed discovery may change the URL/password while a reconnect is pending.
function M.configure_endpoint(opts)
	local current = M.endpoint_config()
	for _, key in ipairs({ "url", "host", "port", "auth", "tls" }) do
		if opts[key] ~= nil and not vim.deep_equal(current[key], opts[key]) then
			if package.loaded["opencode.client.explanation"] then require("opencode.client.explanation").cancel_all() end
			configuration_generation = configuration_generation + 1
			break
		end
	end
	http.setup(opts)
	for key, value in pairs(opts) do sse.opts[key] = vim.deepcopy(value) end
end

function M.set_session_environment(session_id, variables, callback)
	if type(variables) ~= "table" then
		require("opencode.util.schedule").schedule_callback(callback, { message = "Environment must be an object of string variables" }); return
	end
	for key, value in pairs(variables) do
		if type(key) ~= "string" or type(value) ~= "string" or key == "" or key:find("[=%z]") or value:find("%z") then
			require("opencode.util.schedule").schedule_callback(callback, { message = "Environment names and values must be valid strings" }); return
		end
	end
	return api.request("session_environment", { path = { sessionID = session_id }, body = { variables = next(variables) and variables or vim.empty_dict() } }, callback)
end

function M.get_server_info(callback)
	return api.request("info", {}, callback)
end

function M.pair_server(callback)
	return api.request("server_pair", {}, callback)
end

function M.list_terminals(session_id, callback)
	return api.request("pty_list", { path = { sessionID = session_id } }, callback)
end

function M.create_terminal(session_id, opts, callback)
	opts = vim.deepcopy(opts or {})
	if type(opts.env) == "table" and next(opts.env) == nil then opts.env = vim.empty_dict() end
	return api.request("pty_create", { path = { sessionID = session_id }, body = opts }, callback)
end

function M.get_terminal(id, callback)
	return api.request("pty_get", { path = { ptyID = id } }, callback)
end

function M.get_terminal_snapshot(id, callback)
	return api.request("pty_snapshot", { path = { ptyID = id } }, callback)
end

function M.resize_terminal(id, size, attachment_id, callback)
	return api.request("pty_update", { path = { ptyID = id }, body = { size = size, attachmentID = attachment_id } }, callback)
end

function M.remove_terminal(id, callback)
	return api.request("pty_remove", { path = { ptyID = id } }, callback)
end

function M.list_server_plugins(opts, callback)
	return api.request("plugin_list", { query = { location = { directory = opts.directory } } }, callback)
end

function M.check_server_plugins(target, opts, callback)
	return api.request("plugin_check", { query = { location = { directory = opts.directory } }, body = { target = target } }, callback)
end

function M.update_server_plugins(targets, opts, callback)
	return api.request("plugin_update", { query = { location = { directory = opts.directory } }, body = { targets = targets }, timeout = 0 }, callback)
end

function M.run_session_shell(session_id, command, callback)
	-- Native Session.shell waits for process exit. Keep the asynchronous request
	-- alive until completion or a transport failure, including long commands.
	return api.request("session_shell", { path = { sessionID = session_id }, body = { command = command }, timeout = 0 }, callback)
end

function M.background_session(session_id, callback)
	return api.request("session_background", { path = { sessionID = session_id } }, callback)
end

function M.list_shells(opts, callback)
	return api.request("shell_list", { query = { location = { directory = opts.directory } } }, function(err, entries, meta)
		for _, entry in ipairs(entries or {}) do entry.location = vim.deepcopy(meta.location) end
		callback(err, entries, meta)
	end)
end

function M.get_shell(id, opts, callback)
	return api.request("shell_get", { path = { id = id }, query = { location = { directory = opts.directory } } }, callback)
end

function M.get_shell_output(id, opts, callback)
	return api.request("shell_output", { path = { id = id }, query = {
		location = { directory = opts.directory }, cursor = opts.cursor, limit = opts.limit,
	} }, callback)
end

function M.remove_shell(id, opts, callback)
	return api.request("shell_remove", { path = { id = id }, query = { location = { directory = opts.directory } } }, callback)
end

---@param callback function(err, data)
function M.health(callback)
	http.health(callback)
end

---@param opts? table { roots?, directory?, search?, limit?, start? }
---@param callback function(err, sessions)
function M.list_sessions(opts, callback)
	local query = vim.deepcopy(opts or {})
	if query.roots then query.parentID = "null" end
	query.roots = nil
	api.request("session_list", { query = query }, function(err, sessions, meta)
		if err then callback(err, nil, meta); return end
		local result = {}
		for _, info in ipairs(sessions) do
			local normalized, decode_err = api.session(info)
			if decode_err then callback({ message = decode_err, code = "incompatible_response" }); return end
			if not M.is_explanation_session(info.id) then result[#result + 1] = normalized end
		end
		callback(nil, result, meta)
	end)
end

-- Aggregate usage statistics across sessions.
---@param opts? table Query options supported by the server.
---@param callback function(err, stats)
function M.get_usage_stats(opts, callback)
	if type(opts) == "function" then
		callback = opts
		opts = nil
	end
	api.request("session_stats", { query = opts }, callback)
end

-- A session picker needs the full catalog, not the first default-sized page.
function M.get_all_sessions(opts, callback)
	collect_pages(function(cursor, done)
		local query = vim.tbl_extend("force", opts or {}, { limit = 100 })
		query.cursor = cursor
		M.list_sessions(query, done)
	end, function(item) return item.id end, function(err, values)
		if err then callback(err); return end
		table.sort(values, function(a, b) return a.id > b.id end)
		callback(nil, values)
	end)
end

---@param session_id string
---@param callback function(err, session)
function M.get_session(session_id, callback)
	api.request("session_get", { path = { sessionID = session_id } }, callback)
end

function M.update_session(session_id, title, callback)
	api.request("session_update", { path = { sessionID = session_id }, body = { title = title } }, callback)
end

function M.list_projects(callback)
	api.request("project_list", {}, callback)
end

function M.get_location(directory, callback)
	if directory ~= nil and not require("opencode.util.path").is_absolute(directory) then
		require("opencode.util.schedule").schedule_callback(callback, { code = "invalid_request", message = "Enter an absolute server directory" }); return
	end
	api.request("location_get", { query = directory and { location = { directory = directory } } or nil }, callback)
end

function M.list_worktrees(project_id, callback)
	api.request("worktree_list", { query = { projectID = project_id } }, callback)
end

function M.create_worktree(project_id, opts, callback)
	local body = vim.tbl_extend("force", opts or {}, { projectID = project_id })
	api.request("worktree_create", { body = body }, callback)
end

function M.remove_worktree(project_id, directory, force, callback)
	if not require("opencode.util.path").is_absolute(directory) then
		require("opencode.util.schedule").schedule_callback(callback, { code = "invalid_request", message = "Invalid server worktree directory" }); return
	end
	api.request("worktree_remove", { body = { projectID = project_id, directory = directory, force = force == true } }, callback)
end

function M.refresh_worktrees(project_id, callback)
	api.request("worktree_refresh", { body = { projectID = project_id } }, callback)
end

function M.move_session(session_id, directory, callback)
	api.request("session_move", { path = { sessionID = session_id }, body = { directory = directory } }, callback)
end

function M.view_session(session_id, idle, callback)
	api.request("session_view", { path = { sessionID = session_id }, body = { idle = idle } }, callback)
end

-- Get current status for all non-idle sessions
---@param callback function(err, statuses)
function M.get_session_statuses(callback)
	api.request("session_active", {}, function(err, active, meta)
		if err then callback(err, nil, meta); return end
		local statuses = {}
		for id in pairs(active) do if not M.is_explanation_session(id) then statuses[id] = { type = "busy" } end end
		callback(nil, statuses, meta)
	end)
end

---@param session_id string
---@param callback function(err, sessions)
function M.get_session_children(session_id, callback)
	local generation = configuration_generation
	local children, query, seen = {}, { parentID = session_id }, {}
	local function page()
		M.list_sessions(query, function(err, data, meta)
			if generation ~= configuration_generation then
				callback({ code = "stale_connection", message = "Server connection changed" }); return
			end
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

---@param opts? table Native v2 session options; directory is an alias for location.directory.
---@param callback function(err, session)
function M.create_session(opts, callback)
	local body = vim.tbl_extend("force", {}, opts or {})

	if body.parentID ~= nil then
		require("opencode.util.schedule").schedule_callback(callback, { code = "invalid_request", message = "V2 session creation does not accept parentID" })
		return
	end
	body.location = body.location or { directory = normalize_directory(body.directory) }
	body.directory = nil
	api.request("session_create", { body = body }, callback)
end

---@param session_id string
---@param callback function(err, success)
function M.delete_session(session_id, callback)
	api.request("session_delete", { path = { sessionID = session_id } }, callback)
end

---@param session_id string
---@param opts? table { before?: string } Exclusive message boundary; omission copies full history.
---@param callback function(err, session)
function M.fork_session(session_id, opts, callback)
	local body = vim.empty_dict()
	if opts and opts.before then body.before = opts.before end
	api.request("session_fork", { path = { sessionID = session_id }, body = body }, callback)
end

-- Return the server's complete native transcript; keep DTOs intact for JSON
-- export and let presentation choose which message content to include.
---@param session_id string
---@param opts? table { sanitize?: boolean }
---@param callback function(err, transcript)
function M.export_session(session_id, opts, callback)
	local query = opts and opts.sanitize ~= nil and { sanitize = opts.sanitize } or nil
	return api.request("session_export", { path = { sessionID = session_id }, query = query }, callback)
end

---@param session_id string
---@param opts? table { limit? }
---@param callback function(err, messages)
function M.get_messages(session_id, opts, callback)
	opts = opts or {}
	api.request("message_list", { path = { sessionID = session_id }, query = opts }, function(err, data, meta)
		if err then callback(err, nil, meta); return end
		local ok, messages = pcall(require("opencode.protocol.messages").page, session_id, data)
		if not ok then callback({ code = "incompatible_response", message = "Invalid v2 message history" }); return end
		callback(nil, messages, meta)
	end)
end

-- Traverse both opaque cursor directions. Only this complete snapshot may prune
-- absent v2 messages; ordinary pages remain merge-only.
function M.get_all_messages(session_id, callback)
	collect_pages(function(cursor, done)
		M.get_messages(session_id, { limit = 100, cursor = cursor }, done)
	end, function(message) return message.info.id end, function(err, messages)
		if err then callback(err); return end
		table.sort(messages, function(a, b) return a.info.id < b.info.id end)
		callback(nil, messages, { complete = true })
	end)
end

---@param session_id string
---@param message table Native v2 prompt payload.
---@param callback function(err, response)
function M.send_message(session_id, message, callback)
	api.request("prompt", { path = { sessionID = session_id }, body = message }, callback)
end

-- Generate a one-shot answer from a session's context without changing its history.
---@param session_id string
---@param prompt string
---@param callback function(err, text)
function M.generate_text(session_id, prompt, callback)
	api.request("generate", { path = { sessionID = session_id }, body = { prompt = prompt }, timeout = 0 }, callback)
end

-- Generate editor completion; progress uses an isolated temporary session.
---@param prompt string
---@param model? table Native Model.Ref: { providerID, id, variant? }.
---@param callback function(err, text)
---@param opts? table { timeout?: number, directory?: string, on_update?: fun(text: string), on_progress?: fun(tokens: number) } Updates contain accumulated output; tokens are estimated.
---@return table|nil request Handle with cancel() and is_active().
function M.generate_completion(prompt, model, callback, opts)
	if opts and (type(opts.on_update) == "function" or type(opts.on_progress) == "function") then
		return require("opencode.client.explanation").generate(prompt, model, callback,
			vim.tbl_extend("force", opts, { title = "Completion" }), M.endpoint_config)
	end
	return api.request("completion", {
		body = { prompt = prompt, model = model },
		timeout = opts and opts.timeout,
	}, callback)
end

-- Streaming uses an isolated temporary native session; final-only callers keep
-- the sessionless JSON endpoint.
function M.generate_explanation(prompt, model, callback, opts)
	if opts and type(opts.on_update) == "function" then
		return require("opencode.client.explanation").generate(prompt, model, callback, opts, M.endpoint_config)
	end
	return M.generate_completion(prompt, model, callback, opts)
end

function M.is_explanation_session(id)
	return require("opencode.client.explanation").is_session(id)
end

---@param session_id string
---@param callback function(err, success)
function M.abort_session(session_id, callback)
	api.request("interrupt", { path = { sessionID = session_id }, query = { resume = false } }, callback)
end

function M.wait_session(session_id, callback)
	api.request("session_wait", { path = { sessionID = session_id } }, callback)
end

function M.switch_agent(session_id, agent, callback)
	api.request("session_agent", { path = { sessionID = session_id }, body = { agent = agent } }, callback)
end

function M.switch_model(session_id, model, callback)
	api.request("session_model", { path = { sessionID = session_id }, body = { model = model } }, callback)
end

function M.get_inbox(session_id, callback)
	api.request("inbox_list", { path = { sessionID = session_id } }, callback)
end

function M.cancel_input(session_id, inbox_id, callback)
	api.request("inbox_delete", { path = { sessionID = session_id, inboxID = inbox_id } }, callback)
end

function M.set_input_delivery(session_id, inbox_id, delivery, callback)
	api.request("inbox_update", { path = { sessionID = session_id, inboxID = inbox_id }, body = { delivery = delivery } }, callback)
end

-- Native diff defaults to the last user turn. Explicit from/to cover a range.
function M.get_diff(session_id, opts, callback)
	opts = opts or {}
	api.request("session_diff", { path = { sessionID = session_id },
		query = { from = opts.from, to = opts.to, context = opts.context } }, callback)
end

-- Stage reversible undo. Committing discarded history is a separate action.
function M.revert_message(session_id, message_id, opts, callback)
	api.request("revert_stage", { path = { sessionID = session_id },
		body = { messageID = message_id, files = opts and opts.files } }, callback)
end
function M.clear_revert(session_id, callback)
	api.request("revert_clear", { path = { sessionID = session_id } }, callback)
end
function M.commit_revert(session_id, callback)
	api.request("revert_commit", { path = { sessionID = session_id } }, callback)
end

function M.summarize_session(session_id, opts, callback)
	api.request("session_compact", { path = { sessionID = session_id },
		body = { id = opts and opts.id, delivery = opts and opts.delivery } }, callback)
end

-- Interaction routing always uses the immutable owning session, never cwd.
function M.respond_permission(permission_id, reply, opts, callback)
	opts = opts or {}
	api.request("permission_reply", { path = { sessionID = opts.session_id, requestID = permission_id },
		body = { decision = reply, message = opts.message } }, callback)
end

function M.list_permissions(opts, callback)
	if type(opts) == "function" then callback, opts = opts, {} end
	opts = opts or {}
	api.request(opts.session_id and "permission_list" or "permission_all", { path = { sessionID = opts.session_id } }, callback)
end

function M.create_permission(session_id, request, callback)
	api.request("permission_create", { path = { sessionID = session_id }, body = request }, callback)
end

function M.get_permission(session_id, request_id, callback)
	api.request("permission_get", { path = { sessionID = session_id, requestID = request_id } }, callback)
end

function M.reply_to_question(request_id, answer, opts, callback)
	if type(opts) == "function" then callback, opts = opts, {} end
	opts = opts or {}
	api.request("form_reply", { path = { sessionID = opts.session_id, formID = request_id }, body = { answer = answer } }, callback)
end

function M.list_questions(opts, callback)
	if type(opts) == "function" then callback, opts = opts, {} end
	opts = opts or {}
	api.request(opts.session_id and "form_list" or "form_all", { path = { sessionID = opts.session_id } }, callback)
end

function M.get_form(session_id, form_id, callback)
	api.request("form_get", { path = { sessionID = session_id, formID = form_id } }, callback)
end

function M.reject_question(session_id, request_id, callback)
	api.request("form_cancel", { path = { sessionID = session_id, formID = request_id } }, callback)
end

---@param callback function(err, providers)
function M.list_providers(callback, opts)
	api.request("provider_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

-- Get configured providers with models (the main endpoint for provider/model selection)
-- Returns { providers: Provider[], default: { providerID: modelID } }
---@param callback function(err, data)
function M.get_config_providers(callback, opts)
	local directory = normalize_directory(opts and opts.directory)
	local query = { location = { directory = directory } }
	local results, remaining, first_error, location = {}, 3, nil, nil
	for key, operation in pairs({ providers = "provider_list", models = "model_list", default = "model_default" }) do
		api.request(operation, { query = query }, function(err, data, meta)
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
	api.request("integration_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

function M.integration(operation, integration_id, body, opts, callback)
	opts = opts or {}
	if body and type(body.answer) == "table" and next(body.answer) == nil then
		body = vim.tbl_extend("force", body, { answer = vim.empty_dict() })
	end
	api.request("integration_" .. operation, {
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
	api.request("credential_" .. operation, { path = { credentialID = credential_id }, body = body }, callback)
end

---@param callback function(err, config)
function M.get_config(callback, opts)
	api.request("config_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, function(err, sources, meta)
		if err then callback(err); return end
		-- Config sources are not an authoritative merged runtime configuration.
		callback(nil, { sources = sources }, meta)
	end)
end

---@param callback function(err, agents)
function M.list_agents(callback, opts)
	api.request("agent_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, function(err, data, meta)
		if err then callback(err); return end
		callback(nil, catalogs.agents(data), meta)
	end)
end

---@param callback function(err, skills)
function M.list_skills(callback, opts)
	api.request("skill_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

function M.list_commands(callback, opts)
	api.request("command_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

---@param callback function(err, mcp_status)
function M.get_mcp_status(callback, opts)
	api.request("mcp_list", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, function(err, data, meta)
		if err then callback(err); return end
		callback(nil, catalogs.mcp(data), meta)
	end)
end

---@param name string MCP server name
---@param callback function(err, success)
function M.connect_mcp(name, callback, opts)
	api.request("mcp_connect", { path = { server = name }, query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

---@param name string MCP server name
---@param callback function(err, success)
function M.disconnect_mcp(name, callback, opts)
	api.request("mcp_disconnect", { path = { server = name }, query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

-- Read actual v2 runtime catalogs. Configured LSP/formatters are not runtime status.
function M.get_status(callback, opts)
	local results, remaining = { errors = {} }, 3
	local query = { location = { directory = normalize_directory(opts and opts.directory) } }
	for domain, operation in pairs({ version = "info", mcp = "mcp_list", plugins = "plugin_list" }) do
		api.request(operation, { query = operation ~= "info" and query or nil }, function(err, data)
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
	if type(text) ~= "string" then
		require("opencode.util.schedule").schedule_callback(callback, { code = "invalid_request", message = "Command text must be a string" }); return
	end
	opts = opts or {}
	local body = { name = name, text = text, files = opts.files, agents = opts.agents, skills = opts.skills, delivery = opts.delivery }
	api.request("command", { path = { sessionID = session_id }, body = body }, callback)
end

-- Reload the server location and its configuration.
---@param callback function(err, success)
function M.dispose(callback)
	api.request("location_reload", {}, callback)
end

---@param event_type string Event type or "*" for all
---@param callback function(data, event_id) or function(event_type, data, event_id) for "*".
function M.on_event(event_type, callback)
	sse.on(event_type, callback)
end

function M.connect_events()
	return sse.connect()
end

function M.disconnect_events()
	if package.loaded["opencode.client.explanation"] then require("opencode.client.explanation").cancel_all() end
	sse.disconnect()
end

-- Expose raw clients for advanced usage
M.http = http
M.sse = sse

-- Official plugin RPC transport; protocol validation belongs to the review owner.
function M.review_rpc(method, input, directory, callback)
	api.request("rpc_call", { path = { rpcID = "opencode_nvim", method = method },
		query = { location = { directory = directory } }, body = { input = input or vim.empty_dict() } }, callback)
end

function M.get_vcs_info(opts, callback)
	api.request("vcs_info", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

function M.get_vcs_base(opts, callback)
	api.request("vcs_base", { query = { location = { directory = normalize_directory(opts and opts.directory) } } }, callback)
end

function M.list_vcs_branches(opts, callback)
	opts = opts or {}
	api.request("vcs_branches", { query = { location = { directory = normalize_directory(opts.directory) }, search = opts.search, limit = 100 } }, callback)
end

function M.get_vcs_diff(opts, callback)
	opts = opts or {}
	api.request("vcs_diff", { query = { location = { directory = normalize_directory(opts.directory) }, mode = opts.mode or "branch",
		base = opts.base, context = opts.context } }, callback)
end

return M
