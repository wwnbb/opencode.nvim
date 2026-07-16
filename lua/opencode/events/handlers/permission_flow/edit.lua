local M = {}

local util = require("opencode.events.util")
local auto_approve = require("opencode.permission.danger")
local interaction = require("opencode.events.handlers.permission_flow.interaction")

---@param current_session table|nil
---@return string|nil
local function current_session_id(current_session)
	return type(current_session) == "table" and current_session.id or nil
end

---@param request table
---@param current_session table|nil
---@return boolean
local function session_is_relevant(request, current_session)
	return util.permission_session_is_relevant(current_session_id(current_session), request.session_id)
		or util.runtime_root_for_session(request.session_id) ~= nil
end

---@param events table
---@param request table
---@param current_session table|nil
---@param logger table
function M.handle(events, request, current_session, logger)
	if not session_is_relevant(request, current_session) then
		logger.debug("edit permission belongs to an unrelated session, skipping", {
			event_session = request.session_id,
			current_session = current_session_id(current_session),
			permission_type = request.type,
		})
		return
	end

	local edit_state = require("opencode.edit.state")

	if require("opencode.state").is_danger_mode_enabled() then
		local handled = auto_approve.approve(request.id, {
			permission_type = request.type,
			session_id = request.session_id,
			kind = "edit",
		})
		if handled then
			if not edit_state.get_edit(request.id) and #(request.files or {}) > 0 then
				local file_statuses = {}
				for _ = 1, #(request.files or {}) do
					table.insert(file_statuses, "accepted")
				end
				edit_state.add_edit(request.id, request.session_id, request.files, {
					data = request.data,
					metadata = request.metadata,
					message_id = request.message_id,
					call_id = request.call_id,
					review_mode = "readonly",
					status = "sent",
					file_statuses = file_statuses,
					preview = true,
					timestamp = request.timestamp,
				})
			end
			return
		end
	end

	if edit_state.get_edit(request.id) then
		logger.debug("edit permission already handled, skipping", {
			id = request.id,
			type = request.type,
		})
		return
	end

	edit_state.add_edit(request.id, request.session_id, request.files or {}, {
		data = request.data,
		metadata = request.metadata,
		message_id = request.message_id,
		call_id = request.call_id,
		review_mode = request.review_mode,
		timestamp = request.timestamp,
	})
	events.emit("edit_pending", {
		permission_id = request.id,
		file_count = #(request.files or {}),
		session_id = request.session_id,
		message_id = request.message_id,
		call_id = request.call_id,
	})
	events.emit("interaction_changed", {
		kind = "edit",
		action = "pending",
		id = request.id,
		session_id = request.session_id,
	})

	interaction.stop_spinner_if_visible(current_session_id(current_session), request.session_id, logger, "edit")
end

return M
