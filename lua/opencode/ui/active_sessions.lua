local M = {}

local actions = require("opencode.actions")
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
	actions.refresh_session_activity(callback)
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
		local function make_label(session)
			local title = session_util.displayTitle(session.title or session.name) or session.id
			local is_current = session.is_current or current_root_session_id == session.id
			local marker = is_current and "● " or "  "
			return marker .. title
		end

		for index, session in ipairs(sessions) do
			local is_current = session.is_current or current_root_session_id == session.id
			table.insert(items, {
				label = make_label(session),
				value = session.id,
				session = session,
				description = stats_label(session),
				priority = is_current and 100 or (100 - index),
				sort_index = index,
			})
		end

		local function refresh_labels()
			local next_current = app_state.get_session()
			for index, item in ipairs(items) do
				local session = item.session or {}
				session.is_current = next_current.id == session.id
				item.label = make_label(session)
				item.priority = session.is_current and 100 or (100 - (item.sort_index or index))
			end
		end

			local float = require("opencode.ui.float")
			float.create_menu(items, function(item)
				actions.switch_session(item.session, {
					notify = true,
					reason = "active_sessions",
				})
		end, {
			title = " Active Sessions ",
			width = 76,
			footer_text = " ↑↓/j,k:navigate  ⏎:select  x:close tab  esc:close ",
			custom_key = {
				key = "x",
				text = "x:close tab",
				on_key = function(item)
					local closed = require("opencode.actions").close_session({
						session_id = item.value,
						notify = true,
					})
					if not closed then
						return true
					end
					for i = #items, 1, -1 do
						if items[i].value == item.value then
							table.remove(items, i)
							break
						end
					end
					refresh_labels()
					return #items > 0
				end,
			},
		})
	end)
end

return M
