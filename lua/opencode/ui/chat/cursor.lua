local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

local chat_interactions = require("opencode.ui.chat.interactions")

---@class OpenCodeWidgetCursorContext
---@field kind "question" | "permission" | "edit"
---@field id string
---@field relative_line number

---@param kind "question" | "permission" | "edit"
---@return table
local function get_widget_positions(kind)
	if kind == "question" then
		return state.questions
	end
	if kind == "permission" then
		return state.permissions
	end
	return state.edits
end

---@param kind "question" | "permission" | "edit"
---@param pos table|nil
---@return boolean
local function is_widget_cursor_target(kind, pos)
	if not pos then
		return false
	end

	if kind == "question" then
		return pos.status == "pending" or pos.status == "confirming"
	end
	if kind == "permission" then
		return pos.status == "pending"
	end
	return pos.status ~= "sent"
end

---@return number|nil min_line
---@return number|nil max_line
local function interactive_widget_bounds()
	local min_line = nil
	local max_line = nil
	local widget_kinds = { "question", "permission", "edit" }
	for _, kind in ipairs(widget_kinds) do
		for _, pos in pairs(get_widget_positions(kind)) do
			if is_widget_cursor_target(kind, pos) then
				min_line = min_line and math.min(min_line, pos.start_line) or pos.start_line
				max_line = max_line and math.max(max_line, pos.end_line) or pos.end_line
			end
		end
	end
	return min_line, max_line
end

---@return OpenCodeWidgetCursorContext|nil
local function capture_widget_cursor_context()
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(state.winid)[1] - 1
	local widget_kinds = { "question", "permission", "edit" }

	for _, kind in ipairs(widget_kinds) do
		for widget_id, pos in pairs(get_widget_positions(kind)) do
			if
				is_widget_cursor_target(kind, pos)
				and cursor_line >= pos.start_line
				and cursor_line <= pos.end_line
			then
				return {
					kind = kind,
					id = widget_id,
					relative_line = cursor_line - pos.start_line,
				}
			end
		end
	end

	return nil
end

---@param widget_cursor OpenCodeWidgetCursorContext|nil
---@return boolean
local function restore_widget_cursor_context(widget_cursor)
	if not widget_cursor then
		return false
	end
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return false
	end
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end

	local pos = get_widget_positions(widget_cursor.kind)[widget_cursor.id]
	if not is_widget_cursor_target(widget_cursor.kind, pos) then
		return false
	end

	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	local min_line = math.min(pos.start_line + 1, buf_lines)
	local max_line = math.min(pos.end_line + 1, buf_lines)
	if min_line <= 0 or max_line <= 0 then
		return false
	end

	local target_line = pos.start_line + widget_cursor.relative_line + 1
	target_line = math.max(min_line, math.min(target_line, max_line))

	vim.api.nvim_win_set_cursor(state.winid, { target_line, 0 })
	chat_interactions.sync_widget_selection_from_cursor()
	return true
end

---@param widget_cursor OpenCodeWidgetCursorContext|nil
---@return boolean
local function should_auto_scroll(widget_cursor)
	if widget_cursor then
		return false
	end
	if not state.auto_scroll or not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local win_height = vim.api.nvim_win_get_height(state.winid)
	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	return cursor[1] >= buf_lines - win_height - 1
end

M.get_widget_positions = get_widget_positions
M.is_widget_cursor_target = is_widget_cursor_target
M.interactive_widget_bounds = interactive_widget_bounds
M.capture_widget_cursor_context = capture_widget_cursor_context
M.restore_widget_cursor_context = restore_widget_cursor_context
M.should_auto_scroll = should_auto_scroll

return M
