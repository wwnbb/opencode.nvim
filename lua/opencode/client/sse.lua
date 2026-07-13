-- opencode.nvim - SSE (Server-Sent Events) client
-- Handles real-time event streaming from OpenCode server

local M = {}
local transport = require("opencode.client.transport")
local uv = vim.uv

-- Configuration
M.opts = {
	host = "localhost",
	endpoint = "/global/event", -- Matches TUI's global event stream
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

local function auth_header()
	if not M.opts.auth.password then
		return nil
	end
	local credentials = string.format("%s:%s", M.opts.auth.username, M.opts.auth.password)
	local encoded = vim.fn.base64encode(credentials)
	return "Basic " .. encoded
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
	if type(data) ~= "table" or not data.payload then
		return true
	end

	local directory = data.directory
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

	-- Also accept events for the active session's directory. When the user
	-- switches to a session belonging to another project, the session's
	-- directory differs from vim.fn.getcwd(). Without this, permission and
	-- question events for that session are silently dropped, leaving the
	-- agent stuck waiting for a reply the user can never see.
	local ok_state, state_mod = pcall(require, "opencode.state")
	if ok_state and state_mod.get_session and state_mod.get_session_directory then
		local active = state_mod.get_session()
		if active and active.id then
			local session_dir = state_mod.get_session_directory(active.id)
			if session_dir and session_dir ~= "" and session_dir == event_dir then
				return true
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
		elseif line:sub(1, 7) == "event:" then
			-- Some runtimes may drop SSE separators; flush when a new event begins.
			if #state.current_event.data_lines > 0 then
				emit_current_event()
			end
			state.current_event.event = line:sub(8):match("^%s*(.+)$") or "message"
		elseif line:sub(1, 4) == "id:" then
			if #state.current_event.data_lines > 0 then
				emit_current_event()
			end
			state.current_event.id = line:sub(5):match("^%s*(.+)$")
		elseif line:sub(1, 5) == "data:" then
			local value = line:sub(6):match("^%s*(.*)$") or ""
			table.insert(state.current_event.data_lines, value)
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

local function handle_stream_closed(reason)
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

---@param event_type string|nil
---@return string|nil
local function strip_sync_version(event_type)
	if type(event_type) ~= "string" then
		return event_type
	end
	return event_type:gsub("%.%d+$", "")
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

---@param payload table
---@param fallback_event_id string|nil
---@return string|nil
local function payload_event_id(payload, fallback_event_id)
	if type(payload) ~= "table" then
		return fallback_event_id
	end
	if payload.type == "sync" and type(payload.syncEvent) == "table" then
		return payload.syncEvent.id or payload.id or fallback_event_id
	end
	return payload.id or fallback_event_id
end

---@param target any
---@param data table
local function attach_global_metadata(target, data)
	if type(target) ~= "table" then
		return
	end
	target._directory = data.directory
	target._workspace = data.workspace
end

-- Emit event to all listeners
function M.emit(event_type, data, event_id)
	-- Handle wrapped global event format: {directory, payload: {type, properties}}
	local actual_type = event_type
	local actual_data = data
	local actual_event_id = event_id

	if type(data) == "table" and data.payload and data.payload.type then
		if not should_accept_global_event(data) then
			return
		end
		actual_event_id = payload_event_id(data.payload, event_id)
		if already_seen_event(actual_event_id) then
			return
		end
		if data.payload.type == "sync" then
			local sync_event = data.payload.syncEvent
			if type(sync_event) ~= "table" then
				return
			end
			actual_type = strip_sync_version(sync_event.type)
			actual_data = sync_event.data or {}
			if type(actual_data) == "table" then
				actual_data._sync_event_id = sync_event.id
				actual_data._sync_seq = sync_event.seq
				actual_data._sync_aggregate_id = sync_event.aggregateID
			end
		else
			actual_type = data.payload.type
			actual_data = data.payload.properties or {}
		end
		attach_global_metadata(actual_data, data)
	elseif type(data) == "table" and data.type and data.properties then
		-- Session-scoped /event payload format: { type, properties }
		actual_type = data.type
		actual_data = data.properties or {}
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
		return -- Already connected or connecting
	end

	state.manual_disconnect = false
	state.event_buffer = ""
	state.connected = false

	local headers = {
		Accept = "text/event-stream",
		["Cache-Control"] = "no-cache",
	}
	local auth = auth_header()
	if auth then
		headers.Authorization = auth
	end

	-- Send current working directory so the server scopes this
	-- SSE stream to the correct project context
	local cwd = vim.fn.getcwd()
	if cwd and cwd ~= "" then
		headers["x-opencode-directory"] = cwd
	end

	-- Build endpoint path with directory query param for robustness
	local endpoint = M.opts.endpoint or "/event"
	state.directory = normalize_directory(cwd)
	if endpoint ~= "/global/event" and cwd and cwd ~= "" then
		-- Percent-encode the directory for safe URL query param
		local encoded = cwd:gsub("[^A-Za-z0-9%-_.~]", function(c)
			return string.format("%%%02X", c:byte())
		end)
		endpoint = endpoint .. "?directory=" .. encoded
	end

	local stream, err = transport.open_stream({
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
			handle_stream_closed(reason)
		end,
	})

	if not stream then
		local message = err and (err.message or err.error) or "Failed to open SSE stream"
		M.emit("error", message)
		schedule_reconnect()
		return
	end

	state.stream = stream
end

-- Disconnect from SSE stream
function M.disconnect()
	stop_reconnect_timer()
	state.manual_disconnect = true
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
