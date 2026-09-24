-- opencode.nvim - SSE (Server-Sent Events) client
-- Handles real-time event streaming from OpenCode server

local M = {}
local auth = require("opencode.client.auth")
local transport = require("opencode.client.transport")
local uv = vim.uv

-- Configuration
M.opts = {
	host = "localhost",
	endpoint = "/api/event", -- V2 live stream covers all locations.
	auth = {
		username = "opencode",
		password = nil,
	},
	reconnect = true,
	reconnect_delay = 5000,
	max_reconnects = 5,
	connect_timeout = 10000,
}

-- Internal state
local state = {
	stream = nil,
	reconnect_timer = nil,
	manual_disconnect = false,
	connected = false,
	reconnect_count = 0,
	event_buffer = "",
	current_event = {
		id = nil,
		event = "message",
		data_lines = {},
	},
	directory = nil,
}

-- Event callbacks registry
local listeners = {}
local seen_event_ids = {}
local seen_event_order = {}
local MAX_SEEN_EVENT_IDS = 512

local function stop_reconnect_timer()
	if not state.reconnect_timer then
		return
	end

	if not uv.is_closing(state.reconnect_timer) then
		pcall(function()
			state.reconnect_timer:stop()
		end)
		pcall(function()
			state.reconnect_timer:close()
		end)
	end
	state.reconnect_timer = nil
end

local function reset_current_event()
	state.current_event = {
		id = nil,
		event = "message",
		data_lines = {},
	}
end

---@param directory string|nil
---@return string|nil
local function normalize_directory(directory)
	if not directory or directory == "" then
		return nil
	end

	local normalized = directory
	if vim.fs and vim.fs.normalize then
		normalized = vim.fs.normalize(normalized)
	end
	return (normalized:gsub("/+$", ""))
end

---@return string|nil
local function current_directory()
	local cwd = vim.fn.getcwd()
	if not cwd or cwd == "" then
		return state.directory
	end
	return normalize_directory(cwd) or state.directory
end

---@param data any
---@return boolean
local function should_accept_global_event(data)
	if type(data) ~= "table" then
		return true
	end

	local directory = type(data.location) == "table" and data.location.directory or nil
	if not directory or directory == "" or directory == "global" then
		return true
	end

	local event_dir = normalize_directory(directory)

	-- Accept events for the current working directory.
	local current = current_directory()
	if current and current ~= "" then
		state.directory = current
		if event_dir == current then
			return true
		end
	end

	-- Open tabs keep receiving events while another project has focus.
	-- The active view may also be a child session outside the runtime tab list.
	local ok_state, state_mod = pcall(require, "opencode.state")
	if ok_state and state_mod.get_session and state_mod.get_session_directory then
		local active = state_mod.get_session()
		if active and active.id then
			local session_dir = state_mod.get_session_directory(active.id)
			if session_dir and session_dir ~= "" and session_dir == event_dir then
				return true
			end
		end
		if type(state_mod.get_active_sessions) == "function" then
			for _, session in ipairs(state_mod.get_active_sessions()) do
				if state_mod.get_session_directory(session.id) == event_dir then
					return true
				end
			end
		end
	end

	-- Debug-log dropped events so directory mismatches are traceable.
	pcall(function()
		local logger = require("opencode.logger")
		local active = ok_state
			and state_mod.get_session
			and state_mod.get_session()
			or nil
		logger.debug("SSE event dropped: directory mismatch", {
			event_directory = event_dir,
			cwd = current,
			session_id = active and active.id or nil,
		})
	end)

	return false
end

local function emit_current_event()
	local event = state.current_event
	if not event or #event.data_lines == 0 then
		reset_current_event()
		return
	end

	local payload = table.concat(event.data_lines, "\n")

	local ok, parsed = pcall(vim.json.decode, payload)
	if ok and parsed then
		M.emit(event.event, parsed, event.id)
	else
		M.emit(event.event, payload, event.id)
	end

	reset_current_event()
end

-- Process SSE data buffer
local function process_buffer()
	-- Process line-by-line because socket callbacks may split SSE frames arbitrarily.
	-- Flush buffered data whenever we hit SSE's blank-line delimiter.
	while true do
		local newline = state.event_buffer:find("\n", 1, true)
		if not newline then
			break
		end

		local raw_line = state.event_buffer:sub(1, newline - 1)
		state.event_buffer = state.event_buffer:sub(newline + 1)
		local line = raw_line:gsub("\r$", "")

		if line == "" then
			emit_current_event()
		elseif line:sub(1, 1) == ":" then
			-- Comment line, ignore.
		else
			local field, value = line:match("^([^:]+):(.*)$")
			field, value = field or line, value or ""
			-- SSE removes at most one space after the colon. Fields may follow data.
			value = value:gsub("^ ", "", 1)
			if field == "event" then
				state.current_event.event = value ~= "" and value or "message"
			elseif field == "id" then
				if not value:find("\0", 1, true) then
					state.current_event.id = value ~= "" and value or nil
				end
			elseif field == "data" then
				table.insert(state.current_event.data_lines, value)
			end
		end
	end
end

local function schedule_reconnect()
	if not M.opts.reconnect then
		return
	end
	if state.manual_disconnect then
		return
	end
	if state.reconnect_count >= M.opts.max_reconnects then
		M.emit("error", "SSE reconnect gave up after " .. tostring(M.opts.max_reconnects) .. " attempts")
		return
	end

	stop_reconnect_timer()
	state.reconnect_count = state.reconnect_count + 1

	local timer = uv.new_timer()
	if not timer then
		M.emit("error", "Failed to create reconnect timer")
		return
	end

	state.reconnect_timer = timer
	timer:start(
		M.opts.reconnect_delay,
		0,
		vim.schedule_wrap(function()
			stop_reconnect_timer()
			if state.manual_disconnect then
				return
			end
			M.connect()
		end)
	)
end

local function handle_stream_closed(reason, closed_stream)
	if closed_stream ~= nil and closed_stream ~= state.stream then
		return
	end

	emit_current_event()
	stop_reconnect_timer()

	local was_connected = state.connected
	state.connected = false
	state.stream = nil

	if state.manual_disconnect then
		state.manual_disconnect = false
		if was_connected then
			M.emit("disconnected", reason or "Connection closed")
		end
		return
	end

	M.emit("disconnected", reason or "Connection closed")
	schedule_reconnect()
end

---@param event_id string|nil
---@return boolean
local function already_seen_event(event_id)
	if not event_id or event_id == "" then
		return false
	end

	if seen_event_ids[event_id] then
		return true
	end

	seen_event_ids[event_id] = true
	table.insert(seen_event_order, event_id)

	while #seen_event_order > MAX_SEEN_EVENT_IDS do
		local oldest = table.remove(seen_event_order, 1)
		if oldest then
			seen_event_ids[oldest] = nil
		end
	end

	return false
end

-- Emit event to all listeners
function M.emit(event_type, data, event_id)
	local actual_type = event_type
	local actual_data = data
	local actual_event_id = event_id

	if event_type ~= "connected" and event_type ~= "disconnected" and event_type ~= "error" then
		local decoded, decode_err = require("opencode.protocol.v2.events").decode(data)
		if not decoded then
			M.emit("error", decode_err)
			return
		end
		if not should_accept_global_event(data) then return end
		actual_event_id = decoded.id or event_id
		if already_seen_event(actual_event_id) then return end
		actual_type, actual_data = decoded.type, decoded.payload
	end

	local callbacks = listeners[actual_type] or {}
	for _, cb in ipairs(callbacks) do
		local ok, err = pcall(cb, actual_data, actual_event_id)
		if not ok then
			vim.notify("SSE listener error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end

	-- Also emit to wildcard listeners
	local wildcards = listeners["*"] or {}
	for _, cb in ipairs(wildcards) do
		local ok, err = pcall(cb, actual_type, actual_data, actual_event_id)
		if not ok then
			vim.notify("SSE wildcard listener error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

-- Subscribe to SSE events
---@param event_type string Event type to listen for (or "*" for all)
---@param callback function(data, event_id) or function(event_type, data, event_id) for wildcard
function M.on(event_type, callback)
	listeners[event_type] = listeners[event_type] or {}
	table.insert(listeners[event_type], callback)
end

-- Unsubscribe from SSE events
---@param event_type string
---@param callback function
function M.off(event_type, callback)
	local callbacks = listeners[event_type] or {}
	for i, cb in ipairs(callbacks) do
		if cb == callback then
			table.remove(callbacks, i)
			break
		end
	end
end

-- Clear all listeners
function M.clear_listeners()
	listeners = {}
	seen_event_ids = {}
	seen_event_order = {}
end

-- Start SSE connection
function M.connect()
	if state.stream then
		return true -- Already connected or connecting
	end

	state.manual_disconnect = false
	state.event_buffer = ""
	reset_current_event()
	state.connected = false

	local headers = {
		Accept = "text/event-stream",
		["Cache-Control"] = "no-cache",
	}
	local authorization, auth_err = auth.header(M.opts.auth.username, M.opts.auth.password)
	if auth_err then
		stop_reconnect_timer()
		M.emit("error", auth_err)
		return false, auth_err
	end
	if authorization then
		headers.Authorization = authorization
	end

	-- The stream is global; directory is only a local relevance filter.
	local cwd = vim.fn.getcwd()
	local endpoint = M.opts.endpoint or "/api/event"
	state.directory = normalize_directory(cwd)

	local stream
	local err
	stream, err = transport.open_stream({
		host = M.opts.host,
		port = M.opts.port,
		method = "GET",
		path = endpoint,
		headers = headers,
		timeout = M.opts.connect_timeout,
		on_headers = function(status, _)
			if status < 200 or status >= 300 then
				M.emit("error", "SSE handshake failed with HTTP status " .. status)
				if state.stream and state.stream.close then
					state.stream.close()
				end
				return
			end

			state.connected = true
			state.reconnect_count = 0
			M.emit("connected", nil)
		end,
		on_data = function(data)
			if not data or data == "" then
				return
			end
			state.event_buffer = state.event_buffer .. data
			process_buffer()
		end,
		on_error = function(stream_err)
			local message = stream_err and (stream_err.message or stream_err.error) or "SSE stream error"
			M.emit("error", message)
		end,
		on_close = function(reason)
			handle_stream_closed(reason, stream)
		end,
	})

	if not stream then
		local message = err and (err.message or err.error) or "Failed to open SSE stream"
		M.emit("error", message)
		schedule_reconnect()
		return false, message
	end

	state.stream = stream
	return true
end

-- Disconnect from SSE stream
function M.disconnect()
	stop_reconnect_timer()
	state.manual_disconnect = true
	state.reconnect_count = 0
	if state.stream and state.stream.close then
		state.stream.close()
		state.stream = nil
	end
	state.connected = false
end

-- Check if connected
function M.is_connected()
	return state.connected and state.stream ~= nil
end

-- Configure SSE client
---@param opts table
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

-- Get current connection status
function M.status()
	return {
		connected = state.connected,
		reconnect_count = state.reconnect_count,
		has_job = state.stream ~= nil,
		has_stream = state.stream ~= nil,
	}
end

-- Expose internal filter for testing.
M._should_accept = should_accept_global_event

return M
