-- opencode.nvim - SSE (Server-Sent Events) client
-- Handles real-time event streaming from OpenCode server

local M = {}
local transport = require("opencode.client.transport")
local uv = vim.uv

-- Configuration
M.opts = {
	host = "localhost",
	endpoint = "/event", -- Matches TUI's session-scoped event stream
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
}

-- Event callbacks registry
local listeners = {}

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

-- Emit event to all listeners
function M.emit(event_type, data, event_id)
	-- Handle wrapped global event format: {directory, payload: {type, properties}}
	local actual_type = event_type
	local actual_data = data

	if type(data) == "table" and data.payload and data.payload.type then
		actual_type = data.payload.type
		actual_data = data.payload.properties or {}
		actual_data._directory = data.directory
	elseif type(data) == "table" and data.type and data.properties then
		-- Session-scoped /event payload format: { type, properties }
		actual_type = data.type
		actual_data = data.properties or {}
	end

	local callbacks = listeners[actual_type] or {}
	for _, cb in ipairs(callbacks) do
		local ok, err = pcall(cb, actual_data, event_id)
		if not ok then
			vim.notify("SSE listener error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end

	-- Also emit to wildcard listeners
	local wildcards = listeners["*"] or {}
	for _, cb in ipairs(wildcards) do
		local ok, err = pcall(cb, actual_type, actual_data, event_id)
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
	if cwd and cwd ~= "" then
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

return M
