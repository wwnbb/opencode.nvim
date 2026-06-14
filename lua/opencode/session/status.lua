local M = {}

---@param status any
---@return table
function M.normalize_session_status(status)
	if type(status) == "table" then
		return vim.deepcopy(status)
	end
	if type(status) == "string" and status ~= "" then
		return { type = status }
	end
	return { type = "idle" }
end

---@param status any
---@return string
function M.status_type(status)
	local status_type = type(status) == "table" and status.type or status
	if type(status_type) == "string" and status_type ~= "" then
		return status_type
	end
	return "idle"
end

---@param status any
---@return string
function M.session_status_to_global(status)
	local kind = M.status_type(status)
	if kind == "busy" or kind == "retry" or kind == "streaming" then
		return "streaming"
	end
	if kind == "error" then
		return "error"
	end
	return "idle"
end

---@param status string
---@return table
function M.global_status_to_session(status)
	if status == "streaming" or status == "thinking" then
		return { type = "busy" }
	end
	if status == "error" then
		return { type = "error" }
	end
	return { type = "idle" }
end

---@param status any
---@return boolean
function M.is_busy(status)
	local kind = M.status_type(status)
	return kind == "busy" or kind == "retry" or kind == "streaming"
end

---@param status any
---@return boolean
function M.is_idle(status)
	return M.status_type(status) == "idle"
end

---@param status any
---@return boolean
function M.is_error(status)
	return M.status_type(status) == "error"
end

---@param status any
---@return string
function M.status_label(status)
	local kind = M.status_type(status)
	if kind == "busy" or kind == "streaming" then
		return "running"
	end
	if kind == "retry" then
		local attempt = type(status) == "table" and status.attempt or nil
		return attempt and ("retry #" .. attempt) or "retry"
	end
	if kind == "error" then
		return "error"
	end
	return "idle"
end

return M
