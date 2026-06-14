local M = {}

local function default_state(ctx)
	if type(ctx) == "table" and ctx.state then
		return ctx.state
	end
	local ok, state = pcall(require, "opencode.state")
	return ok and state or nil
end

local function default_event_util(ctx)
	if type(ctx) == "table" and ctx.event_util then
		return ctx.event_util
	end
	local ok, event_util = pcall(require, "opencode.events.util")
	return ok and event_util or nil
end

---@param session_id string|nil
---@param ctx? table
---@return string|nil
function M.runtime_session_id(session_id, ctx)
	if not session_id or session_id == "" then
		return nil
	end

	local state = default_state(ctx)
	if state and type(state.is_runtime_session) == "function" and state.is_runtime_session(session_id) then
		return session_id
	end

	local event_util = default_event_util(ctx)
	if event_util and type(event_util.runtime_root_for_session) == "function" then
		return event_util.runtime_root_for_session(session_id)
	end
	return nil
end

---@param close_id string
---@param sessions? table[]
---@param ctx? table
---@return table|nil
function M.next_session_after_close(close_id, sessions, ctx)
	if type(sessions) ~= "table" then
		local state = default_state(ctx)
		if state and type(state.get_active_sessions) == "function" then
			sessions = state.get_active_sessions()
		else
			sessions = {}
		end
	end

	local close_index = nil
	local remaining = {}
	for index, session in ipairs(sessions) do
		if type(session) == "table" and session.id == close_id then
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

---@param root_session_id string
---@param session_id string|nil
---@param ctx? table
---@return boolean
function M.session_owned_by_root(root_session_id, session_id, ctx)
	if not root_session_id or root_session_id == "" or not session_id or session_id == "" then
		return false
	end
	if session_id == root_session_id then
		return true
	end

	local event_util = default_event_util(ctx)
	if event_util and type(event_util.runtime_root_for_session) == "function" then
		return event_util.runtime_root_for_session(session_id) == root_session_id
	end
	return false
end

return M
