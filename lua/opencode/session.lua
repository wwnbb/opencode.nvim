-- Action boundary for active-session and global-status mutations.
-- Compatibility events are emitted here instead of from the store itself.

local M = {}

local state = require("opencode.state")
local session_util = require("opencode.util.session")
local event_util = require("opencode.events.util")

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

---@param status any
---@return table
local function normalize_session_status(status)
	if type(status) == "table" then
		return vim.deepcopy(status)
	end
	if type(status) == "string" and status ~= "" then
		return { type = status }
	end
	return { type = "idle" }
end

---@param status any
---@return string
local function session_status_to_global(status)
	local status_type = type(status) == "table" and status.type or status
	if status_type == "busy" or status_type == "retry" or status_type == "streaming" then
		return "streaming"
	end
	if status_type == "error" then
		return "error"
	end
	return "idle"
end

---@param status string
---@return table
local function global_status_to_session(status)
	if status == "streaming" or status == "thinking" then
		return { type = "busy" }
	end
	if status == "error" then
		return { type = "error" }
	end
	return { type = "idle" }
end

---@param session_id string|nil
---@return string|nil
local function runtime_session_id(session_id)
	if not session_id or session_id == "" then
		return nil
	end
	if state.is_runtime_session(session_id) then
		return session_id
	end
	return event_util.runtime_root_for_session(session_id)
end

---@param target_id string
local function close_pending_permissions_for_session(target_id)
	local ok_perm, perm_state = pcall(require, "opencode.permission.state")
	if not ok_perm or type(perm_state.clear_pending_matching) ~= "function" then
		return
	end

	local removed = perm_state.clear_pending_matching(function(pstate)
		local session_id = pstate and pstate.session_id
		return session_id == target_id or event_util.session_owns_task_child(target_id, session_id)
	end)
	if not removed or #removed == 0 then
		return
	end

	local client_ok, client = pcall(require, "opencode.client")
	local logger_ok, logger = pcall(require, "opencode.logger")

	for _, pstate in ipairs(removed) do
		local permission_id = pstate and pstate.permission_id
		if permission_id and client_ok and type(client.respond_permission) == "function" then
			client.respond_permission(permission_id, "reject", { message = "Session closed" }, function(err)
				if err and logger_ok and logger and type(logger.warn) == "function" then
					logger.warn("Failed to reject permission for closed session", {
						permission_id = permission_id,
						session_id = target_id,
						error = err,
					})
				end
			end)
		end

		emit("permission_rejected", {
			permission_id = permission_id,
			session_id = pstate.session_id or target_id,
		})
		emit("permission_removed", {
			permission_id = permission_id,
			session_id = pstate.session_id or target_id,
		})
		emit("interaction_changed", {
			kind = "permission",
			action = "rejected",
			id = permission_id,
			session_id = pstate.session_id or target_id,
		})
	end
end

---@param close_id string
---@return table|nil
local function next_session_after_close(close_id)
	local sessions = state.get_active_sessions()
	local close_index = nil
	local remaining = {}

	for index, session in ipairs(sessions) do
		if session.id == close_id then
			close_index = index
		else
			table.insert(remaining, session)
		end
	end

	if #remaining == 0 then
		return nil
	end
	if not close_index then
		return remaining[1]
	end

	local next_index = math.min(close_index, #remaining)
	return remaining[next_index]
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
	local global_status = session_status_to_global(raw_status)
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
		session_status = global_status_to_session(status)
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

---@param session_id string
---@param status table|string
---@param opts? table { reason?: string }
---@return table|nil previous
function M.set_session_status(session_id, status, opts)
	opts = opts or {}
	if not session_id or session_id == "" then
		return nil
	end

	local normalized = normalize_session_status(status)
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
	return previous
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
	local target_id = runtime_session_id(session_id or current.id)
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

	local current_root = runtime_session_id(current.id)
	local next_session = next_session_after_close(target_id)
	close_pending_permissions_for_session(target_id)
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
		pending = { permissions = 0, questions = 0, edits = 0 },
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
	local function root_session_for_pending(session_id)
		if not session_id or session_id == "" then
			return nil
		end
		if state.is_runtime_session(session_id) then
			return session_id
		end
		return event_util.runtime_root_for_session(session_id)
	end

	local function ensure(session_id)
		local root_session_id = root_session_for_pending(session_id)
		if not root_session_id then
			return nil
		end
		counts[root_session_id] = counts[root_session_id] or { permissions = 0, questions = 0, edits = 0 }
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
			if item.status == "pending" or item.status == "confirming" then
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
		local next_counts = counts[session_id] or { permissions = 0, questions = 0, edits = 0 }
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
				if state.is_runtime_session(session_id)
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
				vim.notify("Failed to load session messages: " .. tostring(err.message or err.error or err), vim.log.levels.WARN)
			end
			if ok_sync and messages and type(sync.handle_session_messages) == "function" then
				sync.handle_session_messages(session.id, messages)
				M.set_message_cache(session.id, messages, {
					reason = "session_switch",
				})
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
