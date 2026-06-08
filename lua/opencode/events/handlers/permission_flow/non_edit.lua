local M = {}

local auto_approve = require("opencode.permission.danger")
local interaction = require("opencode.events.handlers.permission_flow.interaction")
local request_util = require("opencode.events.handlers.permission_flow.request")

---@param current_session table|nil
---@return string|nil
local function current_session_id(current_session)
	return type(current_session) == "table" and current_session.id or nil
end

---@param events table
---@param request table
---@param current_session table|nil
---@param logger table
function M.handle(events, request, current_session, logger)
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

	local permission_state = require("opencode.permission.state")
	permission_state.add_permission(request.id, request.session_id, request.type, {
		metadata = request.metadata,
		patterns = request.patterns,
		always = request.always,
		tool_input = request_util.resolve_tool_input(request),
		message_id = request.message_id,
		call_id = request.call_id,
		timestamp = request.timestamp,
	})
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

	interaction.stop_spinner_if_visible(current_session_id(current_session), request.session_id, logger, "permission")
	logger.info("Permission request added", {
		permission_id = request.id,
		type = request.type,
	})
end

return M
