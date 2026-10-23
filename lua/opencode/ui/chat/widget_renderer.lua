local cs = require("opencode.ui.chat.state")
return cs.factory("widget_renderer", function(view)
local M = {}

local state = view
local render = cs.module(view, require("opencode.ui.chat.render"))
local panel = require("opencode.ui.panel")
local event_util = require("opencode.events.util")
local question_widget = require("opencode.ui.question_widget")
local permission_widget = require("opencode.ui.permission_widget")
local edit_widget = require("opencode.ui.edit_widget")
local widget_base = require("opencode.ui.widget_base")
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local chat_bash = cs.module(view, require("opencode.ui.chat.bash"))

local function ensure_session_error_highlights()
	panel.set_hl("OpenCodeSessionError", "DiagnosticError", "ErrorMsg")
	panel.set_hl("OpenCodeSessionErrorBorder", "DiagnosticError", "ErrorMsg")
end

local function capture_widget_focus(kind, widget_id, widget_start, meta)
	local focus_offset = widget_base.get_focus_offset(meta)
	if kind == "question" and state.focus_question == widget_id then
		local qstate = require("opencode.question.state").get_question(widget_id)
		focus_offset = question_widget.get_selection_focus_offset(meta, qstate.selections[qstate.current_tab], state.focus_question_option)
		state.focus_question_option = nil
	end
	if focus_offset == nil then
		return
	end
	widget_support.capture_focus_line(kind, widget_id, widget_start + focus_offset + 1)
end

local function append_interactive_widget(ctx, widget)
	-- An attached widget continues the tool row's panel, so it takes no separators.
	local start_line = widget.attached and ctx:line_count() or ctx:prepare_widget_start()
	capture_widget_focus(widget.kind, widget.id, start_line, widget.meta)
	for _, line_text in ipairs(widget.lines) do
		ctx:add_raw_line(line_text, widget.attached and "tool" or nil)
	end

	local position = {
		start_line = start_line,
		end_line = start_line + #widget.lines - 1,
		status = widget.status,
		highlights = widget.highlights,
		meta = widget.meta,
		tool_row = widget.tool_row,
	}
	widget_support.mark_render_generation(position)
	if widget.source then widget_support.set_interactive_meta(position, widget.meta, widget.source, widget.kind) end
	widget.positions[widget.id] = position
	if not widget.attached then ctx:add_raw_line("") end
end

---What the tool row rendered for a call shows, for the permission widgets below it.
---@param tool_part table|nil
---@return table|nil tool_row { tool, end_line, command, folded }
local function tool_row_for(tool_part)
	local part_id = type(tool_part) == "table" and tool_part.id or nil
	local pos = part_id and state.tools[part_id]
	if not pos or type(pos.tool_part) ~= "table" or pos.end_line < pos.start_line then
		return nil
	end
	local command, folded = chat_bash.row_command(pos.tool_part, state.expanded_tools[part_id] == true)
	return { tool = pos.tool_part.tool, end_line = pos.end_line, command = command, folded = folded }
end

function M.render_single_question(ctx, index, qstate)
	if not qstate then
		return
	end
	local request_id = qstate.request_id
	local status = qstate.status or "pending"

	if not index:should_render_session_widget(qstate.session_id, status) then
		return
	end

	local q_lines, q_highlights, q_meta = question_widget.render(qstate, widget_support.render_opts())

	append_interactive_widget(ctx, {
		kind = "question",
		id = request_id,
		lines = q_lines,
		highlights = q_highlights,
		meta = q_meta,
		status = status,
		positions = state.questions,
		source = qstate,
	})
end

function M.render_single_permission(ctx, _index, pstate, tool_row)
	local perm_id = pstate.permission_id
	local pstatus = pstate.status or "pending"
	-- A status line belongs directly below its row; anywhere else it renders as a full panel.
	if tool_row and permission_widget.attaches(pstate, tool_row) and ctx:line_count() - 1 ~= tool_row.end_line then
		tool_row = nil
	end
	local opts = widget_support.render_opts()
	opts.tool_row = tool_row
	local p_lines, p_highlights, p_meta = permission_widget.render(pstate, opts)

	if p_lines then
		append_interactive_widget(ctx, {
			kind = "permission",
			id = perm_id,
			lines = p_lines,
			highlights = p_highlights,
			meta = p_meta,
			status = pstatus,
			positions = state.permissions,
			source = pstate,
			attached = p_meta.attached == true,
			tool_row = tool_row,
		})
		-- A later status line for the same call attaches below this one.
		if p_meta.attached then tool_row.end_line = ctx:line_count() - 1 end
	end
end

function M.render_single_edit(ctx, _index, estate)
	local eid = estate.permission_id
	local estatus = estate.status or "pending"
	local e_lines, e_highlights, e_meta = edit_widget.render(estate, widget_support.render_opts())

	if e_lines then
		append_interactive_widget(ctx, {
			kind = "edit",
			id = eid,
			lines = e_lines,
			highlights = e_highlights,
			meta = e_meta,
			status = estatus,
			positions = state.edits,
		})
	end
end

function M.render_widget_items(ctx, index, widget_items, tool_row)
	local function attaches(item)
		return item.kind == "permission" and permission_widget.attaches(item.data, tool_row)
	end
	table.sort(widget_items, function(a, b)
		-- Status lines continue the tool row's panel, so they come first.
		if tool_row and attaches(a) ~= attaches(b) then
			return attaches(a)
		end

		if a.timestamp ~= b.timestamp then
			return a.timestamp < b.timestamp
		end

		local a_order = index.widget_order[a.kind] or 99
		local b_order = index.widget_order[b.kind] or 99
		if a_order ~= b_order then
			return a_order < b_order
		end

		return tostring(a.id or "") < tostring(b.id or "")
	end)

	for _, item in ipairs(widget_items) do
		if item.kind == "question" then
			index:mark_rendered("question", item.id)
			M.render_single_question(ctx, index, item.data)
		elseif item.kind == "permission" then
			index:mark_rendered("permission", item.id)
			if index:should_render_session_widget(item.data.session_id, item.data.status) then
				M.render_single_permission(ctx, index, item.data, tool_row)
			end
		elseif item.kind == "edit" then
			index:mark_rendered("edit", item.id)
			if index:should_render_session_widget(item.data.session_id, item.data.status) then
				M.render_single_edit(ctx, index, item.data)
			end
		end
	end
end

function M.render_session_error_notice(ctx, notice)
	ensure_session_error_highlights()
	local result = { lines = {}, highlights = {} }
	render.add_panel_line(result, notice.content, "OpenCodeSessionError", {
		prefix_hl_group = "OpenCodeSessionErrorBorder",
	})
	local base_line = ctx:add_render_result(result, "non_tool")
	ctx:append_relative_highlights(result.highlights, base_line)
end

function M.render_child_session_widgets_for_task(ctx, index, tool_part)
	local child_session_id = event_util.resolve_task_child_session_id(tool_part)
	if type(child_session_id) ~= "string" or child_session_id == "" then
		return
	end

	M.render_widget_items(ctx, index, index:items_for_child_session(child_session_id))

	for _, notice in ipairs(state.local_notices) do
		if
			notice.kind == "session_error"
			and notice.child_session_id == child_session_id
			and not index:is_local_notice_rendered(notice.id)
		then
			index:mark_local_notice_rendered(notice.id)
			M.render_session_error_notice(ctx, notice)
			ctx:add_raw_line("")
		end
	end
end

function M.render_widgets_for_message(ctx, index, message_id)
	M.render_widget_items(ctx, index, index:items_for_message(message_id))
end

---@param tool_part? table The call's tool part, when its row was rendered just before
function M.render_widgets_for_tool_call(ctx, index, message_id, call_id, tool_part)
	M.render_widget_items(ctx, index, index:items_for_tool_call(message_id, call_id), tool_row_for(tool_part))
end

function M.render_orphan_widgets(ctx, index, session_msg_ids)
	local groups = index:orphan_groups(session_msg_ids)
	for _, qstate in ipairs(groups.questions) do
		index:mark_rendered("question", qstate.request_id)
		M.render_single_question(ctx, index, qstate)
	end
	for _, pstate in ipairs(groups.permissions) do
		index:mark_rendered("permission", pstate.permission_id)
		M.render_single_permission(ctx, index, pstate)
	end
	for _, estate in ipairs(groups.edits) do
		index:mark_rendered("edit", estate.permission_id)
		M.render_single_edit(ctx, index, estate)
	end
end

return M

end)
