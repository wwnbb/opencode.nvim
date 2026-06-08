local M = {}

function M.setup(events)
	local state = require("opencode.state")
	local session_actions = require("opencode.session")
	local sync = require("opencode.sync")
	local logger = require("opencode.logger")
	local event_util = require("opencode.events.util")
	local perf = require("opencode.perf")

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
				events.emit("todo_update", {
					session_id = session_id,
					todos = todos or {},
				})
			end)
		end)
	end

	---@param status table|string|nil
	---@return boolean
	local function is_busy_status(status)
		local status_type = type(status) == "table" and status.type or status
		return status_type == "busy"
			or status_type == "streaming"
			or status_type == "thinking"
			or status_type == "retry"
	end

	---@param info table
	---@return boolean
	local function completed_assistant_message_can_idle_session(info)
		if type(info) ~= "table" or not info.sessionID or not info.id then
			return false
		end
		if info.role ~= "assistant" then
			return false
		end
		if type(info.time) ~= "table" or info.time.completed == nil then
			return false
		end
		if info.finish == "tool-calls" then
			return false
		end

		local messages = sync.get_messages(info.sessionID)
		local latest = messages and messages[#messages] or nil
		return type(latest) == "table" and latest.id == info.id
	end

	---@param info table
	local function mark_session_idle_after_completed_message(info)
		if not completed_assistant_message_can_idle_session(info) then
			return
		end

		local current_status = state.get_session_status(info.sessionID)
		if not is_busy_status(current_status) then
			return
		end

		local idle_status = { type = "idle" }
		sync.handle_session_status(info.sessionID, idle_status)
		session_actions.set_session_status(info.sessionID, idle_status, {
			reason = "message_completed",
		})
	end

	---@param current_session table
	---@return boolean
	local function can_infer_current_stream_session(current_session)
		if not current_session.id or not state.is_streaming() then
			return false
		end

		local busy_count = 0
		for _, session in ipairs(state.get_active_sessions()) do
			if session.id and is_busy_status(session.status or state.get_session_status(session.id)) then
				busy_count = busy_count + 1
				if busy_count > 1 then
					return false
				end
			end
		end

		return busy_count == 1 and is_busy_status(state.get_session_status(current_session.id))
	end

	---@param part table
	---@param current_session table
	---@return string|nil
	local function resolve_part_session_id(part, current_session)
		local resolved_session_id = part.sessionID

		if not resolved_session_id and part.messageID then
			resolved_session_id = sync.find_message_session_id(part.messageID)
		end

		-- If the backend omits sessionID for streaming chunks, infer the current
		-- session only when there is no competing busy runtime session.
		if not resolved_session_id and can_infer_current_stream_session(current_session) then
			resolved_session_id = current_session.id
		end

		if resolved_session_id then
			part.sessionID = resolved_session_id
		end

		return resolved_session_id
	end

	---@param current_session table
	---@param event_session_id string|nil
	---@param message_id string|nil
	---@return string|nil
	local function resolve_render_session_id(current_session, event_session_id, message_id)
		if type(current_session) ~= "table" or not current_session.id then
			return nil
		end

		if message_id and sync.get_message(current_session.id, message_id) ~= nil then
			return current_session.id
		end
		if not event_session_id or event_session_id == "" then
			return nil
		end

		return event_util.render_target_session_id(current_session.id, event_session_id)
	end

	---@param part table
	---@param current_session table
	---@param resolved_session_id string|nil
	---@return string|nil
	local function resolve_part_render_session_id(part, current_session, resolved_session_id)
		return resolve_render_session_id(current_session, resolved_session_id or part.sessionID, part.messageID)
	end

	---@param part table
	---@param current_session table
	---@param resolved_session_id string|nil
	---@param opts? table
	local function emit_part_events(part, current_session, resolved_session_id, opts)
		opts = opts or {}
		local actual_session_id = resolved_session_id or part.sessionID or current_session.id
		local render_session_id = opts.render_session_id or actual_session_id
		if part.type == "text" then
			events.emit("sync_changed", {
				kind = "part",
				action = "updated",
				session_id = render_session_id,
				message_id = part.messageID,
				part_id = part.id,
				delta = opts.delta,
				field = opts.field,
			})
			return
		end

		if part.type == "reasoning" then
			events.emit("sync_changed", {
				kind = "part",
				action = "updated",
				session_id = render_session_id,
				message_id = part.messageID,
				part_id = part.id,
				delta = opts.delta,
				field = opts.field,
			})
			return
		end

		if part.type == "tool" then
			local tool_state = part.state
			if tool_state then
				events.emit("tool_update", {
					session_id = actual_session_id,
					message_id = part.messageID,
					tool_name = part.tool,
					call_id = part.callID,
					status = tool_state.status,
					input = tool_state.input,
					output = tool_state.status == "completed" and tool_state.output or nil,
					error = tool_state.status == "error" and tool_state.error or nil,
				})
			end
			events.emit("sync_changed", {
				kind = "part",
				action = "updated",
				session_id = render_session_id,
				message_id = part.messageID,
				part_id = part.id,
			})
		end
	end

	-- Handle message.updated - the PRIMARY way messages are added/updated (like TUI sync.tsx:228-265)
	-- This is the ONLY place where messages get added to the store
	events.on("message_updated", function(data)
		vim.schedule(function()
			local done = perf.start("events.message_updated")
			local info = data.info
			if not info then
				logger.debug("Message update ignored", {
					reason = "missing_info",
				})
				done({ skipped = true, reason = "missing_info" })
				return
			end

			-- Update sync store first (like TUI does)
			sync.handle_message_updated(info)
			local current_session = state.get_session()
			if info.sessionID and (current_session.id == info.sessionID or state.is_runtime_session(info.sessionID)) then
				local count = #sync.get_messages(info.sessionID)
				if current_session.id == info.sessionID then
					state.set_message_count(count)
				end
				session_actions.remember({
					id = info.sessionID,
					message_count = count,
					messageCount = count,
				}, {
					touch = current_session.id == info.sessionID and state.is_runtime_session(info.sessionID),
					reason = "message_updated",
				})
			end

			mark_session_idle_after_completed_message(info)

			local render_session_id = resolve_render_session_id(current_session, info.sessionID, info.id)
			if not render_session_id then
				logger.debug("Message update stored outside current session", {
					message_session = info.sessionID,
					current_session = current_session.id,
					messageID = info.id,
					role = info.role,
				})
				done({
					message_id = info.id,
					session_id = info.sessionID,
					role = info.role,
					current = false,
				})
				return
			end

			logger.debug("Message update stored for visible session", {
				sessionID = info.sessionID,
				render_session_id = render_session_id,
				messageID = info.id,
				role = info.role,
				agent = info.agent,
				providerID = info.providerID,
				modelID = info.modelID,
				completed = info.time and info.time.completed ~= nil or false,
			})

			-- Note: User messages now come from the server (not added locally)
			-- so we process them like any other message to trigger re-render

			events.emit("sync_changed", {
				kind = "message",
				action = "updated",
				session_id = render_session_id,
				message_id = info.id,
			})
			done({
				message_id = info.id,
				session_id = info.sessionID,
				render_session_id = render_session_id,
				role = info.role,
				current = render_session_id == current_session.id,
			})
		end)
	end)

	-- Handle message.removed (like TUI sync.tsx:267-279)
	events.on("message_removed", function(data)
		vim.schedule(function()
			if data.sessionID and data.messageID then
				sync.handle_message_removed(data.sessionID, data.messageID)

				local current_session = state.get_session()
				if current_session.id == data.sessionID then
					events.emit("sync_changed", {
						kind = "message",
						action = "removed",
						session_id = current_session.id,
						message_id = data.messageID,
					})
				end
			end
		end)
	end)

	-- Handle message.part.updated - updates parts in sync store (like TUI sync.tsx:281-299)
	-- Parts contain the actual content (text, reasoning, tool calls)
	events.on("message_part_updated", function(data)
		vim.schedule(function()
			local done = perf.start("events.message_part_updated")
			local part = data.part
			if not part then
				logger.debug("Part update ignored", {
					reason = "missing_part",
				})
				done({ skipped = true, reason = "missing_part" })
				return
			end

			local current_session = state.get_session()
			local resolved_session_id = resolve_part_session_id(part, current_session)

			-- Update sync store first (like TUI does)
			sync.handle_part_updated(part)

			local render_session_id = resolve_part_render_session_id(part, current_session, resolved_session_id)
			if not render_session_id then
				logger.debug("Part update stored outside current session", {
					part_session = resolved_session_id,
					current_session = current_session.id,
					partID = part.id,
					messageID = part.messageID,
					type = part.type,
				})
				done({
					part_id = part.id,
					message_id = part.messageID,
					type = part.type,
					session_id = resolved_session_id,
					current = false,
				})
				return
			end

			logger.debug("Part update stored for visible session", {
				sessionID = resolved_session_id,
				render_session_id = render_session_id,
				partID = part.id,
				messageID = part.messageID,
				type = part.type,
			})
			emit_part_events(part, current_session, resolved_session_id, {
				render_session_id = render_session_id,
			})
			done({
				part_id = part.id,
				message_id = part.messageID,
				type = part.type,
				tool = part.tool,
				session_id = resolved_session_id,
				render_session_id = render_session_id,
				current = render_session_id == current_session.id,
			})
		end)
	end)

	-- Handle message.part.delta - incremental token/chunk updates while streaming.
	events.on("message_part_delta", function(data)
		vim.schedule(function()
			local done = perf.start("events.message_part_delta")
			if not data then
				logger.debug("Part delta ignored", {
					reason = "missing_data",
				})
				done({ skipped = true, reason = "missing_data" })
				return
			end
			if not data.messageID or not data.partID or not data.field or type(data.delta) ~= "string" then
				logger.debug("Part delta ignored", {
					reason = "malformed",
					messageID = data.messageID,
					partID = data.partID,
					field = data.field,
				})
				done({
					skipped = true,
					reason = "malformed",
					message_id = data.messageID,
					part_id = data.partID,
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
				done({
					skipped = true,
					reason = "part_not_found",
					message_id = data.messageID,
					part_id = data.partID,
					field = data.field,
					delta_bytes = #data.delta,
				})
				return
			end

			local render_session_id = resolve_part_render_session_id(part, current_session, resolved_session_id)
			if not render_session_id then
				logger.debug("Part delta stored outside current session", {
					part_session = resolved_session_id,
					current_session = current_session.id,
					partID = part.id,
					messageID = part.messageID,
					type = part.type,
				})
				done({
					part_id = part.id,
					message_id = part.messageID,
					type = part.type,
					session_id = resolved_session_id,
					field = data.field,
					delta_bytes = #data.delta,
					current = false,
				})
				return
			end

			logger.debug("Part delta stored for visible session", {
				sessionID = resolved_session_id,
				render_session_id = render_session_id,
				partID = part.id,
				messageID = part.messageID,
				field = data.field,
				delta_length = #data.delta,
			})
			emit_part_events(part, current_session, resolved_session_id, {
				render_session_id = render_session_id,
				delta = data.delta,
				field = data.field,
			})
			done({
				part_id = part.id,
				message_id = part.messageID,
				type = part.type,
				session_id = resolved_session_id,
				render_session_id = render_session_id,
				field = data.field,
				delta_bytes = #data.delta,
				current = render_session_id == current_session.id,
			})
		end)
	end)

	-- Handle message.part.removed (like TUI sync.tsx:302-314)
	events.on("message_part_removed", function(data)
		vim.schedule(function()
			if data.messageID and data.partID then
				sync.handle_part_removed(data.messageID, data.partID)

				local current_session = state.get_session()
				events.emit("sync_changed", {
					kind = "part",
					action = "removed",
					session_id = current_session.id,
					message_id = data.messageID,
					part_id = data.partID,
				})
			end
		end)
	end)

	-- Handle todo.updated (OpenCode session todo state)
	events.on("todo_updated", function(data)
		vim.schedule(function()
			if type(data) ~= "table" or not data.sessionID then
				logger.debug("Todo update ignored", {
					reason = "malformed",
				})
				return
			end

			local todos = type(data.todos) == "table" and data.todos or {}
			sync.handle_todo_updated(data.sessionID, todos)

			local current_session = state.get_session()
			local relevant = event_util.permission_session_is_relevant(current_session and current_session.id, data.sessionID)
			if not relevant then
				logger.debug("Todo update stored outside current session", {
					sessionID = data.sessionID,
					current_session = current_session and current_session.id or nil,
					count = #todos,
				})
				return
			end

			events.emit("todo_update", {
				session_id = data.sessionID,
				todos = todos,
			})

			logger.debug("Todo update stored for current session", {
				sessionID = data.sessionID,
				count = #todos,
			})
		end)
	end)

	-- Retry countdown timer handle
	local retry_timer = nil

	-- Handle session.updated title changes.
	-- OpenCode starts new sessions with a generated default title, then may
	-- rename the session from the first real user prompt.
	events.on("session_updated", function(data)
		vim.schedule(function()
			if not data or type(data.info) ~= "table" then
				return
			end

			local current_session = state.get_session()
			local session_id = data.sessionID or data.info.id
			if not session_id then
				return
			end

			local title = data.info.title
			local parent_id = data.info.parentID or data.info.parentId or data.info.parent_id
			if (title == nil or title == vim.NIL) and (parent_id == nil or parent_id == vim.NIL) then
				return
			end

			session_actions.remember({
				id = session_id,
				title = title,
				name = title,
				time = data.info.time,
				parentID = parent_id,
			}, {
				touch = session_id == current_session.id and state.is_runtime_session(session_id),
				reason = "session_updated",
			})
			if session_id == current_session.id and title ~= nil and title ~= vim.NIL then
				session_actions.set_active(session_id, title, {
					reason = "session_updated",
					preserve_cache = true,
					runtime = state.is_runtime_session(session_id),
				})
			end

			local render_session_id = event_util.render_target_session_id(current_session.id, session_id)
			if render_session_id then
				events.emit("sync_changed", {
					kind = "session",
					action = "updated",
					session_id = render_session_id,
				})
			end
		end)
	end)

	-- Handle session.status changes (like TUI sync.tsx:223-225)
	events.on("session_status", function(data)
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
				session_actions.set_session_status(data.sessionID, data.status, {
					reason = "session_status",
				})
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
							events.emit("sync_changed", {
								kind = "session_status",
								action = "retry_tick",
								session_id = cs.id,
							})
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

			events.emit("sync_changed", {
				kind = "session_status",
				action = "updated",
				session_id = current_session.id,
			})
		end)
	end)

	events.on("session_error", function(data)
		vim.schedule(function()
			local current_session = state.get_session()
			local session_id = (data and data.sessionID) or current_session.id
			local err = data and data.error

			if event_util.is_abort_error(err) then
				logger.debug("Session abort ignored", {
					sessionID = data and data.sessionID or nil,
				})
				if session_id then
					session_actions.set_session_status(session_id, { type = "idle" }, {
						reason = "session_abort",
					})
					events.emit("sync_changed", {
						kind = "session_error",
						action = "aborted",
						session_id = session_id,
					})
				end
				return
			end

			local message = event_util.format_session_error(err, { fallback = "unknown error" })
			if session_id then
				local error_status = {
					type = "error",
					message = message,
				}
				sync.handle_session_status(session_id, error_status)
				session_actions.set_session_status(session_id, error_status, {
					reason = "session_error",
				})
			end

			local notice_session_id = nil
			if session_id == current_session.id then
				notice_session_id = session_id
			else
				notice_session_id = event_util.runtime_root_for_session(session_id)
			end
			logger.debug("Session error handled", {
				sessionID = data and data.sessionID or nil,
				message = message,
			})

			if notice_session_id then
				events.emit("sync_changed", {
					kind = "session_error",
					action = "error",
					session_id = notice_session_id,
				})
			end
		end)
	end)

	events.on("session_change", function(data)
		fetch_session_todos(data and data.id, "session_change")
	end)

	events.on("connected", function()
		local current_session = state.get_session()
		fetch_session_todos(current_session and current_session.id, "connected")
	end)

	-- Clear sync store only for explicit reset/disconnect flows.
	events.on("session_change", function(data)
		local sync = require("opencode.sync")
		local reason = data and data.reason
		if data and data.previous_id and not data.preserve_cache and (reason == "clear" or reason == "disconnect") then
			sync.clear_session(data.previous_id)
		end
	end)
end

return M
