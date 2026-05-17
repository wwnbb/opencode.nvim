local M = {}

local session_util = require("opencode.util.session")
local event_util = require("opencode.events.util")

---@param status table|string|nil
---@return string
local function status_label(status)
	local status_type = type(status) == "table" and status.type or status
	if status_type == "busy" or status_type == "streaming" then
		return "running"
	end
	if status_type == "retry" then
		local attempt = type(status) == "table" and status.attempt or nil
		return attempt and ("retry #" .. attempt) or "retry"
	end
	if status_type == "error" then
		return "error"
	end
	return "idle"
end

---@param pending table|nil
---@return number
local function pending_total(pending)
	pending = pending or {}
	return (pending.permissions or 0) + (pending.questions or 0) + (pending.edits or 0)
end

---@param session table
---@return string
local function stats_label(session)
	local pieces = { status_label(session.status) }
	local pending = session.pending or {}
	if pending_total(pending) > 0 then
		table.insert(
			pieces,
			string.format(
				"wait p%d q%d e%d",
				pending.permissions or 0,
				pending.questions or 0,
				pending.edits or 0
			)
		)
	end
	local cache_count = session.cached_messages and session.cached_messages.count
	local count = session.message_count or session.messageCount or cache_count or 0
	if count > 0 then
		table.insert(pieces, count .. " msgs")
	end
	return table.concat(pieces, " · ")
end

local function refresh_data(callback)
	local session_actions = require("opencode.session")
	session_actions.refresh_status(function()
		session_actions.recount_pending()
		callback()
	end)
end

function M.show()
	refresh_data(function()
		local app_state = require("opencode.state")
		local sessions = app_state.get_active_sessions()
		local current = app_state.get_session()
		local current_root_session_id = nil
		if current.id and not app_state.is_runtime_session(current.id) then
			for _, session in ipairs(sessions) do
				if event_util.session_owns_task_child(session.id, current.id) then
					current_root_session_id = session.id
					break
				end
			end
		end
		if #sessions == 0 then
			vim.notify("No OpenCode sessions found", vim.log.levels.INFO)
			return
		end

		local items = {}
		for index, session in ipairs(sessions) do
			local title = session_util.displayTitle(session.title or session.name) or session.id
			local is_current = session.is_current or current_root_session_id == session.id
			local marker = is_current and "● " or "  "
			table.insert(items, {
				label = marker .. title,
				value = session.id,
				session = session,
				description = stats_label(session),
				priority = is_current and 100 or (100 - index),
				sort_index = index,
			})
		end

		local float = require("opencode.ui.float")
		float.create_menu(items, function(item)
			require("opencode.session").switch_to(item.session, {
				notify = true,
				reason = "active_sessions",
			})
		end, {
			title = " Active Sessions ",
			width = 76,
			footer_text = " ↑↓/j,k:navigate  ⏎:select  esc:close ",
		})
	end)
end

return M
