local M = {}

local event_util = require("opencode.events.util")

local function get_notifications_config()
	local state = require("opencode.state")
	local cfg = state.get_config() or {}
	return cfg.notifications or {}
end

---@param session_id string|nil
---@return string
local function session_title(session_id)
	if not session_id or session_id == "" then
		return "OpenCode"
	end
	local state = require("opencode.state")
	local session = state.get_session_record(session_id)
	if session and (session.title or session.name) then
		return session.title or session.name
	end
	local current = state.get_session()
	if current.id == session_id and current.name then
		return current.name
	end
	return session_id
end

---@param kind string
---@param session_id string|nil
---@return boolean
local function should_notify(kind, session_id)
	local cfg = get_notifications_config()
	if cfg.enabled == false or cfg[kind] == false then
		return false
	end
	local state = require("opencode.state")
	local notify_session_id = event_util.runtime_root_for_session(session_id) or session_id
	if notify_session_id and not state.is_runtime_session(notify_session_id) then
		local current = state.get_session()
		if current.id ~= session_id and current.id ~= notify_session_id then
			return false
		end
	end
	if cfg.current_session == false and notify_session_id then
		local current = state.get_session()
		if
			current.id == session_id
			or current.id == notify_session_id
			or event_util.session_owns_task_child(notify_session_id, current.id)
		then
			return false
		end
	end
	return true
end

---@param session_id string|nil
---@param message string
---@param level integer|nil
local function notify(session_id, message, level)
	local notify_session_id = event_util.runtime_root_for_session(session_id) or session_id
	local title = session_title(notify_session_id)
	if title ~= "" and title ~= "OpenCode" then
		message = title .. ": " .. message
	end
	vim.notify(message, level or vim.log.levels.INFO)
end

---@param err any
---@return string
local function format_session_error(err)
	if type(err) == "string" then
		return err
	end
	if type(err) ~= "table" then
		return tostring(err or "Session error")
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
	return "Session error"
end

---@param err any
---@return boolean
local function is_abort_error(err)
	if type(err) == "string" then
		return vim.trim(err):lower() == "aborted"
	end
	if type(err) ~= "table" then
		return false
	end
	local name = err.name or err._tag
	if name == "MessageAbortedError" or name == "AbortError" then
		return true
	end
	if type(err.message) == "string" then
		return vim.trim(err.message):lower() == "aborted"
	end
	return type(err.data) == "table"
		and type(err.data.message) == "string"
		and vim.trim(err.data.message):lower() == "aborted"
end

function M.setup(events)
	local active = {}
	local errored = {}
	local permissions = {}
	local questions = {}
	local edits = {}

	events.on("permission_pending", function(data)
		vim.schedule(function()
			local id = data and data.permission_id
			if not id or permissions[id] then
				return
			end
			permissions[id] = true
			if should_notify("permissions", data and data.session_id) then
				notify(data and data.session_id, "Permission needs input", vim.log.levels.WARN)
			end
		end)
	end)

	events.on("permission_approved", function(data)
		permissions[data and data.permission_id] = nil
	end)

	events.on("permission_rejected", function(data)
		permissions[data and data.permission_id] = nil
	end)

	events.on("question_pending", function(data)
		vim.schedule(function()
			local id = data and data.request_id
			if not id or questions[id] then
				return
			end
			questions[id] = true
			if should_notify("questions", data and data.session_id) then
				notify(data and data.session_id, "Question needs input", vim.log.levels.WARN)
			end
		end)
	end)

	events.on("question_answered", function(data)
		questions[data and data.request_id] = nil
	end)

	events.on("question_rejected", function(data)
		questions[data and data.request_id] = nil
	end)

	events.on("edit_pending", function(data)
		vim.schedule(function()
			local id = data and data.permission_id
			if not id or edits[id] then
				return
			end
			edits[id] = true
			if should_notify("edits", data and data.session_id) then
				local count = data and data.file_count or 0
				local suffix = count > 0 and (" (" .. count .. " file" .. (count == 1 and "" or "s") .. ")") or ""
				notify(data and data.session_id, "Edit review needs input" .. suffix, vim.log.levels.WARN)
			end
		end)
	end)

	events.on("interaction_changed", function(data)
		if data and data.kind == "edit" and data.action == "sent" then
			edits[data.id] = nil
		end
	end)

	events.on("session_status_change", function(data)
		vim.schedule(function()
			local session_id = data and data.session_id
			local status = data and data.status
			local status_type = type(status) == "table" and status.type or status
			if not session_id or not status_type then
				return
			end
			local root_session_id = event_util.runtime_root_for_session(session_id) or session_id
			if not require("opencode.state").is_runtime_session(root_session_id) then
				return
			end
			if data.reason == "session_abort" or data.reason == "send_failed" or data.reason == "abort" then
				active[root_session_id] = nil
				errored[root_session_id] = nil
				return
			end

			if status_type == "busy" or status_type == "retry" then
				active[root_session_id] = true
				errored[root_session_id] = nil
				return
			end

			if status_type ~= "idle" then
				return
			end
			if not active[root_session_id] then
				return
			end
			active[root_session_id] = nil

			if errored[root_session_id] then
				errored[root_session_id] = nil
				return
			end
			if should_notify("done", root_session_id) then
				notify(root_session_id, "Session done", vim.log.levels.INFO)
			end
		end)
	end)

	events.on("session_error", function(data)
		vim.schedule(function()
			local session_id = data and data.sessionID
			if not session_id or is_abort_error(data and data.error) then
				return
			end
			local root_session_id = event_util.runtime_root_for_session(session_id) or session_id
			if not require("opencode.state").is_runtime_session(root_session_id) then
				return
			end
			errored[root_session_id] = true
			active[root_session_id] = nil
			if should_notify("errors", root_session_id) then
				notify(root_session_id, format_session_error(data and data.error), vim.log.levels.ERROR)
			end
		end)
	end)
end

return M
