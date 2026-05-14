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

---@param raw_time any
---@return number|nil
local function event_time_to_seconds(raw_time)
	if type(raw_time) ~= "number" then
		return nil
	end
	if raw_time > 100000000000 then
		return math.floor(raw_time / 1000)
	end
	return math.floor(raw_time)
end

---@param payload table|nil
---@return string|nil
local function resolve_event_message_id(payload)
	if type(payload) ~= "table" then
		return nil
	end

	local tool = payload.tool
	if type(tool) == "table" then
		local nested = tool.messageID or tool.message_id or tool.messageId
		if type(nested) == "string" and nested ~= "" then
			return nested
		end
	end

	local direct = payload.messageID or payload.message_id or payload.messageId
	if type(direct) == "string" and direct ~= "" then
		return direct
	end

	return nil
end

---@param payload table|nil
---@return string|nil
local function resolve_event_call_id(payload)
	if type(payload) ~= "table" then
		return nil
	end

	local tool = payload.tool
	if type(tool) == "table" then
		local nested = tool.callID or tool.call_id or tool.callId
		if type(nested) == "string" and nested ~= "" then
			return nested
		end
	end

	local direct = payload.callID or payload.call_id or payload.callId
	if type(direct) == "string" and direct ~= "" then
		return direct
	end

	return nil
end

---@param tool_part table|nil
---@return string|nil
local function resolve_task_child_session_id(tool_part)
	if type(tool_part) ~= "table" or tool_part.tool ~= "task" then
		return nil
	end

	local part_metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}

	return state_metadata.sessionId
		or state_metadata.sessionID
		or state_metadata.childSessionID
		or state_metadata.child_session_id
		or part_metadata.sessionId
		or part_metadata.sessionID
		or part_metadata.childSessionID
		or part_metadata.child_session_id
end

---@param parent_session_id string|nil
---@param child_session_id string|nil
---@return boolean
local function session_owns_task_child(parent_session_id, child_session_id)
	if not parent_session_id or parent_session_id == "" or not child_session_id or child_session_id == "" then
		return false
	end

	local ok_sync, sync = pcall(require, "opencode.sync")
	if not ok_sync then
		return false
	end

	for _, message in ipairs(sync.get_messages(parent_session_id) or {}) do
		for _, part in ipairs(sync.get_message_tools(message.id) or {}) do
			if resolve_task_child_session_id(part) == child_session_id then
				return true
			end
		end
	end

	return false
end

---@param current_session_id string|nil
---@param event_session_id string|nil
---@return boolean
local function permission_session_is_relevant(current_session_id, event_session_id)
	if not event_session_id or event_session_id == "" then
		return true
	end
	if not current_session_id or current_session_id == "" then
		return true
	end
	if event_session_id == current_session_id then
		return true
	end

	return session_owns_task_child(current_session_id, event_session_id)
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
	local logger = require("opencode.logger")

	-- Map SSE events to local events
	local sse_to_local = {
		["message.created"] = "message",
		["message.updated"] = "message_updated",
		["message.removed"] = "message_removed",
		["message.part.updated"] = "message_part_updated",
		["message.part.delta"] = "message_part_delta",
		["message.part.removed"] = "message_part_removed",
		["session.updated"] = "session_updated",
		["session.status"] = "session_status",
		["session.error"] = "session_error",
		["session.diff"] = "session_diff",
		["todo.updated"] = "todo_updated",
		["file.edited"] = "edit",
		["permission.requested"] = "permission",
		["permission.asked"] = "permission", -- Server sends permission.asked
		["permission.replied"] = "permission_replied",
		["question.asked"] = "question_asked",
		["question.replied"] = "question_replied",
		["question.rejected"] = "question_rejected",
		["status.streaming"] = "stream_start",
		["status.idle"] = "stream_end",
		["server.connected"] = "server_connected",
		["server.heartbeat"] = "server_heartbeat",
		["error"] = "error",
	}

	for sse_event, local_event in pairs(sse_to_local) do
		client.on_event(sse_event, function(data)
			logger.debug("SSE event mapped", {
				sse_event = sse_event,
				local_event = local_event,
				sessionID = type(data) == "table" and data.sessionID or nil,
				messageID = type(data) == "table" and (data.messageID or (data.info and data.info.id)) or nil,
				role = type(data) == "table" and data.info and data.info.role or nil,
				part_type = type(data) == "table" and data.part and data.part.type or nil,
				status = type(data) == "table" and data.status and data.status.type or nil,
				error = type(data) == "table" and data.error or nil,
			})
			M.emit(local_event, data)
		end)
	end

	-- Also emit raw SSE events for advanced use
	client.on_event("*", function(event_type, data)
		logger.debug("SSE event received", {
			event_type = event_type,
			mapped = sse_to_local[event_type] ~= nil,
			sessionID = type(data) == "table" and data.sessionID or nil,
			messageID = type(data) == "table" and (data.messageID or (data.info and data.info.id)) or nil,
			role = type(data) == "table" and data.info and data.info.role or nil,
			part_type = type(data) == "table" and data.part and data.part.type or nil,
			status = type(data) == "table" and data.status and data.status.type or nil,
		})
		M.emit("sse_" .. event_type, data)
	end)
end

-- Setup chat update handlers for message events
-- This mirrors the TUI's sync.tsx event handling pattern
function M.setup_chat_handlers()
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local logger = require("opencode.logger")

	---@param session_id string|nil
	---@param reason string
	local function fetch_session_todos(session_id, reason)
		if not session_id or session_id == "" then
			return
		end

		local ok_client, client = pcall(require, "opencode.client")
		if not ok_client or type(client.get_session_todos) ~= "function" then
			return
		end

		client.get_session_todos(session_id, function(err, todos)
			vim.schedule(function()
				if err then
					logger.debug("Session todo sync failed", {
						session_id = session_id,
						reason = reason,
						error = err.message or err.error or tostring(err),
					})
					todos = {}
				end

				sync.handle_todo_updated(session_id, todos or {})
				M.emit("todo_update", {
					session_id = session_id,
					todos = todos or {},
				})

				local current_session = state.get_session()
				if current_session.id == session_id then
					M.emit("chat_render", { session_id = session_id })
				end
			end)
		end)
	end

	---@param part table
	---@param current_session table
	---@return string|nil
	local function resolve_part_session_id(part, current_session)
		local resolved_session_id = part.sessionID

		if not resolved_session_id and part.messageID then
			resolved_session_id = sync.find_message_session_id(part.messageID)
		end

		-- If the backend omits sessionID for streaming chunks, infer current session
		-- while actively streaming so incremental text appears immediately.
		if not resolved_session_id and current_session.id and state.is_streaming() then
			resolved_session_id = current_session.id
		end

		if resolved_session_id then
			part.sessionID = resolved_session_id
		end

		return resolved_session_id
	end

	---@param part table
	---@param current_session table
	---@param resolved_session_id string|nil
	---@return boolean
	local function part_in_current_session(part, current_session, resolved_session_id)
		if not current_session.id then
			return false
		end

		local in_current_session = false
		if part.messageID then
			in_current_session = sync.get_message(current_session.id, part.messageID) ~= nil
		end
		if not in_current_session and resolved_session_id then
			in_current_session = resolved_session_id == current_session.id
		end

		return in_current_session
	end

	---@param part table
	---@param current_session table
	local function emit_part_events(part, current_session)
		if part.type == "text" then
			M.emit("chat_render", { session_id = current_session.id })
			return
		end

		if part.type == "reasoning" then
			M.emit("reasoning_update", {
				message_id = part.messageID,
				part_id = part.id,
				text = part.text,
			})
			M.emit("chat_render", { session_id = current_session.id })
			return
		end

		if part.type == "tool" then
			local tool_state = part.state
			if tool_state then
				M.emit("tool_update", {
					message_id = part.messageID,
					tool_name = part.tool,
					call_id = part.callID,
					status = tool_state.status,
					input = tool_state.input,
					output = tool_state.status == "completed" and tool_state.output or nil,
					error = tool_state.status == "error" and tool_state.error or nil,
				})
			end
			M.emit("chat_render", { session_id = current_session.id })
		end
	end

	-- Handle message.updated - the PRIMARY way messages are added/updated (like TUI sync.tsx:228-265)
	-- This is the ONLY place where messages get added to the store
	M.on("message_updated", function(data)
		vim.schedule(function()
			local info = data.info
			if not info then
				logger.debug("Message update ignored", {
					reason = "missing_info",
				})
				return
			end

			-- Update sync store first (like TUI does)
			sync.handle_message_updated(info)

			local current_session = state.get_session()
			if not current_session.id or info.sessionID ~= current_session.id then
				logger.debug("Message update stored outside current session", {
					message_session = info.sessionID,
					current_session = current_session.id,
					messageID = info.id,
					role = info.role,
				})
				return
			end

			logger.debug("Message update stored for current session", {
				sessionID = info.sessionID,
				messageID = info.id,
				role = info.role,
				agent = info.agent,
				providerID = info.providerID,
				modelID = info.modelID,
				completed = info.time and info.time.completed ~= nil or false,
			})

			-- Note: User messages now come from the server (not added locally)
			-- so we process them like any other message to trigger re-render

			-- Update status based on message state
			-- Only set "streaming" here; "idle" is determined by session.status events
			-- (the backend may set time.completed on each tool call during streaming)
			if info.role == "assistant" then
				if not (info.time and info.time.completed) then
					state.set_status("streaming")
				end
			end

			-- Notify chat UI to re-render
			M.emit("chat_render", { session_id = current_session.id })
		end)
	end)

	-- Handle message.removed (like TUI sync.tsx:267-279)
	M.on("message_removed", function(data)
		vim.schedule(function()
			if data.sessionID and data.messageID then
				sync.handle_message_removed(data.sessionID, data.messageID)

				local current_session = state.get_session()
				if current_session.id == data.sessionID then
					M.emit("chat_render", { session_id = current_session.id })
				end
			end
		end)
	end)

	-- Handle message.part.updated - updates parts in sync store (like TUI sync.tsx:281-299)
	-- Parts contain the actual content (text, reasoning, tool calls)
	M.on("message_part_updated", function(data)
		vim.schedule(function()
			local part = data.part
			if not part then
				logger.debug("Part update ignored", {
					reason = "missing_part",
				})
				return
			end

			local current_session = state.get_session()
			local resolved_session_id = resolve_part_session_id(part, current_session)

			-- Update sync store first (like TUI does)
			sync.handle_part_updated(part)

			if not part_in_current_session(part, current_session, resolved_session_id) then
				logger.debug("Part update stored outside current session", {
					part_session = resolved_session_id,
					current_session = current_session.id,
					partID = part.id,
					messageID = part.messageID,
					type = part.type,
				})
				return
			end

			logger.debug("Part update stored for current session", {
				sessionID = resolved_session_id,
				partID = part.id,
				messageID = part.messageID,
				type = part.type,
			})
			emit_part_events(part, current_session)
		end)
	end)

	-- Handle message.part.delta - incremental token/chunk updates while streaming.
	M.on("message_part_delta", function(data)
		vim.schedule(function()
			if not data then
				logger.debug("Part delta ignored", {
					reason = "missing_data",
				})
				return
			end
			if not data.messageID or not data.partID or not data.field or type(data.delta) ~= "string" then
				logger.debug("Part delta ignored", {
					reason = "malformed",
					messageID = data.messageID,
					partID = data.partID,
					field = data.field,
				})
				return
			end

			local current_session = state.get_session()
			local part_hint = {
				id = data.partID,
				messageID = data.messageID,
				sessionID = data.sessionID,
			}
			local resolved_session_id = resolve_part_session_id(part_hint, current_session)
			local part = sync.handle_part_delta({
				messageID = data.messageID,
				partID = data.partID,
				field = data.field,
				delta = data.delta,
				sessionID = resolved_session_id,
			})
			if not part then
				logger.debug("Part delta ignored", {
					reason = "part_not_found",
					partID = data.partID,
					messageID = data.messageID,
					sessionID = resolved_session_id,
				})
				return
			end

			if not part_in_current_session(part, current_session, resolved_session_id) then
				logger.debug("Part delta stored outside current session", {
					part_session = resolved_session_id,
					current_session = current_session.id,
					partID = part.id,
					messageID = part.messageID,
					type = part.type,
				})
				return
			end

			logger.debug("Part delta stored for current session", {
				sessionID = resolved_session_id,
				partID = part.id,
				messageID = part.messageID,
				field = data.field,
				delta_length = #data.delta,
			})
			emit_part_events(part, current_session)
		end)
	end)

	-- Handle message.part.removed (like TUI sync.tsx:302-314)
	M.on("message_part_removed", function(data)
		vim.schedule(function()
			if data.messageID and data.partID then
				sync.handle_part_removed(data.messageID, data.partID)

				local current_session = state.get_session()
				M.emit("chat_render", { session_id = current_session.id })
			end
		end)
	end)

	-- Handle todo.updated (OpenCode session todo state)
	M.on("todo_updated", function(data)
		vim.schedule(function()
			if type(data) ~= "table" or not data.sessionID then
				logger.debug("Todo update ignored", {
					reason = "malformed",
				})
				return
			end

			local todos = type(data.todos) == "table" and data.todos or {}
			sync.handle_todo_updated(data.sessionID, todos)
			M.emit("todo_update", {
				session_id = data.sessionID,
				todos = todos,
			})

			local current_session = state.get_session()
			if current_session.id ~= data.sessionID then
				logger.debug("Todo update stored outside current session", {
					sessionID = data.sessionID,
					current_session = current_session.id,
					count = #todos,
				})
				return
			end

			logger.debug("Todo update stored for current session", {
				sessionID = data.sessionID,
				count = #todos,
			})
			M.emit("chat_render", { session_id = current_session.id })
		end)
	end)

	-- Retry countdown timer handle
	local retry_timer = nil

	-- Handle session.updated title changes.
	-- OpenCode starts new sessions with a generated default title, then may
	-- rename the session from the first real user prompt.
	M.on("session_updated", function(data)
		vim.schedule(function()
			if not data or type(data.info) ~= "table" then
				return
			end

			local current_session = state.get_session()
			local session_id = data.sessionID or data.info.id
			if not session_id or session_id ~= current_session.id then
				return
			end

			local title = data.info.title
			if title == nil or title == vim.NIL then
				return
			end

			state.set_session(session_id, title)
			M.emit("chat_render", { session_id = session_id })
		end)
	end)

	local function format_session_error(err)
		if type(err) == "string" then
			return err
		end
		if type(err) ~= "table" then
			return tostring(err or "unknown error")
		end
		if type(err.data) == "table" and type(err.data.message) == "string" then
			return err.data.message
		end
		if type(err.message) == "string" then
			return err.message
		end
		if type(err.name) == "string" then
			return err.name
		end
		local ok, encoded = pcall(vim.json.encode, err)
		if ok and encoded and encoded ~= "" then
			return encoded
		end
		return "unknown error"
	end

	-- Handle session.status changes (like TUI sync.tsx:223-225)
	M.on("session_status", function(data)
		vim.schedule(function()
			local sync = require("opencode.sync")
			logger.debug("Session status event handling", {
				sessionID = data and data.sessionID or nil,
				status = data and data.status and data.status.type or data and data.status or nil,
			})
			if not data then
				return
			end

			-- Update sync store first
			if data.sessionID and data.status then
				sync.handle_session_status(data.sessionID, data.status)
			end

			local current_session = state.get_session()
			if data.sessionID ~= current_session.id then
				logger.debug("Session status ignored", {
					reason = "different_session",
					sessionID = data.sessionID,
					current_session = current_session.id,
				})
				return
			end

			local status_type = data.status and data.status.type or data.status
			if status_type == "idle" then
				state.set_status("idle")
			elseif status_type == "busy" or status_type == "streaming" then
				state.set_status("streaming")
			end

			-- Manage retry countdown timer (re-render every second for countdown)
			if status_type == "retry" then
				if not retry_timer then
					retry_timer = vim.uv.new_timer()
					retry_timer:start(
						1000,
						1000,
						vim.schedule_wrap(function()
							-- Check if still in retry state
							local cs = state.get_session()
							local ss = cs.id and sync.get_session_status(cs.id)
							if not ss or ss.type ~= "retry" then
								if retry_timer then
									retry_timer:stop()
									retry_timer:close()
									retry_timer = nil
								end
								return
							end
							M.emit("chat_render", { session_id = cs.id })
						end)
					)
				end
			else
				if retry_timer then
					retry_timer:stop()
					retry_timer:close()
					retry_timer = nil
				end
			end

			-- Trigger chat re-render so status (e.g. retry) is shown in the buffer
			M.emit("chat_render", { session_id = current_session.id })
		end)
	end)

	M.on("session_error", function(data)
		vim.schedule(function()
			local current_session = state.get_session()
			if data and data.sessionID and data.sessionID ~= current_session.id then
				logger.debug("Session error ignored", {
					reason = "different_session",
					sessionID = data.sessionID,
					current_session = current_session.id,
				})
				return
			end

			state.set_status("idle")

			local message = format_session_error(data and data.error)
			logger.debug("Session error handled", {
				sessionID = data and data.sessionID or nil,
				message = message,
			})
			vim.notify("OpenCode session error: " .. message, vim.log.levels.ERROR)

			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.add_message then
				chat.add_message("system", "OpenCode session error: " .. message)
			end

			if current_session.id then
				M.emit("chat_render", { session_id = current_session.id })
			end
		end)
	end)

	M.on("session_change", function(data)
		fetch_session_todos(data and data.id, "session_change")
	end)

	M.on("connected", function()
		local current_session = state.get_session()
		fetch_session_todos(current_session and current_session.id, "connected")
	end)

	-- Clear sync store on session change (skip when navigating into child sessions)
	M.on("session_change", function(data)
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		local is_navigating = chat_ok and chat.is_navigating and chat.is_navigating()
		if is_navigating then
			return
		end
		local sync = require("opencode.sync")
		if data and data.previous_id then
			sync.clear_session(data.previous_id)
		end
	end)

	-- Handle tool updates - specifically edit_file tools to show approval widget
	M.on("tool_update", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local tool_name = data.tool_name or ""
			local status = data.status or ""

			local logger = require("opencode.logger")
			logger.debug("tool_update event", {
				tool = tool_name,
				status = status,
				data = data,
			})

			-- Custom tools are handled via the permission system via native diff review
			if tool_name == "neovim_edit" or tool_name == "neovim_apply_patch" then
				return
			end

			-- Check if this is an edit tool that needs approval
			local is_edit_tool = tool_name == "edit_file"
				or tool_name == "Edit"
				or tool_name == "edit"
				or tool_name == "write_file"
				or tool_name == "Write"
				or tool_name == "apply_patch"
				or tool_name:match("edit")
				or tool_name:match("Edit")
				or tool_name:match("patch")

			-- Show diff for edit tools that are pending or running (before completion)
			-- Status might be: pending, running, completed, error
			local needs_approval = status == "pending" or status == "running" or status == ""

			if is_edit_tool and needs_approval then
				logger.info("Edit tool detected, showing diff", { tool = tool_name })
				-- Tool is pending approval - try to extract file info and show diff
				local input = data.input

				if type(input) == "string" then
					-- Try to parse JSON input
					local ok, parsed = pcall(vim.json.decode, input)
					if ok then
						input = parsed
					end
				end

				if type(input) == "table" then
					local filepath = input.file_path or input.filepath or input.path or input.file
					local new_content = input.new_string or input.content or input.modified or ""
					local old_string = input.old_string or ""

					if filepath then
						-- Read original content
						local original_content = ""
						if vim.fn.filereadable(filepath) == 1 then
							local file = io.open(filepath, "r")
							if file then
								original_content = file:read("*all")
								file:close()
							end
						end

						-- If old_string/new_string pattern (patch-style), reconstruct content
						local modified_content = new_content
						if old_string ~= "" and new_content ~= "" then
							-- This is a replacement operation
							modified_content = original_content:gsub(vim.pesc(old_string), new_content, 1)
						elseif new_content == "" and input.new_string then
							modified_content = original_content:gsub(vim.pesc(old_string), input.new_string, 1)
						end

						if modified_content ~= "" and modified_content ~= original_content then
							-- Add to changes and show diff viewer
							local changes = require("opencode.artifact.changes")
							local change_id = changes.add_change(filepath, original_content, modified_content, {
								metadata = {
									source = "tool_call",
									tool_name = tool_name,
									call_id = data.call_id,
									message_id = data.message_id,
								},
							})
						end
					end
				end
			end
		end)
	end)

	-- Handle permission requests from server
	M.on("permission", function(data)
		vim.schedule(function()
			if not data then
				return
			end

				local logger = require("opencode.logger")
				logger.debug("Permission event received", { data = data })

				-- Show permission notification
				local permission_type = data.permission or data.type
				local metadata = data.metadata or {}
				local current_session = require("opencode.state").get_session()
				local message_id = resolve_event_message_id(data)
				local call_id = resolve_event_call_id(data)
				local timestamp = event_time_to_seconds(data.time and data.time.created)

				local is_native_diff_permission = metadata.opencode_native_diff == true
					or permission_type == "diff_review"
					or permission_type == "neovim_edit"
					or permission_type == "neovim_apply_patch"

				-- Guard: only handle edit/native-diff permissions that belong to the
				-- current session or to a task child session owned by it. Subagent
				-- tool calls run in child sessions, so filtering strictly by the
				-- current session leaves the backend waiting for an edit approval
				-- that the UI never renders.
				if is_native_diff_permission or permission_type == "edit" then
					-- Try to resolve the owning session from the most-reliable source first:
					-- the message ID via the sync store (populated only for the active session),
					-- then the raw sessionID field on the event payload / metadata.
					local event_session_id = nil

					if message_id then
						local ok_sync, sync_mod = pcall(require, "opencode.sync")
						if ok_sync and sync_mod.find_message_session_id then
							event_session_id = sync_mod.find_message_session_id(message_id)
						end
					end

					if not event_session_id or event_session_id == "" then
						event_session_id = data.sessionID
							or data.session_id
							or data.sessionId
							or metadata.sessionID
							or metadata.session_id
							or metadata.sessionId
					end

					-- If we successfully resolved a session and it is neither ours nor
					-- one of our task children, skip it as an unrelated editor/session.
					if not permission_session_is_relevant(current_session.id, event_session_id) then
						local logger_g = require("opencode.logger")
						logger_g.debug("edit permission belongs to an unrelated session, skipping", {
							event_session = event_session_id,
							current_session = current_session.id,
							permission_type = permission_type,
						})
						return
					end
				end

				---@param session_hint table
				---@param event_data table
				---@param event_metadata table
				---@param source_message_id string|nil
				---@return string
				local function resolve_widget_session_id(session_hint, event_data, event_metadata, source_message_id)
					if source_message_id then
						local ok_sync, sync_mod = pcall(require, "opencode.sync")
						if ok_sync and sync_mod.find_message_session_id then
							local msg_session = sync_mod.find_message_session_id(source_message_id)
							if msg_session and msg_session ~= "" then
								return msg_session
							end
						end
					end

					local fallback_session = event_data.sessionID
						or event_data.session_id
						or event_data.sessionId
						or event_metadata.sessionID
						or event_metadata.session_id
						or event_metadata.sessionId
					if fallback_session and fallback_session ~= "" then
						return fallback_session
					end

					return (session_hint and session_hint.id) or ""
				end

				---@param ... any
				---@return string|nil
				local function first_non_empty(...)
					for i = 1, select("#", ...) do
						local value = select(i, ...)
						if type(value) == "string" and value ~= "" then
							return value
						end
					end
					return nil
				end

				---@param diff_text any
				---@return number, number
				local function calc_diff_stats(diff_text)
					if type(diff_text) ~= "string" or diff_text == "" then
						return 0, 0
					end

					local additions = 0
					local deletions = 0
					for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
						if line:sub(1, 3) ~= "+++" and line:sub(1, 1) == "+" then
							additions = additions + 1
						elseif line:sub(1, 3) ~= "---" and line:sub(1, 1) == "-" then
							deletions = deletions + 1
						end
					end

					return additions, deletions
				end

				---@param patterns any
				---@return string|nil
				local function extract_pattern_path(patterns)
					if type(patterns) ~= "table" then
						return nil
					end

					if vim.tbl_islist(patterns) then
						for _, item in ipairs(patterns) do
							if type(item) == "string" and item ~= "" then
								return item
							end
							if type(item) == "table" then
								local nested = first_non_empty(
									item.path,
									item.filepath,
									item.file_path,
									item.file,
									item.pattern
								)
								if nested then
									return nested
								end
							end
						end
						return nil
					end

					return first_non_empty(
						patterns.path,
						patterns.filepath,
						patterns.file_path,
						patterns.file,
						patterns.pattern
					)
				end

				---@param raw_files any
				---@return table
				local function normalize_edit_files(raw_files)
					if type(raw_files) ~= "table" then
						return {}
					end
					if vim.tbl_islist(raw_files) then
						return raw_files
					end
					return { raw_files }
				end

				---@param event_data table
				---@param event_metadata table
				---@return table
				local function synthesize_edit_files(event_data, event_metadata)
					local path = first_non_empty(
						event_metadata.filepath,
						event_metadata.file_path,
						event_metadata.file,
						event_metadata.path,
						event_data.filepath,
						event_data.file_path,
						event_data.file,
						event_data.path,
						event_metadata.pattern,
						event_data.pattern,
						extract_pattern_path(event_metadata.patterns),
						extract_pattern_path(event_data.patterns)
					) or "(pending edit)"

					local before = event_metadata.before or event_data.before or ""
					local after = event_metadata.after or event_data.after or event_metadata.content or event_data.content or ""
					local diff = first_non_empty(event_metadata.diff, event_data.diff, event_metadata.patch, event_data.patch)
					local diff_additions, diff_deletions = calc_diff_stats(diff)

					return {
						{
							filePath = path,
							relativePath = vim.fn.fnamemodify(path, ":."),
							before = before,
							after = after,
							diff = diff,
							additions = event_metadata.additions or event_data.additions or diff_additions,
							deletions = event_metadata.deletions or event_data.deletions or diff_deletions,
							type = event_metadata.type or event_data.type or "update",
						},
					}
				end

				if is_native_diff_permission or permission_type == "edit" then
					local permission_id = data.id or data.requestID or ("perm_" .. os.time())
					local edit_state_mod = require("opencode.edit.state")

					-- Skip if already handled (dedup for duplicate SSE events)
					if edit_state_mod.get_edit(permission_id) then
						logger.debug("edit permission already handled, skipping", {
							id = permission_id,
							type = permission_type,
						})
						return
					end

					local nd_files = normalize_edit_files(metadata.files)
					if #nd_files == 0 then
						nd_files = synthesize_edit_files(data, metadata)
					end
					local edit_session_id = resolve_widget_session_id(current_session, data, metadata, message_id)
					local review_mode = "interactive"
					if permission_type == "edit" and not is_native_diff_permission then
						review_mode = "readonly"
					end

					edit_state_mod.add_edit(permission_id, edit_session_id, nd_files, {
						data = data,
						metadata = metadata,
						message_id = message_id,
						call_id = call_id,
						review_mode = review_mode,
						timestamp = timestamp,
					})

					-- Stop spinner so user can interact
					local spinner_ok, perm_spinner = pcall(require, "opencode.ui.spinner")
					if spinner_ok and perm_spinner.is_active and perm_spinner.is_active() then
						perm_spinner.stop()
					end

					-- Add to chat as edit widget
					local chat_ok, chat = pcall(require, "opencode.ui.chat")
					if chat_ok and chat.add_edit_message then
						chat.add_edit_message(permission_id, edit_state_mod.get_edit(permission_id), "pending")
					end
					return
				else
					-- Non-edit permission: handle interactively via permission state + chat widget
					local permission_id = data.id or data.requestID or ("perm_" .. os.time())
					local permission_session_id = resolve_widget_session_id(current_session, data, metadata, message_id)

					-- Resolve tool_input from sync store if tool info is available
					local tool_input = {}
					if message_id and call_id then
						local sync = require("opencode.sync")
						local parts = sync.get_parts(message_id)
						for _, part in ipairs(parts) do
							if part.callID == call_id and part.state and part.state.input then
								tool_input = part.state.input
								break
							end
						end
					end

					-- Fallback: extract input fields from metadata and top-level data fields
					if not next(tool_input) then
						tool_input = vim.tbl_deep_extend("force", {}, metadata.input or {}, {
							command = data.command or metadata.command,
							description = data.description or metadata.description,
							path = data.path or metadata.path or data.filepath or metadata.filepath,
							file_path = data.file_path or metadata.file_path or data.file or metadata.file or data.filepath
								or metadata.filepath,
							pattern = data.pattern or metadata.pattern,
							query = data.query or metadata.query,
							url = data.url or metadata.url,
							directory = data.directory or metadata.directory or data.parentDir or metadata.parentDir,
							subagent_type = data.subagent_type or metadata.subagent_type,
						})
					end

					-- Store permission state
					local perm_state_mod = require("opencode.permission.state")
					perm_state_mod.add_permission(permission_id, permission_session_id, permission_type, {
						metadata = metadata,
						patterns = data.patterns or {},
						always = data.always or {},
						tool_input = tool_input,
						message_id = message_id,
						call_id = call_id,
						timestamp = timestamp,
					})

					-- Stop spinner so user can interact
					local spinner_ok2, perm_spinner = pcall(require, "opencode.ui.spinner")
					if spinner_ok2 and perm_spinner.is_active() then
						perm_spinner.stop()
						logger.debug("Stopped spinner for permission interaction")
					end

					-- Add to chat as a special message
					local chat_ok2, chat2 = pcall(require, "opencode.ui.chat")
					if chat_ok2 and chat2.add_permission_message then
						chat2.add_permission_message(permission_id, perm_state_mod.get_permission(permission_id), "pending")
					end

					logger.info("Permission request added", {
						permission_id = permission_id,
						type = permission_type,
					})
				end
		end)
	end)

	-- Handle file edit events - show approval widget with diff viewer
	M.on("edit", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local filepath = data.file or data.filepath
			local original_content = data.original or data.original_content or ""
			local modified_content = data.modified or data.modified_content or data.content or ""

			if not filepath then
				vim.notify("Edit event missing filepath", vim.log.levels.WARN)
				return
			end

			-- If no original content provided, try to read from file
			if original_content == "" and vim.fn.filereadable(filepath) == 1 then
				local file = io.open(filepath, "r")
				if file then
					original_content = file:read("*all")
					file:close()
				end
			end

			-- If no modified content, nothing to show
			if modified_content == "" then
				vim.notify("File edited: " .. filepath, vim.log.levels.INFO)
				return
			end

			-- Add change to the changes module
			local changes = require("opencode.artifact.changes")
			local change_id = changes.add_change(filepath, original_content, modified_content, {
				metadata = {
					source = "server",
					session_id = data.sessionID,
				},
			})

			if not change_id then
				vim.notify("Failed to create change record for: " .. filepath, vim.log.levels.ERROR)
			end
		end)
	end)

	-- Handle session.diff events (alternative edit format)
	M.on("session_diff", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			-- session.diff may contain multiple file changes
			local diffs = data.diffs or { data }

			for _, diff_data in ipairs(diffs) do
				local filepath = diff_data.file or diff_data.filepath
				local original = diff_data.original or ""
				local modified = diff_data.modified or diff_data.content or ""

				if filepath and modified ~= "" then
					-- Read original if not provided
					if original == "" and vim.fn.filereadable(filepath) == 1 then
						local file = io.open(filepath, "r")
						if file then
							original = file:read("*all")
							file:close()
						end
					end

					local changes = require("opencode.artifact.changes")
					local change_id = changes.add_change(filepath, original, modified, {
						metadata = {
							source = "session_diff",
							session_id = data.sessionID,
						},
					})
				end
			end
		end)
	end)
end

-- Setup question event handlers
function M.setup_question_handlers()
	local state = require("opencode.state")
	local question_state = require("opencode.question.state")

	-- Handle question.asked - store question and trigger UI update
	M.on("question_asked", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			logger.debug("Question asked event received", { data = data })

			local request_id = data.requestID or data.id
			local session_id = data.sessionID
			local message_id = resolve_event_message_id(data)
			local questions = data.questions
			local timestamp = event_time_to_seconds(data.time and data.time.created)

			if not request_id or not questions then
				logger.warn(
					"Invalid question data",
					{ data = data, request_id = request_id, has_questions = questions ~= nil }
				)
				return
			end

			local current_session = state.get_session()
			if message_id then
				local ok_sync, sync = pcall(require, "opencode.sync")
				if ok_sync and sync.find_message_session_id then
					session_id = sync.find_message_session_id(message_id) or session_id
				end
			end
			session_id = session_id or (current_session and current_session.id) or ""

			-- Store question state (allow questions from subagent/child sessions)
			question_state.add_question(request_id, session_id, questions, {
				timestamp = timestamp,
			})

			-- Stop the spinner so user can interact with the question
			local spinner_ok, spinner = pcall(require, "opencode.ui.spinner")
			if spinner_ok and spinner.is_active() then
				spinner.stop()
				logger.debug("Stopped spinner for question interaction")
			end

			-- Add to chat as a special message
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.add_question_message then
				chat.add_question_message(request_id, questions, "pending", {
					message_id = message_id,
					source_session_id = session_id,
					timestamp = timestamp,
				})
			end

			logger.info("Question added", { request_id = request_id:sub(1, 10), count = #questions })
		end)
	end)

	-- Handle question.replied - mark as answered
	M.on("question_replied", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			local request_id = data.requestID

			if not request_id then
				return
			end

			-- Mark as answered
			question_state.mark_answered(request_id, data.answers)

			-- Update chat UI
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.update_question_status then
				chat.update_question_status(request_id, "answered", data.answers)
			end

			logger.debug("Question answered", { request_id = request_id:sub(1, 10) })
		end)
	end)

	-- Handle question.rejected - mark as rejected
	M.on("question_rejected", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			local request_id = data.requestID

			if not request_id then
				return
			end

			-- Mark as rejected
			question_state.mark_rejected(request_id)

			-- Update chat UI
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.update_question_status then
				chat.update_question_status(request_id, "rejected")
			end

			logger.debug("Question rejected", { request_id = request_id:sub(1, 10) })
		end)
	end)

	-- Clear questions on session change (skip when navigating into child sessions)
	M.on("session_change", function()
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		local is_navigating = chat_ok and chat.is_navigating and chat.is_navigating()
		if not is_navigating then
			question_state.clear_all()
		end
	end)
end

-- Setup sync data handlers (providers, agents, config)
-- This mirrors TUI's initial data loading when connecting
function M.setup_sync_data_handlers()
	local sync = require("opencode.sync")
	local client = require("opencode.client")
	local logger = require("opencode.logger")

	---@param value any
	---@return string
	local function value_kind(value)
		if value == nil then
			return "nil"
		end
		if value == vim.NIL then
			return "vim.NIL"
		end
		return type(value)
	end

	---@param tbl table|nil
	---@return number
	local function count_keys(tbl)
		local count = 0
		if type(tbl) ~= "table" then
			return count
		end
		for _, _ in pairs(tbl) do
			count = count + 1
		end
		return count
	end

	---@param providers table[]
	---@param defaults table|nil
	---@return table
	local function summarize_providers(providers, defaults)
		local sample = {}
		local model_count = 0
		for _, provider in ipairs(providers or {}) do
			local provider_model_count = count_keys(provider.models)
			model_count = model_count + provider_model_count
			if #sample < 6 then
				table.insert(sample, {
					id = provider.id,
					name = provider.name,
					model_count = provider_model_count,
					default_model = type(provider.id) == "string" and defaults and defaults[provider.id] or nil,
				})
			end
		end
		return {
			count = #(providers or {}),
			model_count = model_count,
			default_count = count_keys(defaults),
			sample = sample,
		}
	end

	---@param agents table[]
	---@return table
	local function summarize_agents(agents)
		local visible = {}
		local hidden_true_count = 0
		local hidden_null_count = 0
		local subagent_count = 0
		for _, agent in ipairs(agents or {}) do
			if agent.hidden == true then
				hidden_true_count = hidden_true_count + 1
			elseif agent.hidden == vim.NIL then
				hidden_null_count = hidden_null_count + 1
			end
			if agent.mode == "subagent" then
				subagent_count = subagent_count + 1
			end
			if sync.is_visible_agent(agent) and #visible < 8 then
				table.insert(visible, agent.name or agent.id)
			end
		end
		return {
			count = #(agents or {}),
			visible_count = #sync.get_visible_agents(),
			visible_sample = visible,
			hidden_true_count = hidden_true_count,
			hidden_null_count = hidden_null_count,
			subagent_count = subagent_count,
		}
	end

	-- Update input info bar when providers/agents load (if input is visible)
	local function refresh_input_info_bar()
		local input_ok, input = pcall(require, "opencode.ui.input")
		if input_ok and input.is_visible and input.is_visible() then
			input.update_info_bar()
		end
	end

	M.on("providers_loaded", function()
		refresh_input_info_bar()
	end)

	M.on("agents_loaded", function()
		refresh_input_info_bar()
	end)

	M.on("config_loaded", function()
		refresh_input_info_bar()
	end)

	-- Fetch initial data when connected (like TUI does on startup)
	M.on("connected", function()
		vim.schedule(function()
			logger.debug("Fetching initial sync data (providers, agents, config, skills)")

			-- Fetch providers with models (using /config/providers like TUI does)
			-- This returns { providers: Provider[], default: { providerID: modelID } }
			client.get_config_providers(function(err, data)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch config providers", { error = err })
						return
					end
					if data then
						-- Handle providers array
						local providers = data.providers or {}
						sync.handle_providers(providers)

						-- Handle defaults mapping
						if data.default then
							sync.handle_provider_defaults(data.default)
						end

						logger.debug("Providers loaded", summarize_providers(providers, data.default))

						-- Emit event for UI updates
						M.emit("providers_loaded", providers)

						-- Warn if no providers are connected
						if #providers == 0 then
							logger.warn("No providers connected. Use :OpenCode command palette to connect a provider.")
						end
					end
				end)
			end)

			-- Fetch agents
			client.list_agents(function(err, agents)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch agents", { error = err })
						return
					end
					if agents then
						sync.handle_agents(agents)
						-- Emit event for UI updates
						M.emit("agents_loaded", agents)
						logger.debug("Agents loaded", summarize_agents(agents))
					end
				end)
			end)

			-- Fetch config
			client.get_config(function(err, config)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch config", { error = err })
						return
					end
					if config then
						sync.handle_config(config)
						-- Handle commands from config
						if config.command then
							sync.handle_commands(config.command)
						end
						M.emit("config_loaded", config)
						logger.debug("Config loaded", {
							model = config.model,
							model_kind = value_kind(config.model),
							default_agent = config.default_agent,
							command_count = count_keys(config.command),
						})
					end
				end)
			end)

			-- Fetch skills
			client.list_skills(function(err, skills)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch skills", { error = err })
						return
					end
					sync.handle_skills(skills)
					M.emit("skills_loaded", skills)
					logger.debug("Skills loaded", { count = skills and #skills or 0 })
				end)
			end)

			-- Fetch MCP status
			client.get_mcp_status(function(err, mcp)
				vim.schedule(function()
					if not err and mcp then
						sync.handle_mcp(mcp)
						logger.debug("MCP status loaded")
					end
				end)
			end)
		end)
	end)
end

-- Setup permission event handlers
function M.setup_permission_handlers()
	local app_state = require("opencode.state")
	local logger = require("opencode.logger")

	-- Clear permissions and edits on session change (skip when navigating into child sessions)
	M.on("session_change", function()
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		local is_navigating = chat_ok and chat.is_navigating and chat.is_navigating()
		if is_navigating then
			return
		end
		local perm_state_ok, perm_state = pcall(require, "opencode.permission.state")
		if perm_state_ok then
			perm_state.clear_all()
		end
		local edit_state_ok, edit_state_mod = pcall(require, "opencode.edit.state")
		if edit_state_ok then
			edit_state_mod.clear_all()
		end
	end)

	-- OpenCode clients treat permission.replied as the lifecycle event that resolves
	-- the active request. Keep local permission/edit widgets in step with the
	-- server even when the reply was sent by another UI or arrives before the
	-- HTTP callback completes.
	M.on("permission_replied", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local permission_id = data.requestID or data.permissionID or data.id
			if not permission_id or permission_id == "" then
				return
			end

			local reply = data.reply or data.response
			local changed = false

			local perm_state_ok, perm_state_mod = pcall(require, "opencode.permission.state")
			if perm_state_ok and perm_state_mod.has_permission and perm_state_mod.has_permission(permission_id) then
				if reply == "reject" then
					changed = perm_state_mod.mark_rejected(permission_id) or changed
				else
					changed = perm_state_mod.mark_approved(permission_id, reply == "always" and "always" or "once")
						or changed
				end

				local chat_ok, chat = pcall(require, "opencode.ui.chat")
				if chat_ok and chat.update_permission_status then
					chat.update_permission_status(permission_id, reply == "reject" and "rejected" or "approved")
				end
			end

			local edit_state_ok, edit_state_mod = pcall(require, "opencode.edit.state")
			if edit_state_ok and edit_state_mod.get_edit and edit_state_mod.get_edit(permission_id) then
				edit_state_mod.mark_sent(permission_id)
				changed = true
			end

			if changed then
				local session = app_state.get_session()
				M.emit("chat_render", { session_id = data.sessionID or (session and session.id) })
				logger.debug("Permission reply handled", {
					permission_id = permission_id,
					reply = reply,
					sessionID = data.sessionID,
				})
			end
		end)
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

	local ok4, err4 = pcall(M.setup_question_handlers)
	if not ok4 then
		vim.notify("Failed to setup question handlers: " .. tostring(err4), vim.log.levels.WARN)
	end

	local ok5, err5 = pcall(M.setup_sync_data_handlers)
	if not ok5 then
		vim.notify("Failed to setup sync data handlers: " .. tostring(err5), vim.log.levels.WARN)
	end

	local ok6, err6 = pcall(M.setup_permission_handlers)
	if not ok6 then
		vim.notify("Failed to setup permission handlers: " .. tostring(err6), vim.log.levels.WARN)
	end
end

return M
