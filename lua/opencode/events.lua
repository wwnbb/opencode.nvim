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
		["permission.asked"] = "permission", -- Server sends permission.asked
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

	-- Handle message.created - just log, don't add (message_updated handles creation)
	M.on("message", function(data)
		vim.schedule(function()
			local logger = require("opencode.logger")
			logger.debug("message (created) received", { data = data })

			local info = data.info
			if not info then
				logger.debug("message (created): NO INFO")
				return
			end

			local current_session = state.get_session()
			if not current_session.id or info.sessionID ~= current_session.id then
				return
			end

			-- Note: We don't add messages here - message_updated is the primary handler
			-- This avoids race conditions between message.created and message.updated
			logger.debug("message (created): ignoring, waiting for message_updated", {
				role = info.role,
				id = info.id,
			})
		end)
	end)

	-- Handle message.updated - add or update message
	-- This is the PRIMARY way messages get added to the chat (like the TUI)
	M.on("message_updated", function(data)
		vim.schedule(function()
			local logger = require("opencode.logger")
			logger.debug("message_updated received", { data = data })

			local info = data.info
			if not info then
				logger.debug("message_updated: NO INFO")
				return
			end

			local current_session = state.get_session()
			if not current_session.id or info.sessionID ~= current_session.id then
				logger.debug("message_updated: WRONG SESSION", {
					expected = current_session.id,
					received = info.sessionID,
				})
				return
			end

			-- Handle assistant messages (user messages are added locally, ignore from server)
			if info.role == "assistant" then
				local chat_ok, chat = pcall(require, "opencode.ui.chat")
				if not chat_ok then
					return
				end

				-- Check if message already exists
				local messages = chat.get_messages()
				local found = false
				for _, msg in ipairs(messages) do
					if msg.id == info.id then
						found = true
						break
					end
				end

				if not found then
					-- Add new assistant message (content comes via message_part_updated)
					chat.add_message("assistant", "", {
						id = info.id,
						timestamp = os.time(),
					})
					logger.debug("Added assistant message", { id = info.id:sub(1, 10) })
				end

				-- Update status based on message state
				if info.time and info.time.completed then
					state.set_status("idle")
				else
					state.set_status("streaming")
				end
			elseif info.role == "user" then
				-- Ignore user messages from server - they are added locally when sent
				logger.debug("message_updated: ignoring user message from server", { id = info.id })
				return
			else
				logger.debug("message_updated: non-assistant role", { role = info.role })
			end
		end)
	end)

	-- Handle message.part.updated - update chat with streaming content
	M.on("message_part_updated", function(data)
		vim.schedule(function()
			local logger = require("opencode.logger")
			logger.debug("message_part_updated", { data = data })

			local part = data.part
			if not part then
				logger.debug("message_part_updated: NO PART")
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
				-- Update or add text part (only for assistant messages)
				message_parts[msg_id][part.id] = part.text

				-- Assemble full text from all text parts only
				local full_text = ""
				for _, content in pairs(message_parts[msg_id]) do
					if type(content) == "string" then
						full_text = full_text .. content
					end
				end

				-- Update chat UI only if this is an assistant message
				local chat_ok, chat = pcall(require, "opencode.ui.chat")
				if chat_ok and chat.update_assistant_message then
					-- Verify this is an assistant message before updating
					local messages = chat.get_messages()
					local is_assistant = false
					for _, msg in ipairs(messages) do
						if msg.id == msg_id and msg.role == "assistant" then
							is_assistant = true
							break
						end
					end
					if is_assistant then
						chat.update_assistant_message(msg_id, full_text)
					end
				end
			elseif part.type == "reasoning" then
				-- Handle reasoning/thinking part updates
				local logger = require("opencode.logger")

				logger.debug("Reasoning part update", {
					part_id = part.id,
					message_id = msg_id,
					text_length = part.text and #part.text or 0,
				})

				-- Store reasoning text
				message_parts[msg_id][part.id] = {
					type = "reasoning",
					text = part.text or "",
				}

				-- Assemble all reasoning content
				local reasoning_text = ""
				for _, content in pairs(message_parts[msg_id]) do
					if type(content) == "table" and content.type == "reasoning" then
						reasoning_text = reasoning_text .. content.text
					end
				end

				-- Emit reasoning update event
				M.emit("reasoning_update", {
					message_id = msg_id,
					part_id = part.id,
					text = part.text,
					full_reasoning = reasoning_text,
				})

				-- Update chat UI with reasoning
				local chat_ok, chat = pcall(require, "opencode.ui.chat")
				if chat_ok and chat.update_reasoning then
					chat.update_reasoning(msg_id, reasoning_text)
				end
			elseif part.type == "tool" then
				-- Handle tool call updates
				local logger = require("opencode.logger")

				logger.debug("Tool call update", {
					tool = part.tool,
					status = part.state and part.state.status,
					part = part,
				})

				local tool_state = part.state
				if tool_state then
					if tool_state.input then
						logger.debug("Tool input", { input = tool_state.input })
					end

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

							if change_id then
								local diff = require("opencode.ui.diff")
								diff.show(change_id)
							end
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
			local pattern = data.pattern or data.path or data.file or "unknown"

			-- For edit permissions, extract file data and show diff viewer
			if permission_type == "edit" then
				local permission_id = data.id or data.requestID or ("perm_" .. os.time())

				-- Extract file data from metadata
				local metadata = data.metadata or {}
				local files = metadata.files or {}

				logger.debug("Permission request", {
					id = permission_id,
					files_count = #files,
				})

				-- If we have file change data, show the diff viewer for ALL files
				if #files > 0 then
					local changes = require("opencode.artifact.changes")
					local change_ids = {}

					-- Process each file in the permission request
					for i, file_data in ipairs(files) do
						local filepath = file_data.file or file_data.path or file_data.filepath or file_data.filePath
						local original_content = file_data.before or ""
						local modified_content = file_data.after or ""

						-- Skip if no filepath
						if not filepath then
							logger.debug("File missing filepath", { index = i })
							goto continue_file
						end

						-- Ensure filepath is absolute
						if not filepath:match("^/") then
							filepath = "/" .. filepath
						end

						logger.debug("Processing file", {
							index = i,
							filepath = filepath,
							before_length = #original_content,
							after_length = #modified_content,
						})

						-- Add change to the changes module
						local change_id = changes.add_change(filepath, original_content, modified_content, {
							metadata = {
								source = "permission",
								permission_id = permission_id,
								diff = metadata.diff,
								file_index = i,
								total_files = #files,
							},
						})

						if change_id then
							table.insert(change_ids, change_id)
						end

						::continue_file::
					end

					-- Store pending permission for approval callback (with all change IDs)
					if #change_ids > 0 then
						M._pending_permission = {
							id = permission_id,
							change_ids = change_ids,
							current_index = 1,
							type = permission_type,
							pattern = pattern,
							data = data,
						}

						logger.debug("Stored permission", {
							id = permission_id,
							changes_count = #change_ids,
						})

						-- Show the first diff viewer for approval
						local diff = require("opencode.ui.diff")
						diff.show(change_ids[1])
					else
						vim.notify("Failed to create any change records", vim.log.levels.ERROR)
					end
				else
					-- No file data, just show notification
					vim.notify(
						string.format("OpenCode wants to edit: %s (no diff data available)", pattern),
						vim.log.levels.WARN
					)
				end
			elseif permission_type == "bash" then
				vim.notify(string.format("OpenCode wants to run command: %s", pattern), vim.log.levels.WARN)
			else
				vim.notify(
					string.format("Permission request: %s for %s", permission_type, pattern),
					vim.log.levels.INFO
				)
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

			if change_id then
				-- Show the diff viewer for approval
				local diff = require("opencode.ui.diff")
				diff.show(change_id)
			else
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

					if change_id then
						local diff_ui = require("opencode.ui.diff")
						diff_ui.show(change_id)
					end
				end
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
end

return M
