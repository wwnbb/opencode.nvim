local M = {}

---@return table
function M.zero_counts()
	return {
		permissions = 0,
		questions = 0,
		edits = 0,
	}
end

---@param counts table|nil
---@return table
function M.normalize_counts(counts)
	counts = type(counts) == "table" and counts or {}
	return {
		permissions = tonumber(counts.permissions or counts.permission or 0) or 0,
		questions = tonumber(counts.questions or counts.question or 0) or 0,
		edits = tonumber(counts.edits or counts.edit or 0) or 0,
	}
end

---@param counts table|nil
---@return number
function M.total(counts)
	local normalized = M.normalize_counts(counts)
	return normalized.permissions + normalized.questions + normalized.edits
end

---@param counts table|nil
---@return boolean
function M.has_pending(counts)
	return M.total(counts) > 0
end

---@param items table[]|nil
---@param root_session_id string
---@param owns_session fun(root_session_id: string, session_id: string|nil): boolean
---@return table[]
function M.collect_owned(items, root_session_id, owns_session)
	local owned = {}
	if not root_session_id or root_session_id == "" or type(owns_session) ~= "function" then
		return owned
	end

	for _, item in ipairs(items or {}) do
		if type(item) == "table" and owns_session(root_session_id, item.session_id or item.sessionID) then
			table.insert(owned, item)
		end
	end
	return owned
end

---@param item table|nil
---@return boolean
function M.is_pending_question(item)
	local status = type(item) == "table" and item.status or nil
	return status == "pending" or status == "confirming"
end

---@param item table|nil
---@return boolean
function M.is_pending_permission(item)
	return type(item) == "table" and item.status == "pending"
end

---@param item table|nil
---@return boolean
function M.is_pending_edit(item)
	return type(item) == "table" and item.status == "pending"
end

return M
