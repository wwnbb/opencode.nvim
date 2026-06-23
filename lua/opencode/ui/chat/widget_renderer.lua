local M = {}

local state = require("opencode.ui.chat.state").state
local render = require("opencode.ui.chat.render")
local panel = require("opencode.ui.panel")
local event_util = require("opencode.events.util")
local question_widget = require("opencode.ui.question_widget")
local permission_widget = require("opencode.ui.permission_widget")
local edit_widget = require("opencode.ui.edit_widget")
local widget_base = require("opencode.ui.widget_base")
local widget_support = require("opencode.ui.chat.widget_support")

local function ensure_session_error_highlights()
	panel.set_hl("OpenCodeSessionError", "DiagnosticError", "ErrorMsg")
	panel.set_hl("OpenCodeSessionErrorBorder", "DiagnosticError", "ErrorMsg")
end

local function capture_widget_focus(kind, widget_id, widget_start, meta)
	local focus_offset = widget_base.get_focus_offset(meta)
	if focus_offset == nil then
		return
	end
	widget_support.capture_focus_line(kind, widget_id, widget_start + focus_offset + 1)
end

function M.render_single_question(ctx, index, qstate)
	if not qstate then
		return
	end
	local request_id = qstate.request_id
	local q_lines, q_highlights, q_meta
	local status = qstate.status or "pending"

	if not index:should_render_session_widget(qstate.session_id, status) then
		return
	end

	if status == "answered" then
		q_lines, q_highlights = question_widget.get_answered_lines(
			request_id,
			{ questions = qstate.questions, timestamp = qstate.timestamp },
			qstate.answers
		)
		q_meta = widget_base.make_meta()
	elseif status == "rejected" then
		q_lines, q_highlights = question_widget.get_rejected_lines(request_id, {
			questions = qstate.questions,
			timestamp = qstate.timestamp,
		})
		q_meta = widget_base.make_meta()
	else
		q_lines, q_highlights, q_meta =
			question_widget.get_lines_for_question(request_id, { questions = qstate.questions }, qstate, status)
	end

	local q_start_line = ctx:prepare_widget_start()
	capture_widget_focus("question", request_id, q_start_line, q_meta)
	for _, line_text in ipairs(q_lines) do
		ctx:add_raw_line(line_text)
	end

	state.questions[request_id] = {
		start_line = q_start_line,
		end_line = q_start_line + #q_lines - 1,
		status = status,
		highlights = q_highlights,
	}
	ctx:add_raw_line("")
end

function M.render_single_permission(ctx, _index, pstate)
	local perm_id = pstate.permission_id
	local pstatus = pstate.status or "pending"
	local p_lines, p_highlights, p_meta

	if pstatus == "approved" then
		p_lines, p_highlights = permission_widget.get_approved_lines(perm_id, pstate)
		p_meta = widget_base.make_meta()
	elseif pstatus == "rejected" then
		p_lines, p_highlights = permission_widget.get_rejected_lines(perm_id, pstate)
		p_meta = widget_base.make_meta()
	else
		p_lines, p_highlights, p_meta = permission_widget.get_lines_for_permission(perm_id, pstate)
	end

	if p_lines then
		local perm_start = ctx:prepare_widget_start()
		capture_widget_focus("permission", perm_id, perm_start, p_meta)
		for _, line_text in ipairs(p_lines) do
			ctx:add_raw_line(line_text)
		end
		state.permissions[perm_id] = {
			start_line = perm_start,
			end_line = perm_start + #p_lines - 1,
			status = pstatus,
			highlights = p_highlights,
		}
		ctx:add_raw_line("")
	end
end

function M.render_single_edit(ctx, _index, estate)
	local eid = estate.permission_id
	local estatus = estate.status or "pending"
	local e_lines, e_highlights, e_meta

	if estatus == "sent" then
		e_lines, e_highlights, e_meta = edit_widget.get_resolved_lines(eid, estate)
		e_meta = e_meta or widget_base.make_meta()
	else
		e_lines, e_highlights, e_meta = edit_widget.get_lines_for_edit(eid, estate)
	end

	if e_lines then
		local edit_start = ctx:prepare_widget_start()
		capture_widget_focus("edit", eid, edit_start, e_meta)
		for _, line_text in ipairs(e_lines) do
			ctx:add_raw_line(line_text)
		end
		state.edits[eid] = {
			start_line = edit_start,
			end_line = edit_start + #e_lines - 1,
			status = estatus,
			highlights = e_highlights,
			meta = e_meta,
		}
		ctx:add_raw_line("")
	end
end

function M.render_widget_items(ctx, index, widget_items)
	table.sort(widget_items, function(a, b)
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
				M.render_single_permission(ctx, index, item.data)
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

function M.render_widgets_for_tool_call(ctx, index, message_id, call_id)
	M.render_widget_items(ctx, index, index:items_for_tool_call(message_id, call_id))
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
