local M = {}

function M.setup(events)
	local state = require("opencode.state")
	local session_actions = require("opencode.session")
	local sync = require("opencode.sync")
	local client = require("opencode.client")
	local logger = require("opencode.logger")
	local event_util = require("opencode.events.util")
	local ORPHAN_RECONCILE_DELAYS_MS = { 40, 150, 400, 1000 }
	local ORPHAN_RECONCILE_MESSAGE_LIMIT = 100
	local orphan_reconciles = {}

	---@param value any
	---@return string|nil
	local function nonempty_string(value)
		if type(value) ~= "string" or value == "" then
			return nil
		end
		return value
	end

	---@param payload any
	---@return string|nil
	local function payload_session_id(payload)
		if type(payload) ~= "table" then
			return nil
		end
		return nonempty_string(payload.sessionID)
			or nonempty_string(payload.sessionId)
			or nonempty_string(payload.session_id)
	end

	---@param payload any
	---@return string|nil
	local function payload_message_id(payload)
		if type(payload) ~= "table" then
			return nil
		end
		return nonempty_string(payload.messageID)
			or nonempty_string(payload.messageId)
			or nonempty_string(payload.message_id)
	end

	---@param payload any
	---@return string|nil
	local function payload_part_id(payload)
		if type(payload) ~= "table" then
			return nil
		end
		return nonempty_string(payload.partID)
			or nonempty_string(payload.partId)
			or nonempty_string(payload.part_id)
			or nonempty_string(payload.id)
	end

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
		local resolved_session_id = payload_session_id(part)

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

	---@param session_id string
	---@param message_id string
	---@return string
	local function orphan_reconcile_key(session_id, message_id)
		return session_id .. "\0" .. message_id
	end

	---@param entry table
	---@param result string
	local function finish_orphan_reconcile(entry, result)
		if orphan_reconciles[entry.key] ~= entry then
			return
		end
		orphan_reconciles[entry.key] = nil
		if result == "exhausted" then
			logger.debug("Orphan message reconciliation exhausted", {
				message_id = entry.message_id,
				candidate_session_id = entry.session_id,
				attempts = entry.attempt,
				elapsed_ms = vim.uv.now() - entry.created_at,
			})
		end
	end

	---@param entry table
	local function schedule_orphan_reconcile_attempt(entry)
		if orphan_reconciles[entry.key] ~= entry then
			return
		end
		local delay_ms = ORPHAN_RECONCILE_DELAYS_MS[entry.attempt + 1]
		if not delay_ms then
			finish_orphan_reconcile(entry, "exhausted")
			return
		end

		entry.scheduled = true
		logger.debug("Orphan message reconciliation scheduled", {
			message_id = entry.message_id,
			candidate_session_id = entry.session_id,
			reason = entry.reason,
			delay_ms = delay_ms,
		})
		vim.defer_fn(function()
			if orphan_reconciles[entry.key] ~= entry then
				return
			end
			entry.scheduled = false
			if entry.in_flight then
				return
			end

			entry.attempt = entry.attempt + 1
			entry.in_flight = true
			logger.debug("Orphan message reconciliation request started", {
				message_id = entry.message_id,
				candidate_session_id = entry.session_id,
				attempt = entry.attempt,
				max_attempts = #ORPHAN_RECONCILE_DELAYS_MS,
			})

			client.get_messages(entry.session_id, { limit = ORPHAN_RECONCILE_MESSAGE_LIMIT }, function(err, messages)
				vim.schedule(function()
					if orphan_reconciles[entry.key] ~= entry then
						return
					end
					entry.in_flight = false

					if err then
						logger.debug("Orphan message reconciliation HTTP error", {
							message_id = entry.message_id,
							candidate_session_id = entry.session_id,
							attempt = entry.attempt,
							error = err.message or err.error or tostring(err),
						})
						schedule_orphan_reconcile_attempt(entry)
						return
					end

					local returned_messages = type(messages) == "table" and #messages or 0
					local _, _, changed_count = sync.handle_session_messages(entry.session_id, messages)
					local owned = sync.get_message(entry.session_id, entry.message_id) ~= nil
					if owned then
						orphan_reconciles[entry.key] = nil

						local current_session = state.get_session()
						local count = #sync.get_messages(entry.session_id)
						if current_session.id == entry.session_id then
							state.set_message_count(count)
						end

						local render_session_id = resolve_render_session_id(
							current_session,
							entry.session_id,
							entry.message_id
						)
						logger.debug("Orphan message reconciliation resolved", {
							message_id = entry.message_id,
							candidate_session_id = entry.session_id,
							attempt = entry.attempt,
							render_session_id = render_session_id,
							changed_count = changed_count,
						})
						if render_session_id then
							events.emit("sync_changed", {
								kind = "message",
								action = "reconciled",
								session_id = render_session_id,
								message_id = entry.message_id,
							})
						end
						return
					end

					local known_owner = sync.find_message_session_id(entry.message_id)
					if known_owner and known_owner ~= entry.session_id then
						logger.debug("Orphan message resolved in another session", {
							message_id = entry.message_id,
							candidate_session_id = entry.session_id,
							actual_owner = known_owner,
						})
						orphan_reconciles[entry.key] = nil
						return
					end

					logger.debug("Orphan message reconciliation snapshot miss", {
						message_id = entry.message_id,
						candidate_session_id = entry.session_id,
						attempt = entry.attempt,
						returned_messages = returned_messages,
						known_owner = known_owner,
					})
					schedule_orphan_reconcile_attempt(entry)
				end)
			end)
		end, delay_ms)
	end

	---@param session_id string|nil
	---@param message_id string|nil
	---@param reason string
	local function schedule_orphan_reconcile(session_id, message_id, reason)
		session_id = nonempty_string(session_id)
		message_id = nonempty_string(message_id)
		if not session_id or not message_id then
			return
		end
		if sync.find_message_session_id(message_id) then
			return
		end

		local key = orphan_reconcile_key(session_id, message_id)
		local now = vim.uv.now()
		local existing = orphan_reconciles[key]
		if existing then
			logger.debug("Orphan message reconciliation coalesced", {
				message_id = message_id,
				candidate_session_id = session_id,
				previous_reason = existing.reason,
				new_reason = reason,
			})
			existing.reason = reason
			existing.last_seen_at = now
			return
		end

		local entry = {
			key = key,
			session_id = session_id,
			message_id = message_id,
			attempt = 0,
			reason = reason,
			created_at = now,
			last_seen_at = now,
			in_flight = false,
			scheduled = false,
		}
		orphan_reconciles[key] = entry
		schedule_orphan_reconcile_attempt(entry)
	end

	---@param message_id string|nil
	local function cancel_orphan_reconciles_for_message(message_id)
		message_id = nonempty_string(message_id)
		if not message_id then
			return
		end
		for key, entry in pairs(orphan_reconciles) do
			if entry.message_id == message_id then
				orphan_reconciles[key] = nil
			end
		end
	end

	---@param session_id string|nil
	local function cancel_orphan_reconciles_for_session(session_id)
		session_id = nonempty_string(session_id)
		if not session_id then
			return
		end
		for key, entry in pairs(orphan_reconciles) do
			if entry.session_id == session_id then
				orphan_reconciles[key] = nil
			end
		end
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

	---@param data any
	---@return table|nil
	local function extract_message_info(data)
		if type(data) ~= "table" then
			return nil
		end
		if type(data.info) == "table" then
			return data.info
		end
		if type(data.message) == "table" then
			return data.message
		end
		return data
	end

	---@param data any
	---@return table|nil
	local function extract_message_parts(data)
		if type(data) ~= "table" then
			return nil
		end
		if type(data.parts) == "table" then
			return data.parts
		end
		if type(data.message) == "table" and type(data.message.parts) == "table" then
			return data.message.parts
		end
		return nil
	end

	---@param data any
	---@param action string
	---@param opts? table
	local function handle_message_payload(data, action, opts)
		opts = opts or {}
		local reason = opts.reason or "message_updated"
		local label = opts.label or "Message update"
		local info = extract_message_info(data)
		if type(info) ~= "table" or not info.id then
			local skip_reason = type(info) == "table" and "missing_id" or "missing_info"
			logger.debug(label .. " ignored", {
				reason = skip_reason,
			})
			return
		end

		info.id = nonempty_string(info.id)
		if not info.id then
			logger.debug(label .. " ignored", {
				reason = "missing_id",
			})
			return
		end

		info.sessionID = payload_session_id(info) or payload_session_id(data)

		local parts = extract_message_parts(data)
		if not info.sessionID and type(parts) == "table" then
			for _, part in ipairs(parts) do
				local part_session_id = payload_session_id(part)
				local part_message_id = payload_message_id(part)
				if
					type(part) == "table"
					and part_session_id
					and (not part_message_id or part_message_id == info.id)
				then
					info.sessionID = part_session_id
					break
				end
			end
		end
		if not info.sessionID then
			info.sessionID = sync.find_message_session_id(info.id)
		end

		local message_changed = sync.handle_message_updated(info)
		local part_count = 0
		local parts_changed_count = 0
		if type(parts) == "table" then
			for _, part in ipairs(parts) do
				if type(part) == "table" and nonempty_string(part.id) then
					part.messageID = payload_message_id(part) or info.id
					part.sessionID = payload_session_id(part) or info.sessionID
					if sync.handle_part_updated(part) then
						parts_changed_count = parts_changed_count + 1
					end
					part_count = part_count + 1
				end
			end
		end

		local current_session = state.get_session()
		if info.sessionID then
			cancel_orphan_reconciles_for_message(info.id)
		else
			schedule_orphan_reconcile(current_session.id, info.id, reason)
		end
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
				reason = reason,
			})
		end
		session_actions.maybe_idle_from_message(info, { reason = "message_completed" })

		local render_session_id = resolve_render_session_id(current_session, info.sessionID, info.id)
		if not render_session_id then
			logger.debug(label .. " stored outside current session", {
				message_session = info.sessionID,
				current_session = current_session.id,
				messageID = info.id,
				role = info.role,
				parts = part_count,
			})
			return
		end

		logger.debug(label .. " stored for visible session", {
			sessionID = info.sessionID,
			render_session_id = render_session_id,
			messageID = info.id,
			role = info.role,
			agent = info.agent,
			providerID = info.providerID,
			modelID = info.modelID,
			completed = info.time and info.time.completed ~= nil or false,
			parts = part_count,
		})

		events.emit("sync_changed", {
			kind = "message",
			action = action,
			session_id = render_session_id,
			message_id = info.id,
		})
	end

	-- message.created is mapped to the local "message" event.
	events.on("message", function(data)
		vim.schedule(function()
			handle_message_payload(data, "created", {
				reason = "message_created",
				label = "Message created",
			})
		end)
	end)

	-- Handle message.updated - the primary way messages are added/updated (like TUI sync.tsx:228-265)
	events.on("message_updated", function(data)
		vim.schedule(function()
			handle_message_payload(data, "updated", {
				reason = "message_updated",
				label = "Message update",
			})
		end)
	end)

	-- Handle message.removed (like TUI sync.tsx:267-279)
	events.on("message_removed", function(data)
		vim.schedule(function()
			local session_id = payload_session_id(data)
			local message_id = payload_message_id(data)
			cancel_orphan_reconciles_for_message(message_id)
			if session_id and message_id then
				sync.handle_message_removed(session_id, message_id)

				local current_session = state.get_session()
				if current_session.id == session_id then
					events.emit("sync_changed", {
						kind = "message",
						action = "removed",
						session_id = current_session.id,
						message_id = message_id,
					})
				end
			end
		end)
	end)

	-- Handle message.part.updated - updates parts in sync store (like TUI sync.tsx:281-299)
	-- Parts contain the actual content (text, reasoning, tool calls)
	events.on("message_part_updated", function(data)
		vim.schedule(function()
			local part = type(data) == "table" and data.part or nil
			if type(part) ~= "table" then
				logger.debug("Part update ignored", {
					reason = "missing_part",
				})
				return
			end

			local part_id = payload_part_id(part)
			local message_id = payload_message_id(part) or payload_message_id(data)
			if not part_id or not message_id then
				logger.debug("Part update ignored", {
					reason = "malformed",
					partID = part_id,
					messageID = message_id,
				})
				return
			end

			part.id = part_id
			part.messageID = message_id
			part.sessionID = payload_session_id(part) or payload_session_id(data)

			local current_session = state.get_session()
			local resolved_session_id = resolve_part_session_id(part, current_session)

			-- Update sync store first (like TUI does)
			sync.handle_part_updated(part)
			if not resolved_session_id then
				schedule_orphan_reconcile(current_session.id, part.messageID, "message_part_updated")
			end

			local render_session_id = resolve_part_render_session_id(part, current_session, resolved_session_id)
			if not render_session_id then
				logger.debug("Part update stored outside current session", {
					part_session = resolved_session_id,
					current_session = current_session.id,
					partID = part.id,
					messageID = part.messageID,
					type = part.type,
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
		end)
	end)

	-- Handle message.part.delta - incremental token/chunk updates while streaming.
	events.on("message_part_delta", function(data)
		vim.schedule(function()
			if type(data) ~= "table" then
				logger.debug("Part delta ignored", {
					reason = "missing_data",
				})
				return
			end
			local message_id = payload_message_id(data)
			local part_id = payload_part_id(data)
			local field = nonempty_string(data.field)
			if not message_id or not part_id or not field or type(data.delta) ~= "string" then
				logger.debug("Part delta ignored", {
					reason = "malformed",
					messageID = message_id,
					partID = part_id,
					field = data.field,
				})
				return
			end

			local current_session = state.get_session()
			local part_hint = {
				id = part_id,
				messageID = message_id,
				sessionID = payload_session_id(data),
			}
			local resolved_session_id = resolve_part_session_id(part_hint, current_session)
			local part = sync.handle_part_delta({
				messageID = message_id,
				partID = part_id,
				field = field,
				delta = data.delta,
				sessionID = resolved_session_id,
			})
			if not resolved_session_id then
				schedule_orphan_reconcile(current_session.id, message_id, "message_part_delta")
			end
			if not part then
				logger.debug("Part delta ignored", {
					reason = "part_not_found",
					partID = part_id,
					messageID = message_id,
					sessionID = resolved_session_id,
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
				return
			end

			logger.debug("Part delta stored for visible session", {
				sessionID = resolved_session_id,
				render_session_id = render_session_id,
				partID = part.id,
				messageID = part.messageID,
				field = field,
				delta_length = #data.delta,
			})
			emit_part_events(part, current_session, resolved_session_id, {
				render_session_id = render_session_id,
				delta = data.delta,
				field = field,
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

	events.on("session.closed", function(data)
		vim.schedule(function()
			cancel_orphan_reconciles_for_session(payload_session_id(data))
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
			local directory = data.info.directory
			if (title == nil or title == vim.NIL) and (parent_id == nil or parent_id == vim.NIL) and (directory == nil or directory == vim.NIL) then
				return
			end

			session_actions.remember({
				id = session_id,
				title = title,
				name = title,
				time = data.info.time,
				parentID = parent_id,
				directory = directory,
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

			-- session.idle events carry only sessionID, no status field; treat as implicit idle
			if data.sessionID and not data.status then
				data.status = { type = "idle" }
			end

			-- Update sync store first
			if data.sessionID and data.status then
				sync.handle_session_status(data.sessionID, data.status)
				session_actions.set_session_status(data.sessionID, data.status, {
					reason = "session_status",
				})

				-- When the session leaves the busy state, any tool parts still
				-- "running" or assistant messages still uncompleted are stale:
				-- the server dropped the terminal SSE events (abort, disconnect,
				-- crash). Force-close them so the UI stops spinning.
				local status_type = type(data.status) == "table" and data.status.type or data.status
				if status_type == "idle" or status_type == "error" then
					local finalized_parts, finalized_messages = sync.finalize_inflight(data.sessionID, {
						finish = status_type == "error" and "error" or "stop",
						tool_status = status_type == "error" and "error" or "interrupted",
						reason = "session_status_" .. status_type,
					})
					if finalized_parts > 0 or finalized_messages > 0 then
						logger.debug("Finalized stale in-flight parts after session status", {
							sessionID = data.sessionID,
							status = status_type,
							finalized_parts = finalized_parts,
							finalized_messages = finalized_messages,
						})
					end
				end
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
				local finalized_parts, finalized_messages = sync.finalize_inflight(session_id, {
					finish = "stop",
					tool_status = "interrupted",
					reason = "session_abort",
				})
				if finalized_parts > 0 or finalized_messages > 0 then
					logger.debug("Finalized stale in-flight parts after abort", {
						sessionID = session_id,
						finalized_parts = finalized_parts,
						finalized_messages = finalized_messages,
					})
				end
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
