local M = {}

local auto_approve = require("opencode.permission.danger")
local request_util = require("opencode.events.handlers.permission_flow.request")

---@param events table
---@param data table|nil
function M.handle_session_change(events, data)
	if data and data.preserve_cache then
		return
	end

	auto_approve.clear()

	local perm_state_ok, permission_state = pcall(require, "opencode.permission.state")
	if perm_state_ok then
		for _, permission_id in ipairs(permission_state.clear_all() or {}) do
			events.emit("permission_removed", { permission_id = permission_id })
		end
	end

	local edit_state_ok, edit_state = pcall(require, "opencode.edit.state")
	if edit_state_ok then
		for _, permission_id in ipairs(edit_state.clear_all() or {}) do
			events.emit("edit_removed", { permission_id = permission_id })
		end
	end
end

---@param raw_reply any
---@return string
local function normalize_reply(raw_reply)
	if raw_reply == "reject" then
		return "reject"
	end
	if raw_reply == "always" then
		return "always"
	end
	return "once"
end

---@param events table
---@param data table|nil
---@param logger table
function M.handle_permission_replied(events, data, logger)
	local reply_event = request_util.decode_reply(data)
	if not reply_event then
		return
	end

	local reply = normalize_reply(reply_event.reply)
	local changed = false

	local perm_state_ok, permission_state = pcall(require, "opencode.permission.state")
	if perm_state_ok and permission_state.has_permission and permission_state.has_permission(reply_event.id) then
		if reply == "reject" then
			changed = permission_state.mark_rejected(reply_event.id) or changed
			events.emit("permission_rejected", {
				permission_id = reply_event.id,
			})
		else
			changed = permission_state.mark_approved(reply_event.id, reply) or changed
			events.emit("permission_approved", {
				permission_id = reply_event.id,
				reply = reply,
			})
		end
	end

	local edit_state_ok, edit_state = pcall(require, "opencode.edit.state")
	if edit_state_ok and edit_state.get_edit and edit_state.get_edit(reply_event.id) then
		edit_state.mark_sent(reply_event.id)
		changed = true
		events.emit("interaction_changed", {
			kind = "edit",
			action = "sent",
			id = reply_event.id,
			session_id = reply_event.session_id,
		})
	end

	if changed then
		local session = require("opencode.state").get_session()
		events.emit("interaction_changed", {
			kind = "permission",
			action = reply == "reject" and "rejected" or "approved",
			id = reply_event.id,
			session_id = reply_event.session_id or (session and session.id),
		})
		logger.debug("Permission reply handled", {
			permission_id = reply_event.id,
			reply = reply_event.reply,
			sessionID = reply_event.session_id,
		})
	end
end

return M
