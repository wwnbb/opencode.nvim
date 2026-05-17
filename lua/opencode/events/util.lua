local M = {}

function M.event_time_to_seconds(raw_time)
	if type(raw_time) ~= "number" then
		return nil
	end
	if raw_time > 100000000000 then
		return math.floor(raw_time / 1000)
	end
	return math.floor(raw_time)
end

---@param payload table|nil
---@return string|nil
function M.resolve_event_message_id(payload)
	if type(payload) ~= "table" then
		return nil
	end

	local tool = payload.tool
	if type(tool) == "table" then
		local nested = tool.messageID or tool.message_id or tool.messageId
		if type(nested) == "string" and nested ~= "" then
			return nested
		end
	end

	local direct = payload.messageID or payload.message_id or payload.messageId
	if type(direct) == "string" and direct ~= "" then
		return direct
	end

	return nil
end

---@param payload table|nil
---@return string|nil
function M.resolve_event_call_id(payload)
	if type(payload) ~= "table" then
		return nil
	end

	local tool = payload.tool
	if type(tool) == "table" then
		local nested = tool.callID or tool.call_id or tool.callId
		if type(nested) == "string" and nested ~= "" then
			return nested
		end
	end

	local direct = payload.callID or payload.call_id or payload.callId
	if type(direct) == "string" and direct ~= "" then
		return direct
	end

	return nil
end

---@param tool_part table|nil
---@return string|nil
function M.resolve_task_child_session_id(tool_part)
	if type(tool_part) ~= "table" or tool_part.tool ~= "task" then
		return nil
	end

	local part_metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}

	return state_metadata.sessionId
		or state_metadata.sessionID
		or state_metadata.childSessionID
		or state_metadata.child_session_id
		or part_metadata.sessionId
		or part_metadata.sessionID
		or part_metadata.childSessionID
		or part_metadata.child_session_id
end

---@param parent_session_id string|nil
---@param child_session_id string|nil
---@return boolean
function M.session_owns_task_child(parent_session_id, child_session_id)
	if not parent_session_id or parent_session_id == "" or not child_session_id or child_session_id == "" then
		return false
	end

	local ok_sync, sync = pcall(require, "opencode.sync")
	if not ok_sync then
		return false
	end

	for _, message in ipairs(sync.get_messages(parent_session_id) or {}) do
		for _, part in ipairs(sync.get_message_tools(message.id) or {}) do
			if M.resolve_task_child_session_id(part) == child_session_id then
				return true
			end
		end
	end

	return false
end

---@param session_id string|nil
---@return string|nil
function M.runtime_root_for_session(session_id)
	if not session_id or session_id == "" then
		return nil
	end

	local ok_state, state = pcall(require, "opencode.state")
	if not ok_state then
		return session_id
	end
	if state.is_runtime_session(session_id) then
		return session_id
	end

	for _, session in ipairs(state.get_active_sessions()) do
		if M.session_owns_task_child(session.id, session_id) then
			return session.id
		end
	end

	return nil
end

---@param current_session_id string|nil
---@param event_session_id string|nil
---@return boolean
function M.permission_session_is_relevant(current_session_id, event_session_id)
	if not event_session_id or event_session_id == "" then
		return true
	end
	if not current_session_id or current_session_id == "" then
		return true
	end
	if event_session_id == current_session_id then
		return true
	end

	return M.session_owns_task_child(current_session_id, event_session_id)
end


return M
