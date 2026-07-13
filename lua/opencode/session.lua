-- Action boundary for active-session and global-status mutations.
-- Compatibility events are emitted here instead of from the store itself.

local M = {}

local state = require("opencode.state")
local session_util = require("opencode.util.session")
local event_util = require("opencode.events.util")
local navigation = require("opencode.session.navigation")
local pending_helper = require("opencode.session.pending")
local status_helper = require("opencode.session.status")
local navigation_ctx = { state = state, event_util = event_util }

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

---@param data? table
local function request_chat_render(data)
	local ok, render_coordinator = pcall(require, "opencode.ui.chat.render_coordinator")
	if ok and type(render_coordinator.request) == "function" then
		render_coordinator.request(vim.tbl_extend("force", data or {}, {
			force = true,
		}))
	end
end

---@param kind string
---@param id string
---@param err any
local function log_close_reject_error(kind, id, err)
	if not err then
		return
	end
	local ok_logger, logger = pcall(require, "opencode.logger")
	if ok_logger and logger and type(logger.debug) == "function" then
		logger.debug("Failed to reject " .. kind .. " while closing session", {
			id = id,
			error = err.message or err.error or tostring(err),
		})
	end
end

---@param permission_id string
local function reject_permission_request(permission_id)
	local ok_client, client = pcall(require, "opencode.client")
	if not ok_client or type(client.respond_permission) ~= "function" then
		return
	end
	-- Resolve the session directory so the reject reaches the instance
	-- that owns the permission (may differ from cwd for cross-project
	-- sessions).
	local reply_opts = { message = "Session closed" }
	local session_id
	local perm_ok, perm_state = pcall(require, "opencode.permission.state")
	if perm_ok and perm_state.get_permission then
		local pstate = perm_state.get_permission(permission_id)
		if pstate then
			session_id = pstate.session_id
		end
	end
	if not session_id then
		local edit_ok, edit_state = pcall(require, "opencode.edit.state")
		if edit_ok and edit_state.get_edit then
			local estate = edit_state.get_edit(permission_id)
			if estate then
				session_id = estate.session_id
			end
		end
	end
	if session_id then
		local state_ok, state = pcall(require, "opencode.state")
		if state_ok and type(state.get_session_directory) == "function" then
			reply_opts.directory = state.get_session_directory(session_id)
		end
	end
	pcall(function()
		client.respond_permission(permission_id, "reject", reply_opts, function(err)
			log_close_reject_error("permission", permission_id, err)
		end)
	end)
end

---@param session_id string|nil
---@param request_id string
local function reject_question_request(session_id, request_id)
	local ok_client, client = pcall(require, "opencode.client")
	if not ok_client or type(client.reject_question) ~= "function" then
		return
	end
	pcall(function()
		client.reject_question(session_id or "", request_id, function(err)
			log_close_reject_error("question", request_id, err)
		end)
	end)
end

---@param permission_id string
---@param session_id string|nil
---@param source string
local function emit_permission_rejected_for_close(permission_id, session_id, source)
	emit("permission_rejected", {
		permission_id = permission_id,
		session_id = session_id,
		reason = "session_close",
		source = source,
	})
	emit("interaction_changed", {
		kind = "permission",
		action = "rejected",
		id = permission_id,
		session_id = session_id,
		reason = "session_close",
		source = source,
	})
end

---@param root_session_id string
local function close_pending_interactions_for_session(root_session_id)
	if not root_session_id or root_session_id == "" then
		return
	end

	local ok_auto, auto_approve = pcall(require, "opencode.permission.danger")
	if ok_auto and type(auto_approve.clear) == "function" then
		auto_approve.clear()
	end

	local ok_perm, perm_state = pcall(require, "opencode.permission.state")
	if ok_perm and type(perm_state.get_all) == "function" and type(perm_state.remove_permission) == "function" then
		local owned = pending_helper.collect_owned(perm_state.get_all(), root_session_id, function(root, session_id)
			return navigation.session_owned_by_root(root, session_id, navigation_ctx)
		end)
		for _, pstate in ipairs(owned) do
			if pending_helper.is_pending_permission(pstate) then
				reject_permission_request(pstate.permission_id)
				if type(perm_state.mark_rejected) == "function" then
					perm_state.mark_rejected(pstate.permission_id)
				end
				emit_permission_rejected_for_close(pstate.permission_id, pstate.session_id, "permission")
			end
			if perm_state.remove_permission(pstate.permission_id) then
				emit("permission_removed", {
					permission_id = pstate.permission_id,
					session_id = pstate.session_id,
					reason = "session_close",
				})
				emit("interaction_changed", {
					kind = "permission",
					action = "removed",
					id = pstate.permission_id,
					session_id = pstate.session_id,
				})
			end
		end
	end

	local ok_question, question_state = pcall(require, "opencode.question.state")
	if
		ok_question
		and type(question_state.get_all) == "function"
		and type(question_state.remove_question) == "function"
	then
		local owned = pending_helper.collect_owned(question_state.get_all(), root_session_id, function(root, session_id)
			return navigation.session_owned_by_root(root, session_id, navigation_ctx)
		end)
		for _, qstate in ipairs(owned) do
			if pending_helper.is_pending_question(qstate) then
				reject_question_request(qstate.session_id, qstate.request_id)
			end
			if question_state.remove_question(qstate.request_id) then
				emit("question_removed", {
					request_id = qstate.request_id,
					session_id = qstate.session_id,
					reason = "session_close",
				})
				emit("interaction_changed", {
					kind = "question",
					action = "removed",
					id = qstate.request_id,
					session_id = qstate.session_id,
				})
			end
		end
	end

	local ok_edit, edit_state = pcall(require, "opencode.edit.state")
	if ok_edit and type(edit_state.get_all) == "function" and type(edit_state.remove_edit) == "function" then
		local owned = pending_helper.collect_owned(edit_state.get_all(), root_session_id, function(root, session_id)
			return navigation.session_owned_by_root(root, session_id, navigation_ctx)
		end)
		for _, estate in ipairs(owned) do
			if pending_helper.is_pending_edit(estate) then
				if type(edit_state.reject_all) == "function" then
					local call_ok, rejected, reject_err = pcall(edit_state.reject_all, estate.permission_id)
					if not call_ok or not rejected then
						vim.notify(
							"Failed to reject edit before closing session: "
								.. tostring((call_ok and reject_err) or rejected or "unknown error"),
							vim.log.levels.ERROR
						)
					end
				end
				reject_permission_request(estate.permission_id)
				emit_permission_rejected_for_close(estate.permission_id, estate.session_id, "edit")
			end
			if edit_state.remove_edit(estate.permission_id) then
				emit("edit_removed", {
					permission_id = estate.permission_id,
					session_id = estate.session_id,
					reason = "session_close",
				})
				emit("interaction_changed", {
					kind = "edit",
					action = "removed",
					id = estate.permission_id,
					session_id = estate.session_id,
				})
			end
		end
	end
end

---@param session table
---@param opts? table { notify?: boolean, reason?: string }
local function activate_local(session, opts)
	opts = opts or {}
	if type(session) ~= "table" or not session.id then
		return
	end

	local current = state.get_session()
	M.remember(session, { touch = false, reason = opts.reason or "session_switch" })
	M.set_active(session.id, session.title or session.name, {
		reason = opts.reason or "session_switch",
		preserve_cache = true,
	})
	emit("session.selected", {
		sessionID = session.id,
		sessionTitle = session.title or session.name,
		previousSessionID = current.id,
	})
	emit("sync_changed", {
		kind = "session",
		action = opts.reason or "session_switch",
		session_id = session.id,
	})
	if opts.notify then
		local title = session_util.displayTitle(session.title or session.name) or session.id
		vim.notify("Switched to session: " .. title, vim.log.levels.INFO)
	end
end

---@param status string
---@param opts table
---@return string previous
local function set_global_status(status, opts)
	opts = opts or {}
	local previous = state.set_status(status)

	emit("status_change", {
		status = status,
		previous = previous,
		reason = opts.reason,
		session_id = opts.session_id,
	})

	return previous
end

---@param session_id string|nil
---@param raw_status table|string|nil
---@param opts? table
local function mirror_active_status(session_id, raw_status, opts)
	local current = state.get_session()
	if not session_id or current.id ~= session_id then
		return
	end
	local global_status = status_helper.session_status_to_global(raw_status)
	set_global_status(global_status, {
		reason = opts and opts.reason or "session_status",
		session_id = session_id,
	})
end

---@param id string|nil
---@param name string|nil
---@param opts? table { reason?: string, preserve_cache?: boolean, runtime?: boolean }
---@return table previous
function M.set_active(id, name, opts)
	opts = opts or {}
	local previous = state.set_session(id, name, {
		runtime = opts.runtime ~= false,
	})
	local current = state.get_session()
	local session_status = id and state.get_session_status(id) or { type = "idle" }

	emit("session_change", {
		id = current.id,
		name = current.name,
		previous_id = previous.id,
		previous_name = previous.name,
		reason = opts.reason,
		preserve_cache = opts.preserve_cache == true,
	})
	emit("sessions_changed", { reason = opts.reason or "session_change", session_id = current.id })

	if id then
		mirror_active_status(id, session_status, {
			reason = opts.reason or "session_change",
		})
	else
		set_global_status("idle", {
			reason = opts.reason or "session_change",
			session_id = nil,
		})
	end

	return previous
end

---@param status string
---@param opts? table { reason?: string, session_id?: string }
---@return string previous
function M.set_status(status, opts)
	opts = opts or {}
	local previous_status = nil
	local session_status = nil
	if opts.session_id then
		session_status = status_helper.global_status_to_session(status)
		previous_status = state.set_session_status(opts.session_id, session_status)
	end

	local current = state.get_session()
	local previous = state.get_status()
	if not opts.session_id or current.id == opts.session_id then
		previous = set_global_status(status, opts)
	end

	if opts.session_id then
		emit("session_status_change", {
			session_id = opts.session_id,
			status = session_status,
			previous = previous_status,
			reason = opts.reason,
		})
		emit("sessions_changed", { reason = opts.reason, session_id = opts.session_id })
	end

	return previous
end

---@param status table|string|nil
---@return boolean
local function is_busy_status_for_idle(status)
	local status_type = type(status) == "table" and status.type or status
	return status_type == "busy"
		or status_type == "streaming"
		or status_type == "thinking"
		or status_type == "retry"
end

local busy_watchdog_scheduled = false

local function schedule_busy_watchdog()
	if busy_watchdog_scheduled then
		return
	end
	busy_watchdog_scheduled = true
	vim.defer_fn(function()
		busy_watchdog_scheduled = false
		local any_busy = false
		for _, session_id in ipairs(state.get_session_status_ids()) do
			if state.is_runtime_session(session_id) then
				local current = state.get_session_status(session_id)
				if is_busy_status_for_idle(current) then
					M.reconcile_busy_session_idle(session_id, { reason = "watchdog" })
					local after = state.get_session_status(session_id)
					if is_busy_status_for_idle(after) then
						any_busy = true
					end
				end
			end
		end
		if any_busy then
			schedule_busy_watchdog()
		end
	end, 15000)
end

---@param session_id string
---@param status table|string
---@param opts? table { reason?: string }
---@return table|nil previous
function M.set_session_status(session_id, status, opts)
	opts = opts or {}
	if not session_id or session_id == "" then
		return nil
	end

	local normalized = status_helper.normalize_session_status(status)
	local previous = state.set_session_status(session_id, normalized)
	mirror_active_status(session_id, normalized, {
		reason = opts.reason or "session_status",
	})

	emit("session_status_change", {
		session_id = session_id,
		status = normalized,
		previous = previous,
		reason = opts.reason,
	})
	emit("sessions_changed", { reason = opts.reason, session_id = session_id })

	if is_busy_status_for_idle(normalized) then
		schedule_busy_watchdog()
	end
	return previous
end

---@param info table  message info with sessionID, id, role, time, finish
---@param opts? table  { reason?: string }
---@return boolean  true if session was idled
function M.maybe_idle_from_message(info, opts)
	opts = opts or {}
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

	local ok_sync, sync = pcall(require, "opencode.sync")
	if not ok_sync or type(sync.get_messages) ~= "function" then
		return false
	end
	local messages = sync.get_messages(info.sessionID)
	local latest = messages and messages[#messages] or nil
	if type(latest) ~= "table" or latest.id ~= info.id then
		return false
	end

	local current_status = state.get_session_status(info.sessionID)
	if not is_busy_status_for_idle(current_status) then
		return false
	end

	local idle_status = { type = "idle" }
	if type(sync.handle_session_status) == "function" then
		sync.handle_session_status(info.sessionID, idle_status)
	end
	M.set_session_status(info.sessionID, idle_status, {
		reason = opts.reason or "message_completed",
	})
	return true
end

---@param session_id string
---@param opts? table  { reason?: string }
function M.reconcile_busy_session_idle(session_id, opts)
	opts = opts or {}
	if not session_id or session_id == "" then
		return
	end

	local current_status = state.get_session_status(session_id)
	if not is_busy_status_for_idle(current_status) then
		return
	end

	local ok_sync, sync = pcall(require, "opencode.sync")
	if not ok_sync or type(sync.get_messages) ~= "function" then
		return
	end
	local messages = sync.get_messages(session_id)
	local latest = messages and messages[#messages] or nil
	if type(latest) == "table" then
		M.maybe_idle_from_message(latest, opts)
	end
end

---@param session table
---@param opts? table
---@return table|nil
function M.remember(session, opts)
	local record = state.upsert_session(session, opts)
	if record then
		emit("sessions_changed", { reason = opts and opts.reason or "remember", session_id = record.id })
	end
	return record
end

---@param session_id string|nil
---@param opts? table { reason?: string }
function M.forget(session_id, opts)
	opts = opts or {}
	if not session_id or session_id == "" then
		return
	end
	state.remove_session(session_id)
	emit("sessions_changed", { reason = opts.reason or "forget", session_id = session_id })
end

---@param session_id? string
---@param opts? table { notify?: boolean, reason?: string, silent?: boolean }
---@return boolean closed
function M.close(session_id, opts)
	opts = opts or {}
	local current = state.get_session()
	local target_id = navigation.runtime_session_id(session_id or current.id, navigation_ctx)
	if not target_id then
		if not opts.silent then
			vim.notify("No active OpenCode session tab to close", vim.log.levels.WARN)
		end
		return false
	end

	if not state.is_runtime_session(target_id) then
		if not opts.silent then
			vim.notify("OpenCode session is not an active tab", vim.log.levels.INFO)
		end
		return false
	end

	local current_root = navigation.runtime_session_id(current.id, navigation_ctx)
	local next_session = navigation.next_session_after_close(target_id, nil, navigation_ctx)
	close_pending_interactions_for_session(target_id)
	local closed = state.close_runtime_session(target_id)
	local title = session_util.displayTitle(closed and (closed.title or closed.name)) or target_id

	local ok_sync, sync = pcall(require, "opencode.sync")
	if ok_sync and type(sync.clear_session) == "function" then
		sync.clear_session(target_id)
	end

	if current_root == target_id then
		if next_session then
			local record = state.get_session_record(next_session.id) or next_session
			activate_local(record, {
				reason = opts.reason or "session_close",
			})
		else
			M.set_active(nil, nil, {
				reason = opts.reason or "session_close",
				preserve_cache = true,
			})
		end

		local ok_chat, chat = pcall(require, "opencode.ui.chat")
		if ok_chat and type(chat.clear_session_view) == "function" then
			chat.clear_session_view(target_id)
		end
	end

	emit("session.closed", {
		sessionID = target_id,
		session_id = target_id,
		nextSessionID = next_session and next_session.id or nil,
		next_session_id = next_session and next_session.id or nil,
		reason = opts.reason or "session_close",
	})
	emit("session_pending_change", {
		session_id = target_id,
		pending = pending_helper.zero_counts(),
	})
	emit("sessions_changed", { reason = opts.reason or "session_close", session_id = target_id })
	emit("sync_changed", {
		kind = "session",
		action = opts.reason or "session_close",
		session_id = target_id,
	})

	if opts.notify and not opts.silent then
		vim.notify("Closed session tab: " .. title, vim.log.levels.INFO)
	end
	return true
end

---@param sessions table[]|nil
---@param opts? table { limit?: number, reason?: string }
function M.set_recent(sessions, opts)
	opts = opts or {}
	state.set_recent_sessions(sessions or {}, opts.limit)
	emit("sessions_changed", { reason = opts.reason or "recent" })
end

---@param session_id string
---@param messages table[]|nil
---@param opts? table { loaded?: boolean, reason?: string }
function M.set_message_cache(session_id, messages, opts)
	opts = opts or {}
	local count = type(messages) == "table" and #messages or 0
	local current = state.get_session()
	if current.id == session_id then
		state.set_message_count(count)
	else
		state.set_session_message_cache(session_id, {
			count = count,
			loaded = opts.loaded ~= false,
			updated_at = os.time() * 1000,
		})
	end
	emit("sessions_changed", { reason = opts.reason or "message_cache", session_id = session_id })
end

---@return table<string, table>
local function collect_pending_counts()
	local counts = {}

	---@param session_id string|nil
	---@return string|nil
	local function ensure(session_id)
		local root_session_id = navigation.runtime_session_id(session_id, navigation_ctx)
		if not root_session_id then
			return nil
		end
		counts[root_session_id] = counts[root_session_id] or pending_helper.zero_counts()
		return counts[root_session_id]
	end

	local ok_permissions, permissions = pcall(require, "opencode.permission.state")
	if ok_permissions and type(permissions.get_all_active) == "function" then
		for _, item in ipairs(permissions.get_all_active()) do
			local entry = ensure(item.session_id)
			if entry then
				entry.permissions = entry.permissions + 1
			end
		end
	end

	local ok_questions, questions = pcall(require, "opencode.question.state")
	if ok_questions and type(questions.get_all) == "function" then
		for _, item in ipairs(questions.get_all()) do
			if pending_helper.is_pending_question(item) then
				local entry = ensure(item.session_id)
				if entry then
					entry.questions = entry.questions + 1
				end
			end
		end
	end

	local ok_edits, edits = pcall(require, "opencode.edit.state")
	if ok_edits and type(edits.get_all_active) == "function" then
		for _, item in ipairs(edits.get_all_active()) do
			local entry = ensure(item.session_id)
			if entry then
				entry.edits = entry.edits + 1
			end
		end
	end

	return counts
end

---@return table<string, table>
function M.recount_pending()
	local counts = collect_pending_counts()
	local seen = {}

	for _, session in ipairs(state.get_active_sessions()) do
		seen[session.id] = true
	end
	for session_id, _ in pairs(counts) do
		seen[session_id] = true
	end

	for session_id, _ in pairs(seen) do
		local next_counts = counts[session_id] or pending_helper.zero_counts()
		state.set_session_pending_counts(session_id, next_counts)
		emit("session_pending_change", {
			session_id = session_id,
			pending = next_counts,
		})
	end

	emit("sessions_changed", { reason = "pending_counts" })
	return counts
end

---@param callback? function
---@param opts? table { limit?: number, silent?: boolean }
function M.refresh_recent(callback, opts)
	opts = opts or {}
	local ok_client, client = pcall(require, "opencode.client")
	if not ok_client or type(client.list_sessions) ~= "function" then
		if callback then
			callback({ message = "OpenCode client unavailable" })
		end
		return
	end

	local cfg = state.get_config() or {}
	local parallel = cfg.session and cfg.session.parallel or {}
	local limit = opts.limit or parallel.recent_limit or 30
	local directory = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
	if vim.fs and vim.fs.normalize then
		directory = vim.fs.normalize(directory)
	end

	client.list_sessions({ roots = true, directory = directory, limit = limit }, function(err, sessions)
		if not err and sessions then
			M.set_recent(sessions, {
				limit = limit,
				reason = "refresh_recent",
			})
		end
		if callback then
			callback(err, sessions)
		end
	end)
end

---@param callback? function
function M.refresh_status(callback)
	local ok_client, client = pcall(require, "opencode.client")
	if not ok_client or type(client.get_session_statuses) ~= "function" then
		if callback then
			callback({ message = "OpenCode client unavailable" })
		end
		return
	end

	local directory = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")
	if vim.fs and vim.fs.normalize then
		directory = vim.fs.normalize(directory)
	end

	client.get_session_statuses({ directory = directory }, function(err, statuses)
		if not err and type(statuses) == "table" then
			local seen = {}
			for session_id, status in pairs(statuses) do
				if state.is_runtime_session(session_id) then
					seen[session_id] = true
					M.set_session_status(session_id, status, { reason = "refresh_status" })
				end
			end
			for _, session_id in ipairs(state.get_session_status_ids()) do
				local current_status = state.get_session_status(session_id)
				if
					state.is_runtime_session(session_id)
					and not seen[session_id]
					and (current_status.type == "busy" or current_status.type == "retry")
				then
					M.set_session_status(session_id, { type = "idle" }, { reason = "refresh_status" })
				end
			end
		end
		if callback then
			callback(err, statuses)
		end
	end)
end

---@param session table
---@param opts? table { notify?: boolean, reason?: string }
function M.switch_to(session, opts)
	opts = opts or {}
	if type(session) ~= "table" or not session.id then
		vim.notify("OpenCode: invalid session", vim.log.levels.ERROR)
		return
	end

	local current = state.get_session()
	if current.id == session.id then
		if opts.notify then
			local title = session_util.displayTitle(session.title or session.name) or session.id
			vim.notify("Already on session: " .. title, vim.log.levels.INFO)
		end
		return
	end

	M.remember(session, { touch = false, reason = opts.reason or "session_switch" })

	local function activate()
		M.set_active(session.id, session.title or session.name, {
			reason = opts.reason or "session_switch",
			preserve_cache = true,
		})
		emit("session.selected", {
			sessionID = session.id,
			sessionTitle = session.title or session.name,
			previousSessionID = current.id,
		})
		emit("sync_changed", {
			kind = "session",
			action = opts.reason or "session_switch",
			session_id = session.id,
		})
		if opts.notify then
			local title = session_util.displayTitle(session.title or session.name) or session.id
			vim.notify("Switched to session: " .. title, vim.log.levels.INFO)
		end
	end

	local ok_sync, sync = pcall(require, "opencode.sync")
	local ok_client, client = pcall(require, "opencode.client")
	activate()
	request_chat_render({
		session_id = session.id,
		reason = opts.reason or "session_switch",
	})
	if not ok_client or type(client.get_messages) ~= "function" then
		return
	end

	client.get_messages(session.id, { limit = 100 }, function(err, messages)
		vim.schedule(function()
			if err and opts.notify then
				vim.notify(
					"Failed to load session messages: " .. tostring(err.message or err.error or err),
					vim.log.levels.WARN
				)
			end
			if ok_sync and messages and type(sync.handle_session_messages) == "function" then
				sync.handle_session_messages(session.id, messages)
				M.set_message_cache(session.id, messages, {
					reason = "session_switch",
				})
				M.reconcile_busy_session_idle(session.id, { reason = "session_switch" })
			end
			if state.get_session().id == session.id then
				request_chat_render({
					session_id = session.id,
					reason = "session_switch_loaded",
				})
			end
		end)
	end)
end

return M
