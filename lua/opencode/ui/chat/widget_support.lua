local cs = require("opencode.ui.chat.state")
return cs.factory("widget_support", function(view)
local M = {}

local state = view
local render = cs.module(view, require("opencode.ui.chat.render"))
local chat_highlights = require("opencode.ui.chat.highlights")
local event_util = require("opencode.events.util")
local chat_hl_ns = cs.chat_hl_ns
local chat_anim_ns = cs.chat_anim_ns
local render_state = cs.module(view, require("opencode.ui.chat.render_state"))
local tree = require("opencode.ui.chat.widget_tree")
local positions = cs.module(view, require("opencode.ui.chat.positions"))

local FOCUS_ORDER = { "question", "permission", "edit" }
local FOCUS_MAPS = { question = "questions", permission = "permissions", edit = "edits" }

---@param kind string
---@return string, string
local function focus_keys(kind)
	return "focus_" .. kind, "focus_" .. kind .. "_offset"
end

---@param pos table|nil
---@return integer|nil start_line
---@return integer|nil end_line
M.range = positions.range

---@param owner_session_id string|nil
---@param widget_status string|nil
---@param current_session_id string|nil
---@param in_child_session_view boolean
---@return boolean
function M.should_render(owner_session_id, widget_status, current_session_id, in_child_session_view)
	if not current_session_id or current_session_id == "" then
		return false
	end
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
	local focus_key, offset_key = focus_keys(kind)
	if (widget_status or "pending") ~= "pending" then
		if state[focus_key] == widget_id then
			state[focus_key] = nil
			state[offset_key] = nil
		end
		return false
	end

	state[focus_key] = widget_id
	state[offset_key] = nil
	return true
end

---The cursor goes to this row of the widget once the frame is applied.
---@param kind string
---@param widget_id string
---@param offset number 0-based row within the widget
---@return boolean
function M.capture_focus_offset(kind, widget_id, offset)
	local focus_key, offset_key = focus_keys(kind)
	if state[focus_key] ~= widget_id then
		return false
	end

	state[offset_key] = offset
	return true
end

---Row of the cursor within a widget position.
---@param pos table|nil
---@param cursor_line integer 0-based
---@return integer|nil
function M.offset_at_cursor(pos, cursor_line)
	local start_line = positions.range(pos)
	return start_line and (cursor_line - start_line) or nil
end

---Put the cursor on a row of a widget position.
---@param pos table|nil
---@param offset integer 0-based row within the widget
---@return boolean
function M.set_cursor_in(pos, offset)
	local start_line = positions.range(pos)
	if not start_line or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then return false end
	vim.api.nvim_win_set_cursor(state.winid, { start_line + offset + 1, 0 })
	return true
end

---@return string|nil, string|nil
function M.apply_focus_cursor()
	if not cs.is_chat_buffer_displayed(view) then return nil, nil end
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return nil, nil
	end
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	for _, kind in ipairs(FOCUS_ORDER) do
		local focus_key, offset_key = focus_keys(kind)
		local widget_id = state[focus_key]
		local offset = state[offset_key]
		local start_line = widget_id and offset and positions.range((state[FOCUS_MAPS[kind]] or {})[widget_id])
		if start_line then
			vim.api.nvim_win_set_cursor(state.winid, { math.min(start_line + offset + 1, buf_lines), 0 })
			state[focus_key] = nil
			state[offset_key] = nil
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
---@return string|nil root_id Owning root widget id
function M.find_widget_context_at_cursor(state_table, winid, predicate)
	if winid == state.winid and not cs.is_chat_buffer_displayed(view) then return nil, nil end
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local cursor_line = cursor[1] - 1

	return tree.at_line(state_table, cursor_line, predicate, positions.range)
end

---Options passed to widget renderers for this view.
---@return { width: number, render: table }
function M.render_opts()
	return { width = render.get_chat_text_width(), render = render }
end

---Interactive widget at the cursor whose rendered and stored statuses are both allowed.
---@param widget_positions table Rendered positions by widget id
---@param lookup fun(id: string): table|nil Store getter
---@param allowed fun(status: string|nil): boolean
---@return string|nil id
---@return table|nil source Store record
---@return table|nil pos
---@return number|nil cursor_line 0-based cursor row
function M.context_at_cursor(widget_positions, lookup, allowed)
	if not cs.is_chat_buffer_displayed(view) then return nil, nil, nil, nil end
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil, nil, nil
	end
	local cursor_line = vim.api.nvim_win_get_cursor(state.winid)[1] - 1
	local id, pos = tree.at_line(widget_positions, cursor_line, function(node)
		return allowed(node.status)
	end, M.range)
	if not id or not pos then
		return nil, nil, nil, nil
	end
	local source = lookup(id)
	if not source or not allowed(source.status) then
		return nil, nil, nil, nil
	end
	return id, source, pos, cursor_line
end

---Shared in-place rerender: replace a widget's rendered block from its store record.
---@param widget_positions table Rendered positions by widget id
---@param id string
---@param lookup fun(id: string): table|nil Store getter
---@param render_widget fun(source: table, opts: table): table, table, table
---@return table|nil pos
---@return table|nil source
---@return boolean replaced
---@return table|nil meta
function M.rerender_widget(widget_positions, id, lookup, render_widget)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return nil, nil, false, nil
	end
	local pos = widget_positions[id]
	if not pos then
		return nil, nil, false, nil
	end
	local source = lookup(id)
	if not source then
		return pos, nil, false, nil
	end
	local lines, highlights, meta = render_widget(source, M.render_opts())
	return pos, source, M.replace_rendered_block(pos, { lines = lines, highlights = highlights }), meta
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

local META_FIELDS = {
	question = { "questions", "current_tab", "status", "submitting", "field_errors", "server_error", "submission_kind" },
	permission = { "tool_input", "permission_type", "always", "status", "submitting", "error", "message" },
}

-- Cursor coordinates belong to the rendered block, not a newly formatted store.
function M.set_interactive_meta(pos, meta, source, kind)
	local snapshot = { source = source, width = render.get_chat_text_width() }
	for _, field in ipairs(META_FIELDS[kind]) do snapshot[field] = source[field] end
	local selection = source.selections and source.selections[source.current_tab]
	snapshot.custom_input = selection and selection.custom_input
	snapshot.option_count = kind == "permission" and #(source.always or {})
	pos.meta, pos.meta_state = meta, snapshot
end

function M.get_interactive_meta(pos, source, kind)
	local snapshot = pos.meta_state
	if not snapshot or snapshot.source ~= source or snapshot.width ~= render.get_chat_text_width() then return nil end
	local generation = state.render_in_progress and state.render_generation or state.applied_render_generation
	if pos.render_generation and generation and pos.render_generation ~= generation then return nil end
	for _, field in ipairs(META_FIELDS[kind]) do
		if snapshot[field] ~= source[field] then return nil end
	end
	local selection = source.selections and source.selections[source.current_tab]
	if snapshot.custom_input ~= (selection and selection.custom_input)
		or (kind == "permission" and snapshot.option_count ~= #(source.always or {})) then return nil end
	return pos.meta
end

---@param pos table|nil
---@return boolean
function M.can_update_in_place(pos)
	return not M.in_place_updates_blocked() and M.position_generation_is_current(pos)
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
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end
	if not M.can_update_in_place(pos) then
		return false
	end
	local start_line, end_line = positions.range(pos)
	if not start_line then
		return false
	end
	result = M.sanitize_result_lines(result or {})

	local ok = render_state.replace_chat_range({
		bufnr = state.bufnr,
		start_line = start_line,
		end_line = end_line + 1,
		lines = result.lines,
		clear_animation = true,
		apply_highlights = function()
			chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, result.highlights, start_line)
		end,
	})
	if not ok then
		return false
	end

	pos.highlights = result.highlights
	pos.children = tree.positions(result.children, start_line, pos.render_generation)
	positions.place(pos, start_line, start_line + #result.lines - 1)
	M.mark_applied_render_generation(pos)
	return true
end

-- ─── In-place block updates ──────────────────────────────────────────────────

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
	if not cs.is_chat_buffer_displayed(view) then return nil, nil end
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
	local start_line, end_line = positions.range(pos)
	if not start_line then
		return false
	end
	if top_line == nil or bottom_line == nil then
		return true
	end
	return end_line >= top_line and start_line <= bottom_line
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
	local start_line, end_line = positions.range(pos)
	if not start_line then
		return false
	end
	result = M.sanitize_result_lines(result)
	local new_lines = result.lines or {}
	if end_line - start_line + 1 ~= #new_lines then
		return false
	end

	local old_lines = vim.api.nvim_buf_get_lines(state.bufnr, start_line, end_line + 1, false)
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

	local ok = render_state.replace_chat_range({
		bufnr = state.bufnr,
		start_line = start_line,
		end_line = end_line + 1,
		lines = new_lines,
		clear_animation = changed,
		apply_highlights = function()
			chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, result.highlights, start_line)
		end,
	})
	if not ok then
		return false
	end
	pos.highlights = result.highlights
	pos.children = tree.positions(result.children, start_line, pos.render_generation)
	positions.place(pos, start_line, end_line)
	return true
end

---@param widget_positions table
---@param top_line number|nil
---@param bottom_line number|nil
---@param fns table { resolve, is_animating, render, rerender }
---@return boolean updated
function M.update_animating_blocks(widget_positions, top_line, bottom_line, fns)
	local updated = false

	for part_id, pos in pairs(widget_positions) do
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
			local start_line, end_line = M.range(pos)
			if #result.lines ~= (end_line - start_line + 1) then
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

end)
