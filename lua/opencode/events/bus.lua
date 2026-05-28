-- opencode.nvim - Event system module
-- Pub/sub event bus for inter-module communication

---@class OpencodeEventBus
local M = {}

-- Event registry: { event_type = { callback1, callback2, ... } }
local listeners = {}

-- One-time listeners registry
local once_listeners = {}

-- Event history (for debugging/playback)
local event_history = {}

local max_history = 100

-- Get or create listener list for an event type
local function get_listeners(event_type)
	listeners[event_type] = listeners[event_type] or {}
	return listeners[event_type]
end

-- Subscribe to an event
---@param event_type string Event type to listen for (e.g., "message", "connected")
---@param callback function Callback function(data)
function M.on(event_type, callback)
	local cbs = get_listeners(event_type)
	table.insert(cbs, callback)
	return callback -- Return callback for off() reference
end

-- Subscribe to an event (one-time only)
---@param event_type string Event type to listen for
---@param callback function Callback function(data)
function M.once(event_type, callback)
	once_listeners[event_type] = once_listeners[event_type] or {}
	table.insert(once_listeners[event_type], callback)
	return callback
end

-- Unsubscribe from an event
---@param event_type string Event type
---@param callback function Callback to remove (must be same reference as passed to on())
function M.off(event_type, callback)
	local cbs = listeners[event_type]
	if not cbs then
		return
	end

	for i, cb in ipairs(cbs) do
		if cb == callback then
			table.remove(cbs, i)
			break
		end
	end

	-- Also check once listeners
	local once_cbs = once_listeners[event_type]
	if once_cbs then
		for i, cb in ipairs(once_cbs) do
			if cb == callback then
				table.remove(once_cbs, i)
				break
			end
		end
	end
end

-- Emit an event to all subscribers
---@param event_type string Event type
---@param data any Event data payload
function M.emit(event_type, data)
	-- Record in history
	table.insert(event_history, 1, {
		type = event_type,
		data = data,
		time = vim.uv.now(),
	})

	-- Trim history
	if #event_history > max_history then
		table.remove(event_history)
	end

	-- Call regular listeners
	local cbs = listeners[event_type] or {}
	for _, cb in ipairs(cbs) do
		local ok, err = pcall(cb, data)
		if not ok then
			vim.notify(string.format("Event listener error (%s): %s", event_type, tostring(err)), vim.log.levels.ERROR)
		end
	end

	-- Call and clear once listeners
	local once_cbs = once_listeners[event_type]
	if once_cbs then
		for _, cb in ipairs(once_cbs) do
			local ok, err = pcall(cb, data)
			if not ok then
				vim.notify(
					string.format("Event once-listener error (%s): %s", event_type, tostring(err)),
					vim.log.levels.ERROR
				)
			end
		end
		once_listeners[event_type] = {}
	end
end

-- Get event history
---@param limit? number Maximum number of events to return
---@return table Array of {type, data, time}
function M.get_history(limit)
	limit = limit or max_history
	local result = {}
	for i = 1, math.min(limit, #event_history) do
		table.insert(result, event_history[i])
	end
	return result
end

-- Clear event history
function M.clear_history()
	event_history = {}
end

-- Clear all listeners for an event type (or all events if nil)
---@param event_type? string Specific event type, or nil for all
function M.clear(event_type)
	if event_type then
		listeners[event_type] = {}
		once_listeners[event_type] = {}
	else
		listeners = {}
		once_listeners = {}
	end
end

function M.listener_count(event_type)
	local cbs = listeners[event_type] or {}
	local once_cbs = once_listeners[event_type] or {}
	return #cbs + #once_cbs
end

-- List all event types with listeners
---@return table Array of event type names
function M.list_event_types()
	local types = {}
	for event_type, _ in pairs(listeners) do
		table.insert(types, event_type)
	end
	return types
end

return M
