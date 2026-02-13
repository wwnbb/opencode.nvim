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
		["question.asked"] = "question_asked",
		["question.replied"] = "question_replied",
		["question.rejected"] = "question_rejected",
		["status.streaming"] = "stream_start",
		["status.idle"] = "stream_end",
		["server.connected"] = "server_connected",
		["server.heartbeat"] = "server_heartbeat",
		["error"] = "error",
	}

	local logger = require("opencode.logger")

	for sse_event, local_event in pairs(sse_to_local) do
		client.on_event(sse_event, function(data)
			-- Log all SSE events
			logger.debug("SSE event: " .. sse_event, { data = data })
			M.emit(local_event, data)
		end)
	end

	-- Also emit raw SSE events for advanced use and log them
	client.on_event("*", function(event_type, data)
		-- Skip heartbeat noise
		if event_type ~= "server.heartbeat" then
			logger.info("SSE raw: " .. tostring(event_type), { data = data })
		end
		M.emit("sse_" .. event_type, data)
	end)
end

-- Setup chat update handlers for message events
-- This mirrors the TUI's sync.tsx event handling pattern
function M.setup_chat_handlers()
	local state = require("opencode.state")
	local sync = require("opencode.sync")

	-- Handle message.updated - the PRIMARY way messages are added/updated (like TUI sync.tsx:228-265)
	-- This is the ONLY place where messages get added to the store
	M.on("message_updated", function(data)
		vim.schedule(function()
			local logger = require("opencode.logger")
			logger.debug("message_updated received", { data = data })

			local info = data.info
			if not info then
				logger.debug("message_updated: NO INFO")
				return
			end

			-- Update sync store first (like TUI does)
			sync.handle_message_updated(info)

			local current_session = state.get_session()
			if not current_session.id or info.sessionID ~= current_session.id then
				logger.debug("message_updated: different session", {
					current = current_session.id,
					received = info.sessionID,
				})
				return
			end

			-- Note: User messages now come from the server (not added locally)
			-- so we process them like any other message to trigger re-render

			-- Update status based on message state
			if info.role == "assistant" then
				if info.time and info.time.completed then
					state.set_status("idle")
				else
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
			local logger = require("opencode.logger")
			logger.debug("message_removed received", { data = data })

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
			local logger = require("opencode.logger")
			logger.debug("message_part_updated", { data = data })

			local part = data.part
			if not part then
				logger.debug("message_part_updated: NO PART")
				return
			end

			-- Update sync store first (like TUI does)
			sync.handle_part_updated(part)

			local current_session = state.get_session()
			if not current_session.id or part.sessionID ~= current_session.id then
				return
			end

			-- Emit specific events based on part type
			if part.type == "text" then
				-- Text content update
				M.emit("chat_render", { session_id = current_session.id })
			elseif part.type == "reasoning" then
				-- Reasoning/thinking update
				logger.debug("Reasoning part update", {
					part_id = part.id,
					message_id = part.messageID,
					text_length = part.text and #part.text or 0,
				})

				M.emit("reasoning_update", {
					message_id = part.messageID,
					part_id = part.id,
					text = part.text,
				})
				M.emit("chat_render", { session_id = current_session.id })
			elseif part.type == "tool" then
				-- Tool call update
				logger.debug("Tool call update", {
					tool = part.tool,
					status = part.state and part.state.status,
				})

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
		end)
	end)

	-- Handle message.part.removed (like TUI sync.tsx:302-314)
	M.on("message_part_removed", function(data)
		vim.schedule(function()
			local logger = require("opencode.logger")
			logger.debug("message_part_removed received", { data = data })

			if data.messageID and data.partID then
				sync.handle_part_removed(data.messageID, data.partID)

				local current_session = state.get_session()
				M.emit("chat_render", { session_id = current_session.id })
			end
		end)
	end)

	-- Retry countdown timer handle
	local retry_timer = nil

	-- Handle session.status changes (like TUI sync.tsx:223-225)
	M.on("session_status", function(data)
		vim.schedule(function()
			local sync = require("opencode.sync")

			-- Update sync store first
			if data.sessionID and data.status then
				sync.handle_session_status(data.sessionID, data.status)
			end

			local current_session = state.get_session()
			if data.sessionID ~= current_session.id then
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
					retry_timer:start(1000, 1000, vim.schedule_wrap(function()
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
					end))
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

	-- Clear sync store on session change
	M.on("session_change", function(data)
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

			-- Custom tools are handled via the permission system with "diff_review" type
			if tool_name == "opencode_edit" or tool_name == "opencode_apply_patch" then
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

			-- Route diff_review permissions to the edit widget
			if permission_type == "diff_review" then
				local permission_id = data.id or data.requestID or ("perm_" .. os.time())
				local edit_state_mod = require("opencode.edit.state")

				-- Skip if already handled (dedup for duplicate SSE events)
				if edit_state_mod.get_edit(permission_id) then
					logger.debug("diff_review already handled, skipping", { id = permission_id })
					return
				end

				local metadata = data.metadata or {}
				local current_session = require("opencode.state").get_session()
				local nd_files = metadata.files or {}
				local message_id = data.tool and data.tool.messageID or nil

				edit_state_mod.add_edit(permission_id, current_session.id or "", nd_files, {
					data = data,
					metadata = metadata,
					message_id = message_id,
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

			elseif permission_type == "edit" then
				local permission_id = data.id or data.requestID or ("perm_" .. os.time())

				-- Extract file data from metadata
				local metadata = data.metadata or {}

				-- Check for native diff request from custom tools -> edit widget (legacy)
				if metadata.opencode_native_diff == true then
					local edit_state_mod = require("opencode.edit.state")

					-- Skip if already handled (dedup: diff_review path may have created this edit)
					if edit_state_mod.get_edit(permission_id) then
						logger.debug("edit (native_diff) already handled, skipping", { id = permission_id })
						return
					end

					local current_session = require("opencode.state").get_session()
					local nd_files = metadata.files or {}
					local message_id = data.tool and data.tool.messageID or nil

					edit_state_mod.add_edit(permission_id, current_session.id or "", nd_files, {
						data = data,
						metadata = metadata,
						message_id = message_id,
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
				end

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
			else
				-- Non-edit permission: handle interactively via permission state + chat widget
				local permission_id = data.id or data.requestID or ("perm_" .. os.time())
				local metadata = data.metadata or {}
				local current_session = require("opencode.state").get_session()

				-- Resolve tool_input from sync store if tool info is available
				local tool_input = {}
				if data.tool and data.tool.messageID and data.tool.callID then
					local sync = require("opencode.sync")
					local parts = sync.get_parts(data.tool.messageID)
					for _, part in ipairs(parts) do
						if part.callID == data.tool.callID and part.state and part.state.input then
							tool_input = part.state.input
							break
						end
					end
				end

				-- Fallback: extract input fields from metadata and top-level data fields
				if not next(tool_input) then
					tool_input = vim.tbl_deep_extend("force", {},
						metadata.input or {},
						{
							command = data.command or metadata.command,
							description = data.description or metadata.description,
							path = data.path or metadata.path,
							file_path = data.file_path or metadata.file_path or data.file or metadata.file,
							pattern = data.pattern or metadata.pattern,
							query = data.query or metadata.query,
							url = data.url or metadata.url,
							directory = data.directory or metadata.directory,
							subagent_type = data.subagent_type or metadata.subagent_type,
						}
					)
				end

				-- Store permission state
				local perm_state_mod = require("opencode.permission.state")
				local message_id = data.tool and data.tool.messageID or nil
				perm_state_mod.add_permission(permission_id, current_session.id or "", permission_type, {
					metadata = metadata,
					patterns = data.patterns or {},
					always = data.always or {},
					tool_input = tool_input,
					message_id = message_id,
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
			local questions = data.questions

			if not request_id or not questions then
				logger.warn("Invalid question data", { data = data, request_id = request_id, has_questions = questions ~= nil })
				return
			end

			-- Check session match
			local current_session = state.get_session()
			if session_id and session_id ~= current_session.id then
				logger.debug("Question for different session, ignoring", {
					expected = current_session.id,
					received = session_id,
				})
				return
			end

			-- Store question state
			question_state.add_question(request_id, session_id or current_session.id, questions)

			-- Stop the spinner so user can interact with the question
			local spinner_ok, spinner = pcall(require, "opencode.ui.spinner")
			if spinner_ok and spinner.is_active() then
				spinner.stop()
				logger.debug("Stopped spinner for question interaction")
			end

			-- Add to chat as a special message
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.add_question_message then
				chat.add_question_message(request_id, questions, "pending")
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

	-- Clear questions on session change
	M.on("session_change", function()
		question_state.clear_all()
	end)
end

-- Setup sync data handlers (providers, agents, config)
-- This mirrors TUI's initial data loading when connecting
function M.setup_sync_data_handlers()
	local sync = require("opencode.sync")
	local client = require("opencode.client")
	local logger = require("opencode.logger")

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
			logger.debug("Fetching initial sync data (providers, agents, config)")

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
						logger.debug("Providers loaded", { count = #providers })

						-- Handle defaults mapping
						if data.default then
							sync.handle_provider_defaults(data.default)
							logger.debug("Provider defaults loaded")
						end

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
						logger.debug("Agents loaded", { count = #agents })
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
						logger.debug("Config loaded")
					end
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
	-- Clear permissions and edits on session change
	M.on("session_change", function()
		local perm_state_ok, perm_state = pcall(require, "opencode.permission.state")
		if perm_state_ok then
			perm_state.clear_all()
		end
		local edit_state_ok, edit_state_mod = pcall(require, "opencode.edit.state")
		if edit_state_ok then
			edit_state_mod.clear_all()
		end
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
