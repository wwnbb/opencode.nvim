local M = {}

local auto_approve = require("opencode.permission.danger")
local request_util = require("opencode.events.handlers.permission_flow.request")

---@param events table
---@param request table
---@param logger table
function M.handle(events, request, logger)

	local permission_state = require("opencode.permission.state")
	local tool_input = request_util.resolve_tool_input(request)
	local tool_name = request_util.resolve_tool_name(request)
	local tracked = permission_state.has_permission(request.id)
	if tracked then
		local item = permission_state.get_permission(request.id)
		local restored = false
		if item.submission_token and not require("opencode.session.pending").is_current(item.submission_token) then
			restored = permission_state.restore_submission(request.id)
		end
		logger.debug("Permission already tracked", { permission_id = request.id })
		if permission_state.enrich_permission(request.id, { tool_input = tool_input, tool_name = tool_name }) or restored then
			events.emit("interaction_changed", {
				kind = "permission",
				action = "updated",
				id = request.id,
				session_id = request.session_id,
			})
		end
	else
		permission_state.add_permission(request.id, request.session_id, request.type, {
			metadata = request.metadata,
			location = request.location,
			patterns = request.patterns,
			always = request.always,
			tool_input = tool_input,
			tool_name = tool_name,
			message_id = request.message_id,
			call_id = request.call_id,
			timestamp = request.timestamp,
		})
	end
	if require("opencode.state").is_danger_mode_enabled() then
		local handled = auto_approve.approve(request.id, {
			permission_type = request.type,
			session_id = request.session_id,
			kind = "permission",
		})
		if handled then
			return
		end
	end

	if tracked then return end
	events.emit("permission_pending", {
		permission_id = request.id,
		permission_type = request.type,
		session_id = request.session_id,
		message_id = request.message_id,
		call_id = request.call_id,
	})
	events.emit("interaction_changed", {
		kind = "permission",
		action = "pending",
		id = request.id,
		session_id = request.session_id,
	})

	logger.info("Permission request added", {
		permission_id = request.id,
		type = request.type,
	})
end

return M
