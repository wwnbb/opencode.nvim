-- Per-session child-agent execution locks.

local M = {}

local locks = {}

---@param session_id string|nil
---@return boolean
local function valid_session_id(session_id)
	return type(session_id) == "string" and session_id ~= ""
end

---@param session_id string
---@param record table
---@return table|nil
function M.set(session_id, record)
	if not valid_session_id(session_id) or type(record) ~= "table" then
		return nil
	end

	local value = vim.deepcopy(record)
	value.session_id = session_id
	locks[session_id] = value
	return vim.deepcopy(value)
end

---@param session_id string|nil
---@return table|nil
function M.get(session_id)
	if not valid_session_id(session_id) or not locks[session_id] then
		return nil
	end
	return vim.deepcopy(locks[session_id])
end

-- Lock local controls while following authoritative selections from the server.
function M.update_selection(session_id, selection)
	local value = valid_session_id(session_id) and locks[session_id]
	if not value or type(selection) ~= "table" then return end
	local agent = type(selection.agent) == "string" and selection.agent ~= "" and selection.agent or nil
	local model = selection.model and require("opencode.protocol.requests").model(selection.model)
	if model and (model.providerID == "" or model.id == "") then model = nil end
	if not agent and not model then return end
	value.child_session = value.child_session or { id = session_id }
	if agent then
		value.agent, value.child_session.agent = agent, agent
	end
	if model then
		value.model = { providerID = model.providerID, modelID = model.id }
		value.variant, value.pending = model.variant, nil
		value.child_session.model = vim.deepcopy(selection.model)
	end
	value.error = nil
end

---@param session_id string|nil
---@return boolean
function M.is_locked(session_id)
	return valid_session_id(session_id) and locks[session_id] ~= nil
end

---@param session_id string|nil
function M.clear(session_id)
	if valid_session_id(session_id) then
		locks[session_id] = nil
	end
end

function M.clear_all()
	locks = {}
end

return M
