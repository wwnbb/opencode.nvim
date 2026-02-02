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
	event_id = nil,
}

-- Event callbacks registry
local listeners = {}

-- Build SSE endpoint URL
local function sse_url()
	local url = string.format("http://%s:%d/global/event", M.opts.host, M.opts.port)
	return url
end

-- Parse SSE event from buffer
local function parse_sse_event(data)
	local event = {
		id = nil,
		event = "message",
		data = nil,
	}

	local lines = vim.split(data, "\n", { plain = true })
	local data_lines = {}

	for _, line in ipairs(lines) do
		if line:sub(1, 5) == "data:" then
			table.insert(data_lines, line:sub(6):match("^%s*(.+)$") or "")
		elseif line:sub(1, 7) == "event:" then
			event.event = line:sub(8):match("^%s*(.+)$") or "message"
		elseif line:sub(1, 4) == "id:" then
			event.id = line:sub(5):match("^%s*(.+)$")
		end
	end

	if #data_lines > 0 then
		event.data = table.concat(data_lines, "\n")
	end

	return event
end

-- Process SSE data buffer
local function process_buffer()
	-- Look for complete events (double newline)
	while true do
		local event_end = state.event_buffer:find("\n\n", 1, true)
		if not event_end then
			event_end = state.event_buffer:find("\r\n\r\n", 1, true)
		end
		if not event_end then
			break
		end

		local event_data = state.event_buffer:sub(1, event_end - 1)
		state.event_buffer = state.event_buffer:sub(event_end + 2)

		local event = parse_sse_event(event_data)
		if event.data then
			-- DEBUG: Log all SSE events
			vim.schedule(function()
				vim.notify(string.format("[SSE] Event: %s", event.event), vim.log.levels.DEBUG)
			end)

			-- Parse JSON data
			local ok, parsed = pcall(vim.json.decode, event.data)
			if ok and parsed then
				vim.schedule(function()
					vim.notify(string.format("[SSE] Parsed %s successfully", event.event), vim.log.levels.DEBUG)
				end)
				M.emit(event.event, parsed, event.id)
			else
				vim.schedule(function()
					vim.notify(string.format("[SSE] JSON parse FAILED for %s: %s", event.event, tostring(parsed)), vim.log.levels.DEBUG)
				end)
				-- Emit raw data if JSON parsing fails
				M.emit(event.event, event.data, event.id)
			end
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
