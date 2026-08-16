local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")
local chat_highlights = require("opencode.ui.chat.highlights")
local event_util = require("opencode.events.util")
local chat_hl_ns = cs.chat_hl_ns
local chat_anim_ns = cs.chat_anim_ns
local render_state = require("opencode.ui.chat.render_state")

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
	local status = widget_status or "pending"
	if status ~= "pending" and status ~= "confirming" then
		return false
	end
	return event_util.permission_session_is_relevant(current_session_id, owner_session_id)
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

---@param state_table table maps part_id (string) -> position info { start_line, end_line, ... }
---@param winid number|nil window id to check cursor position in
---@param predicate? fun(pos: table, part_id: string): boolean optional filter
---@return string|nil part_id
---@return table|nil pos
function M.find_widget_context_at_cursor(state_table, winid, predicate)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local cursor_line = cursor[1] - 1

	for part_id, pos in pairs(state_table) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line then
			if predicate == nil or predicate(pos, part_id) then
				return part_id, pos
			end
		end
	end

	return nil, nil
end

---@return number
function M.current_render_generation()
	return state.render_generation or 0
end

---@param pos table|nil
---@param generation? number
---@return table|nil
function M.mark_render_generation(pos, generation)
	if type(pos) == "table" then
		pos.render_generation = generation or M.current_render_generation()
	end
	return pos
end

---@param pos table|nil
---@return table|nil
function M.mark_applied_render_generation(pos)
	if type(pos) == "table" then
		pos.render_generation = state.applied_render_generation or state.render_generation or pos.render_generation
	end
	return pos
end

---@return boolean
function M.in_place_updates_blocked()
	return state.render_scheduled == true or state.render_in_progress == true
end

---@param pos table|nil
---@return boolean
function M.position_generation_is_current(pos)
	local applied_generation = state.applied_render_generation
	if type(pos) ~= "table" or not pos.render_generation or not applied_generation then
		return true
	end
	return pos.render_generation == applied_generation
end

---@param pos table|nil
---@return boolean
function M.can_update_in_place(pos)
	return not M.in_place_updates_blocked() and M.position_generation_is_current(pos)
end

---@param old_end number
---@param delta number
---@param opts? table { skip_stream_block_key?: string|nil, skip_stream_message_id?: string|nil }
function M.shift_tracked_lines(old_end, delta, opts)
	if delta == 0 then
		return
	end

	opts = opts or {}

	render.shift_line_map(state.questions, old_end, delta)
	render.shift_line_map(state.permissions, old_end, delta)
	render.shift_line_map(state.edits, old_end, delta)
	render.shift_line_map(state.tasks, old_end, delta)
	render.shift_line_map(state.tools, old_end, delta)

	for _, pos in ipairs(state.message_positions or {}) do
		if pos and pos.start_line and pos.end_line then
			if pos.start_line > old_end then
				pos.start_line = pos.start_line + delta
				pos.end_line = pos.end_line + delta
			elseif pos.end_line >= old_end then
				pos.end_line = pos.end_line + delta
			end
		end
	end

	for block_key, pos in pairs(state.stream_blocks) do
		if
			block_key ~= opts.skip_stream_block_key
			and (not opts.skip_stream_message_id or pos.message_id ~= opts.skip_stream_message_id)
			and pos.start_line
			and pos.end_line
			and pos.start_line > old_end
		then
			pos.start_line = pos.start_line + delta
			pos.end_line = pos.end_line + delta
		end
	end

	if state.spinner_footer_line and state.spinner_footer_line > old_end then
		state.spinner_footer_line = state.spinner_footer_line + delta
	end

	if state.focus_question_line and (state.focus_question_line - 1) > old_end then
		state.focus_question_line = state.focus_question_line + delta
	end
	if state.focus_permission_line and (state.focus_permission_line - 1) > old_end then
		state.focus_permission_line = state.focus_permission_line + delta
	end
	if state.focus_edit_line and (state.focus_edit_line - 1) > old_end then
		state.focus_edit_line = state.focus_edit_line + delta
	end
end

---@param bufnr number|nil
---@param start_line number|nil
---@param end_line number|nil
function M.clear_animation_extmarks(bufnr, start_line, end_line)
	bufnr = bufnr or state.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	pcall(vim.api.nvim_buf_clear_namespace, bufnr, chat_anim_ns, start_line or 0, end_line or -1)
end

---@param pos table
---@param result table { lines: string[], highlights: table[] }
---@return boolean updated
function M.replace_rendered_block(pos, result)
	if not M.can_update_in_place(pos) then
		return false
	end
	result = result or {}
	result.lines = result.lines or {}
	for i, line in ipairs(result.lines) do
		result.lines[i] = render.sanitize_buffer_line(line)
	end
	local old_end = pos.end_line
	local old_line_count = old_end - pos.start_line + 1
	local new_line_count = #result.lines
	local delta = new_line_count - old_line_count

	vim.bo[state.bufnr].modifiable = true
	M.clear_animation_extmarks(state.bufnr, pos.start_line, pos.end_line + 1)
	render_state.clear_chat_highlights(state.bufnr, pos.start_line, pos.end_line + 1)
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, result.lines)
	render_state.clear_chat_highlights(state.bufnr, pos.start_line, pos.start_line + new_line_count)
	chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, result.highlights, pos.start_line)
	vim.bo[state.bufnr].modifiable = false

	M.shift_tracked_lines(old_end, delta)
	pos.end_line = pos.start_line + new_line_count - 1
	pos.highlights = result.highlights
	M.mark_applied_render_generation(pos)
	return true
end

-- ─── In-place block updates ──────────────────────────────────────────────────

function M.apply_result_highlights(result, pos)
	chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, result.highlights, pos.start_line)
end

function M.sanitize_result_lines(result)
	result.lines = result.lines or {}
	for i, line in ipairs(result.lines) do
		result.lines[i] = render.sanitize_buffer_line(line)
	end
	return result
end

---@return number|nil top_line
---@return number|nil bottom_line
function M.get_visible_line_range()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end
	local ok, range = pcall(vim.api.nvim_win_call, state.winid, function()
		return { vim.fn.line("w0") - 1, vim.fn.line("w$") - 1 }
	end)
	if not ok or type(range) ~= "table" then
		return nil, nil
	end
	return range[1], range[2]
end

---@param pos table|nil
---@param top_line number|nil
---@param bottom_line number|nil
---@return boolean
function M.block_is_visible(pos, top_line, bottom_line)
	if not pos or type(pos.start_line) ~= "number" or type(pos.end_line) ~= "number" then
		return false
	end
	if top_line == nil or bottom_line == nil then
		return true
	end
	return pos.end_line >= top_line and pos.start_line <= bottom_line
end

---@param highlights table[]|nil
---@return string
function M.highlight_signature(highlights)
	if type(highlights) ~= "table" then
		return ""
	end
	local parts = {}
	for _, hl in ipairs(highlights) do
		if type(hl) == "table" then
			table.insert(
				parts,
				table.concat({
					tostring(hl.line or 0),
					tostring(hl.end_line or ""),
					tostring(hl.col_start or 0),
					tostring(hl.col_end or hl.end_col or ""),
					tostring(hl.hl_group or ""),
					tostring(hl.priority or ""),
					tostring(hl.hl_eol or ""),
				}, ":")
			)
		end
	end
	return table.concat(parts, "|")
end

---@param pos table
---@param result table
---@return boolean updated
function M.update_block_lines_in_place(pos, result)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end
	result = M.sanitize_result_lines(result)
	local new_lines = result.lines or {}
	local old_count = pos.end_line - pos.start_line + 1
	if old_count ~= #new_lines then
		return false
	end

	local old_lines = vim.api.nvim_buf_get_lines(state.bufnr, pos.start_line, pos.end_line + 1, false)
	local changed = false
	for i, line in ipairs(new_lines) do
		if old_lines[i] ~= line then
			changed = true
			break
		end
	end

	local old_highlight_signature = M.highlight_signature(pos.highlights)
	local new_highlight_signature = M.highlight_signature(result.highlights)
	if not changed and old_highlight_signature == new_highlight_signature then
		return false
	end

	vim.bo[state.bufnr].modifiable = true
	if changed then
		M.clear_animation_extmarks(state.bufnr, pos.start_line, pos.end_line + 1)
		local range_start = nil
		local replacement = {}
		local function flush_range(before_index)
			if not range_start then
				return
			end
			vim.api.nvim_buf_set_lines(
				state.bufnr,
				pos.start_line + range_start - 1,
				pos.start_line + before_index - 1,
				false,
				replacement
			)
			range_start = nil
			replacement = {}
		end

		for i, line in ipairs(new_lines) do
			if old_lines[i] ~= line then
				range_start = range_start or i
				table.insert(replacement, line)
			else
				flush_range(i)
			end
		end
		flush_range(#new_lines + 1)
	end

	render_state.clear_chat_highlights(state.bufnr, pos.start_line, pos.end_line + 1)
	M.apply_result_highlights(result, pos)
	vim.bo[state.bufnr].modifiable = false
	pos.highlights = result.highlights
	return true
end

---@param positions table
---@param top_line number|nil
---@param bottom_line number|nil
---@param fns table { resolve, is_animating, render, rerender }
---@return boolean updated
function M.update_animating_blocks(positions, top_line, bottom_line, fns)
	local updated = false

	for part_id, pos in pairs(positions) do
		local tool_part = fns.resolve(pos)
		if
			fns.is_animating(tool_part)
			and M.position_generation_is_current(pos)
			and M.block_is_visible(pos, top_line, bottom_line)
		then
			local result = fns.render(part_id, pos, tool_part)
			if result == nil then
				goto continue
			end
			if #result.lines ~= (pos.end_line - pos.start_line + 1) then
				fns.rerender(part_id)
				updated = true
			else
				updated = M.update_block_lines_in_place(pos, result) or updated
			end
		end
		::continue::
	end

	return updated
end

return M
