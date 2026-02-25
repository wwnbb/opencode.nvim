-- opencode.nvim - SSE (Server-Sent Events) client
-- Handles real-time event streaming from OpenCode server

local M = {}

-- Check for plenary.nvim dependency
local has_plenary, Job = pcall(require, "plenary.job")
if not has_plenary then
	vim.notify("opencode.nvim requires plenary.nvim. Please install nvim-lua/plenary.nvim", vim.log.levels.ERROR)
	return M
end

-- Configuration
M.opts = {
	host = "localhost",
	port = 9099,
	endpoint = "/event", -- Matches TUI's session-scoped event stream
	auth = {
		username = "opencode",
		password = nil,
	},
	reconnect = true,
	reconnect_delay = 5000,
	max_reconnects = 5,
}

-- Internal state
local state = {
	job = nil,
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

-- Build SSE endpoint URL
local function sse_url()
	local url = string.format("http://%s:%d%s", M.opts.host, M.opts.port, M.opts.endpoint or "/event")
	return url
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
	-- Process line-by-line to handle both chunked and line-delimited stdout behavior.
	-- Some job backends do not preserve SSE blank separators reliably.
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
	if state.job then
		return -- Already connected or connecting
	end

	local url = sse_url()
	local args = { "-sS", "-N", "-H", "Accept: text/event-stream" }

	-- Add auth if configured
	if M.opts.auth.password then
		local credentials = string.format("%s:%s", M.opts.auth.username, M.opts.auth.password)
		table.insert(args, "-u")
		table.insert(args, credentials)
	end

	table.insert(args, url)

	state.event_buffer = ""
	state.connected = false

	state.job = Job:new({
		command = "curl",
		args = args,
		on_stdout = function(_, data)
			if data then
				state.event_buffer = state.event_buffer .. data .. "\n"
				vim.schedule(process_buffer)
			end
		end,
		on_stderr = function(_, data)
			if data then
				vim.schedule(function()
					M.emit("error", data)
				end)
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				emit_current_event()
				state.job = nil
				state.connected = false

				if code ~= 0 then
					M.emit("disconnected", "Connection closed with code: " .. code)

					-- Auto-reconnect if enabled
					if M.opts.reconnect and state.reconnect_count < M.opts.max_reconnects then
						state.reconnect_count = state.reconnect_count + 1
						vim.defer_fn(function()
							M.connect()
						end, M.opts.reconnect_delay)
					end
				else
					M.emit("disconnected", "Connection closed normally")
				end
			end)
		end,
	})

	state.job:start()
	state.connected = true
	state.reconnect_count = 0
	M.emit("connected", nil)
end

-- Disconnect from SSE stream
function M.disconnect()
	if state.job then
		state.job:shutdown()
		state.job = nil
	end
	state.connected = false
end

-- Check if connected
function M.is_connected()
	return state.connected and state.job ~= nil
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
		has_job = state.job ~= nil,
	}
end

return M
