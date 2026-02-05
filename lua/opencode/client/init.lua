-- opencode.nvim - Client module (HTTP + SSE)
-- Combined interface for OpenCode server communication

local M = {}

local http = require("opencode.client.http")
local sse = require("opencode.client.sse")

-- Configure both clients
---@param opts table Configuration options
function M.setup(opts)
	opts = opts or {}

	local config = {
		host = opts.host or "localhost",
		port = opts.port or 9099,
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
---@param callback function(err, sessions)
function M.list_sessions(callback)
	http.get("/session", callback)
end

-- Get session details
---@param session_id string
---@param callback function(err, session)
function M.get_session(session_id, callback)
	http.get("/session/" .. session_id, callback)
end

-- Create new session
---@param opts? table { parentID?, title? }
---@param callback function(err, session)
function M.create_session(opts, callback)
	-- Ensure opts is an object (not empty array) for JSON encoding
	-- An empty Lua table {} encodes as [] in JSON, but we need {}
	-- Use vim.empty_dict() as base and merge any provided opts
	local body = vim.empty_dict()
	if opts and next(opts) then
		-- Merge non-empty opts into the empty_dict base
		for k, v in pairs(opts) do
			body[k] = v
		end
	end
	http.post("/session", body, callback)
end

-- Delete session
---@param session_id string
---@param callback function(err, success)
function M.delete_session(session_id, callback)
	http.delete("/session/" .. session_id, callback)
end

-- Fork session
---@param session_id string
---@param opts? table { messageID? }
---@param callback function(err, session)
function M.fork_session(session_id, opts, callback)
	opts = opts or {}
	http.post("/session/" .. session_id .. "/fork", opts, callback)
end

-- Get session messages
---@param session_id string
---@param opts? table { limit? }
---@param callback function(err, messages)
function M.get_messages(session_id, opts, callback)
	opts = opts or {}
	http.get("/session/" .. session_id .. "/message", callback, { query = opts })
end

-- Send message to session
---@param session_id string
---@param message table { parts, model?, agent?, noReply?, system?, tools?, messageID? }
---@param callback function(err, response)
function M.send_message(session_id, message, callback)
	http.post("/session/" .. session_id .. "/message", message, callback)
end

-- Send async message (no wait for response)
---@param session_id string
---@param message table
---@param callback function(err)
function M.send_message_async(session_id, message, callback)
	http.post("/session/" .. session_id .. "/prompt_async", message, function(err, _)
		callback(err)
	end)
end

-- Abort session
---@param session_id string
---@param callback function(err, success)
function M.abort_session(session_id, callback)
	http.post("/session/" .. session_id .. "/abort", {}, callback)
end

-- Get session diff
---@param session_id string
---@param opts? table { messageID? }
---@param callback function(err, diffs)
function M.get_diff(session_id, opts, callback)
	opts = opts or {}
	http.get("/session/" .. session_id .. "/diff", callback, { query = opts })
end

-- Revert message
---@param session_id string
---@param message_id string
---@param opts? table { partID? }
---@param callback function(err, success)
function M.revert_message(session_id, message_id, opts, callback)
	opts = opts or {}
	http.post("/session/" .. session_id .. "/revert", vim.tbl_deep_extend("force", opts, { messageID = message_id }), callback)
end

-- Respond to permission request
-- reply: "once" (approve this time), "always" (approve and remember), "reject" (deny)
---@param permission_id string The permission request ID (e.g., "per_xxx")
---@param reply string "once" | "always" | "reject"
---@param opts? table { message? string } Optional rejection message
---@param callback function(err, success)
function M.respond_permission(permission_id, reply, opts, callback)
	opts = opts or {}
	http.post(
		"/permission/" .. permission_id .. "/reply",
		{ reply = reply, message = opts.message },
		callback
	)
end

-- Reply to a question with selected answers
-- API endpoint: /question/:requestID/reply
---@param session_id string Session ID (unused, kept for API compatibility)
---@param request_id string Question request ID
---@param answers table Array of answer arrays, e.g., {{"label1"}, {"label2"}}
---@param callback function(err, success)
function M.reply_to_question(session_id, request_id, answers, callback)
	http.post(
		"/question/" .. request_id .. "/reply",
		{ answers = answers },
		callback
	)
end

-- Reject/cancel a question request
-- API endpoint: /question/:requestID/reject
---@param session_id string Session ID (unused, kept for API compatibility)
---@param request_id string Question request ID
---@param callback function(err, success)
function M.reject_question(session_id, request_id, callback)
	http.post(
		"/question/" .. request_id .. "/reject",
		{},
		callback
	)
end

-- Get list of providers (basic list with all/connected/default info)
---@param callback function(err, providers)
function M.list_providers(callback)
	http.get("/provider", callback)
end

-- Get configured providers with models (the main endpoint for provider/model selection)
-- Returns { providers: Provider[], default: { providerID: modelID } }
---@param callback function(err, data)
function M.get_config_providers(callback)
	http.get("/config/providers", callback)
end

-- Get provider auth methods
---@param callback function(err, auth_methods)
function M.get_provider_auth(callback)
	http.get("/provider/auth", callback)
end

-- Set provider auth (API key)
---@param provider_id string
---@param auth table { type: "api", key: string }
---@param callback function(err, success)
function M.set_provider_auth(provider_id, auth, callback)
	http.put("/auth/" .. provider_id, auth, callback)
end

-- Remove provider auth (disconnect provider)
---@param provider_id string
---@param callback function(err, success)
function M.remove_provider_auth(provider_id, callback)
	http.delete("/auth/" .. provider_id, callback)
end

-- OAuth authorize - initiate OAuth flow
---@param provider_id string
---@param method number Auth method index
---@param callback function(err, authorization)
function M.oauth_authorize(provider_id, method, callback)
	http.post("/provider/" .. provider_id .. "/oauth/authorize", { method = method }, callback)
end

-- OAuth callback - complete OAuth flow
---@param provider_id string
---@param method number Auth method index
---@param code? string OAuth authorization code (for code flow)
---@param callback function(err, success)
function M.oauth_callback(provider_id, method, code, callback)
	http.post("/provider/" .. provider_id .. "/oauth/callback", { method = method, code = code }, callback)
end

-- Get config
---@param callback function(err, config)
function M.get_config(callback)
	http.get("/global/config", callback)
end

-- Update config
---@param config table
---@param callback function(err, updated_config)
function M.update_config(config, callback)
	http.patch("/global/config", config, callback)
end

-- Get list of agents
---@param callback function(err, agents)
function M.list_agents(callback)
	http.get("/agent", callback)
end

-- Get file content
---@param path string File path
---@param callback function(err, content)
function M.get_file(path, callback)
	http.get("/file/content", callback, { query = { path = path } })
end

-- Find files
---@param query string Search query
---@param opts? table { type?, directory?, limit? }
---@param callback function(err, files)
function M.find_files(query, opts, callback)
	opts = opts or {}
	opts.query = query
	http.get("/find/file", callback, { query = opts })
end

-- Get MCP status
---@param callback function(err, mcp_status)
function M.get_mcp_status(callback)
	http.get("/mcp", callback)
end

-- Get LSP status
---@param callback function(err, lsp_status)
function M.get_lsp_status(callback)
	http.get("/lsp", callback)
end

-- Get formatter status
---@param callback function(err, formatter_status)
function M.get_formatter_status(callback)
	http.get("/formatter", callback)
end

-- Get full server status (version, MCP servers, LSP servers, formatters, plugins)
-- Fetches from multiple endpoints and combines the results
---@param callback function(err, status)
function M.get_status(callback)
	local results = {
		version = nil,
		mcp = nil,
		lsp = nil,
		formatters = nil,
		plugins = nil,
	}
	local pending = 4 -- health, mcp, lsp, formatter, config
	local errors = {}

	local function check_done()
		pending = pending - 1
		if pending == 0 then
			-- Return combined results (ignore individual errors if we got some data)
			local has_data = results.version or results.mcp or results.lsp or results.formatters or results.plugins
			if has_data then
				callback(nil, results)
			else
				callback({ message = "Failed to fetch status: " .. table.concat(errors, ", ") }, nil)
			end
		end
	end

	-- Fetch health for version
	http.health(function(err, data)
		if not err and data then
			results.version = data.version
		else
			table.insert(errors, "health")
		end
		check_done()
	end)

	-- Fetch MCP status
	http.get("/mcp", function(err, data)
		if not err and data then
			results.mcp = data
		else
			table.insert(errors, "mcp")
		end
		check_done()
	end)

	-- Fetch LSP status
	http.get("/lsp", function(err, data)
		if not err and data then
			results.lsp = data
		else
			table.insert(errors, "lsp")
		end
		check_done()
	end)

	-- Fetch formatter status
	http.get("/formatter", function(err, data)
		if not err and data then
			results.formatters = data
		else
			table.insert(errors, "formatter")
		end
		check_done()
	end)

	-- Fetch config for plugins
	pending = pending + 1
	http.get("/global/config", function(err, data)
		if not err and data and data.plugin then
			results.plugins = data.plugin
		else
			table.insert(errors, "config")
		end
		check_done()
	end)
end

-- Execute slash command
---@param session_id string
---@param command string
---@param args table
---@param opts? table { messageID?, agent?, model? }
---@param callback function(err, response)
function M.execute_command(session_id, command, args, opts, callback)
	opts = opts or {}
	http.post("/session/" .. session_id .. "/command", vim.tbl_deep_extend("force", opts, {
		command = command,
		arguments = args,
	}), callback)
end

-- Run shell command
---@param session_id string
---@param command string
---@param opts? table { agent?, model? }
---@param callback function(err, response)
function M.run_shell(session_id, command, opts, callback)
	opts = opts or {}
	http.post("/session/" .. session_id .. "/shell", vim.tbl_deep_extend("force", opts, {
		command = command,
	}), callback)
end

-- Dispose instance
---@param callback function(err, success)
function M.dispose(callback)
	http.post("/global/dispose", {}, callback)
end

-- SSE Event handling

-- Subscribe to SSE events
---@param event_type string Event type or "*" for all
---@param callback function(data, event_id)
function M.on_event(event_type, callback)
	sse.on(event_type, callback)
end

-- Unsubscribe from SSE events
---@param event_type string
---@param callback function
function M.off_event(event_type, callback)
	sse.off(event_type, callback)
end

-- Start SSE connection
function M.connect_events()
	sse.connect()
end

-- Stop SSE connection
function M.disconnect_events()
	sse.disconnect()
end

-- Check SSE connection status
function M.is_event_stream_connected()
	return sse.is_connected()
end

-- Expose raw clients for advanced usage
M.http = http
M.sse = sse

return M
