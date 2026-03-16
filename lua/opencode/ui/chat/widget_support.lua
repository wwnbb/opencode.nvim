local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

local FOCUS_ORDER = { "question", "permission", "edit" }

---@param kind string
---@return string, string
local function focus_keys(kind)
	return "focus_" .. kind, "focus_" .. kind .. "_line"
end

---@param owner_session_id string|nil
---@param widget_status string|nil
---@param current_session_id string
---@param in_child_session_view boolean
---@return boolean
function M.should_render(owner_session_id, widget_status, current_session_id, in_child_session_view)
	if owner_session_id == current_session_id then
		return true
	end
	if in_child_session_view then
		return false
	end
	return (widget_status or "pending") == "pending"
end

---@param kind string
---@param widget_id string
---@param widget_status string|nil
---@return boolean
function M.request_focus(kind, widget_id, widget_status)
	local focus_key, line_key = focus_keys(kind)
	if (widget_status or "pending") ~= "pending" then
		if state[focus_key] == widget_id then
			state[focus_key] = nil
			state[line_key] = nil
		end
		return false
	end

	state[focus_key] = widget_id
	state[line_key] = nil
	return true
end

---@param kind string
---@param widget_id string
---@param line number
---@return boolean
function M.capture_focus_line(kind, widget_id, line)
	local focus_key, line_key = focus_keys(kind)
	if state[focus_key] ~= widget_id then
		return false
	end

	state[line_key] = line
	return true
end

---@return string|nil, string|nil
function M.apply_focus_cursor()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return nil, nil
	end
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	for _, kind in ipairs(FOCUS_ORDER) do
		local focus_key, line_key = focus_keys(kind)
		local widget_id = state[focus_key]
		local line = state[line_key]
		if widget_id and line then
			vim.api.nvim_win_set_cursor(state.winid, { math.min(line, buf_lines), 0 })
			state[focus_key] = nil
			state[line_key] = nil
			return kind, widget_id
		end
	end

	return nil, nil
end

return M
