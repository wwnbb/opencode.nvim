local M = {}

local request_util = require("opencode.events.handlers.permission_flow.request")

---@param events table
---@param data table|nil
---@param logger table
function M.handle_permission_replied(events, data, logger)
	local reply_event = request_util.decode_reply(data)
	if not reply_event then
		return
	end

	local perm_state_ok, permission_state = pcall(require, "opencode.permission.state")
	if not perm_state_ok then return end
	local item = permission_state.get_permission(reply_event.id)
	if not item then return end

	local reply = reply_event.reply
	if reply == "reject" then
		if not permission_state.mark_rejected(reply_event.id) then return end
		events.emit("permission_rejected", {
			permission_id = reply_event.id,
		})
	else
		if not permission_state.mark_approved(reply_event.id, reply) then return end
		events.emit("permission_approved", {
			permission_id = reply_event.id,
			reply = reply,
		})
	end

	events.emit("interaction_changed", {
		kind = "permission",
		action = reply == "reject" and "rejected" or "approved",
		id = reply_event.id,
		session_id = reply_event.session_id or item.session_id,
	})
	logger.debug("Permission reply handled", {
		permission_id = reply_event.id,
		reply = reply,
		sessionID = reply_event.session_id,
	})
end

return M
