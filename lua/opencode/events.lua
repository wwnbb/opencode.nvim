-- opencode.nvim - Event system module
-- Pub/sub event bus for inter-module communication

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
		time = vim.loop.now(),
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

-- Get count of listeners for an event type
---@param event_type string
---@return number Count of registered listeners
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

-- Setup automatic state change event emission
-- This bridges the state module with the event system
function M.setup_state_bridge()
	local state = require("opencode.state")

	-- Subscribe to state changes and emit corresponding events
	state.on("connection", function(new_val, old_val)
		M.emit("connection_change", { new = new_val, old = old_val })

		if new_val == "connected" then
			M.emit("connected", {})
		elseif new_val == "idle" and old_val == "connected" then
			M.emit("disconnected", { reason = "state_change" })
		end
	end)

	state.on("status", function(new_val, old_val)
		M.emit("status_change", { status = new_val, previous = old_val })
	end)

	state.on("session.id", function(new_val, old_val)
		M.emit("session_change", { id = new_val, previous_id = old_val })
	end)

	state.on("model.id", function(new_val, old_val)
		M.emit("model_change", { model = new_val, previous = old_val })
	end)

	state.on("agent.id", function(new_val, old_val)
		M.emit("agent_change", { agent = new_val, previous = old_val })
	end)

	-- Bridge pending changes events
	state.on("pending_changes.files", function(new_val, old_val)
		M.emit("changes_update", {
			files = new_val,
			stats = state.get_pending_changes_stats(),
		})
	end)
end

-- Setup SSE event bridge
-- This bridges server-sent events to the local event system
function M.setup_sse_bridge()
	local client = require("opencode.client")

	-- Map SSE events to local events
	local sse_to_local = {
		["message.created"] = "message",
		["message.updated"] = "message_updated",
		["message.removed"] = "message_removed",
		["message.part.updated"] = "message_part_updated",
		["message.part.removed"] = "message_part_removed",
		["session.updated"] = "session_updated",
		["session.status"] = "session_status",
		["session.diff"] = "session_diff",
		["file.edited"] = "edit",
		["permission.requested"] = "permission",
		["status.streaming"] = "stream_start",
		["status.idle"] = "stream_end",
		["server.connected"] = "server_connected",
		["server.heartbeat"] = "server_heartbeat",
		["error"] = "error",
	}

	for sse_event, local_event in pairs(sse_to_local) do
		client.on_event(sse_event, function(data)
			M.emit(local_event, data)
		end)
	end

	-- Also emit raw SSE events for advanced use
	client.on_event("*", function(event_type, data)
		M.emit("sse_" .. event_type, data)
	end)
end

-- Setup chat update handlers for message events
function M.setup_chat_handlers()
	local state = require("opencode.state")

	-- Track message parts for streaming assembly
	local message_parts = {}

	-- Handle message.updated - update chat with assistant message info
	M.on("message_updated", function(data)
		vim.schedule(function()
			local info = data.info
			if not info then
				return
			end

			local current_session = state.get_session()
			if not current_session.id or info.sessionID ~= current_session.id then
				return
			end

			-- Update status based on message state
			if info.role == "assistant" then
				if info.time and info.time.completed then
					state.set_status("idle")
				else
					state.set_status("streaming")
				end
			end
		end)
	end)

	-- Handle message.part.updated - update chat with streaming content
	M.on("message_part_updated", function(data)
		vim.schedule(function()
			local part = data.part
			if not part then
				return
			end

			local current_session = state.get_session()
			if not current_session.id or part.sessionID ~= current_session.id then
				return
			end

			local msg_id = part.messageID

			-- Track parts by message ID
			message_parts[msg_id] = message_parts[msg_id] or {}

			if part.type == "text" then
				-- Update or add text part
				message_parts[msg_id][part.id] = part.text

				-- Assemble full text from all parts
				local full_text = ""
				for _, text in pairs(message_parts[msg_id]) do
					if type(text) == "string" then
						full_text = full_text .. text
					end
				end

				-- Update chat UI
				local chat_ok, chat = pcall(require, "opencode.ui.chat")
				if chat_ok and chat.update_assistant_message then
					chat.update_assistant_message(msg_id, full_text)
				end
			elseif part.type == "tool" then
				-- Handle tool call updates
				local chat_ok, chat = pcall(require, "opencode.ui.chat")
				if chat_ok then
					local tool_state = part.state
					if tool_state then
						M.emit("tool_update", {
							message_id = msg_id,
							tool_name = part.tool,
							call_id = part.callID,
							status = tool_state.status,
							input = tool_state.input,
							output = tool_state.status == "completed" and tool_state.output or nil,
							error = tool_state.status == "error" and tool_state.error or nil,
						})
					end
				end
			end
		end)
	end)

	-- Handle session.status changes
	M.on("session_status", function(data)
		vim.schedule(function()
			local current_session = state.get_session()
			if data.sessionID ~= current_session.id then
				return
			end

			if data.status == "idle" then
				state.set_status("idle")
			elseif data.status == "busy" or data.status == "streaming" then
				state.set_status("streaming")
			end
		end)
	end)

	-- Clear message parts cache on session change
	M.on("session_change", function()
		message_parts = {}
	end)
end

-- Initialize event system with bridges
function M.setup()
	-- Setup bridges to other systems
	local ok1, err1 = pcall(M.setup_state_bridge)
	if not ok1 then
		vim.notify("Failed to setup state bridge: " .. tostring(err1), vim.log.levels.WARN)
	end

	local ok2, err2 = pcall(M.setup_sse_bridge)
	if not ok2 then
		vim.notify("Failed to setup SSE bridge: " .. tostring(err2), vim.log.levels.WARN)
	end

	local ok3, err3 = pcall(M.setup_chat_handlers)
	if not ok3 then
		vim.notify("Failed to setup chat handlers: " .. tostring(err3), vim.log.levels.WARN)
	end
end

return M
