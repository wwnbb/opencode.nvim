-- Pending-interaction counts (permissions, questions, edits) per session.
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
		permissions = tonumber(counts.permissions or 0) or 0,
		questions = tonumber(counts.questions or 0) or 0,
		edits = tonumber(counts.edits or 0) or 0,
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

---@param item table|nil
---@return boolean
function M.is_pending_question(item)
	local status = type(item) == "table" and item.status or nil
	return status == "pending" or status == "confirming"
end

return M
