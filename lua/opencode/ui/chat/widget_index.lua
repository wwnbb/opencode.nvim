local M = {}

local question_state = require("opencode.question.state")
local permission_state = require("opencode.permission.state")
local edit_state = require("opencode.edit.state")
local widget_support = require("opencode.ui.chat.widget_support")

local Index = {}
Index.__index = Index

local WIDGET_ORDER = {
	question = 1,
	permission = 2,
	edit = 3,
}

local function add_to_map(map, key, value)
	if not key then
		return
	end
	map[key] = map[key] or {}
	table.insert(map[key], value)
end

local function widget_item(kind, id, timestamp, data)
	return {
		kind = kind,
		id = id,
		timestamp = timestamp or 0,
		data = data,
	}
end

function M.new(opts)
	opts = opts or {}
	local self = setmetatable({
		current_session = opts.current_session or {},
		in_child_session_view = opts.in_child_session_view == true,
		all_questions = question_state.get_all(),
		all_permissions = permission_state.get_all(),
		all_edits = edit_state.get_all(),
		questions_by_message = {},
		permissions_by_message = {},
		edits_by_message = {},
		questions_by_call = {},
		permissions_by_call = {},
		edits_by_call = {},
		questions_by_session = {},
		permissions_by_session = {},
		edits_by_session = {},
		rendered_question_ids = {},
		rendered_perm_ids = {},
		rendered_edit_ids = {},
		rendered_local_notice_ids = {},
		widget_order = WIDGET_ORDER,
	}, Index)

	for _, qstate in ipairs(self.all_questions) do
		add_to_map(self.questions_by_message, qstate.message_id, qstate)
		add_to_map(self.questions_by_call, qstate.call_id, qstate)
		add_to_map(self.questions_by_session, qstate.session_id, qstate)
	end
	for _, pstate in ipairs(self.all_permissions) do
		add_to_map(self.permissions_by_message, pstate.message_id, pstate)
		add_to_map(self.permissions_by_call, pstate.call_id, pstate)
		add_to_map(self.permissions_by_session, pstate.session_id, pstate)
	end
	for _, estate in ipairs(self.all_edits) do
		add_to_map(self.edits_by_message, estate.message_id, estate)
		add_to_map(self.edits_by_call, estate.call_id, estate)
		add_to_map(self.edits_by_session, estate.session_id, estate)
	end

	return self
end

function Index:should_render_session_widget(owner_session_id, widget_status)
	return widget_support.should_render(
		owner_session_id,
		widget_status,
		self.current_session and self.current_session.id,
		self.in_child_session_view
	)
end

function Index:is_rendered(kind, id)
	if kind == "question" then
		return self.rendered_question_ids[id] == true
	elseif kind == "permission" then
		return self.rendered_perm_ids[id] == true
	elseif kind == "edit" then
		return self.rendered_edit_ids[id] == true
	end
	return false
end

function Index:mark_rendered(kind, id)
	if not id then
		return
	end
	if kind == "question" then
		self.rendered_question_ids[id] = true
	elseif kind == "permission" then
		self.rendered_perm_ids[id] = true
	elseif kind == "edit" then
		self.rendered_edit_ids[id] = true
	end
end

function Index:mark_local_notice_rendered(id)
	if id then
		self.rendered_local_notice_ids[id] = true
	end
end

function Index:is_local_notice_rendered(id)
	return id and self.rendered_local_notice_ids[id] == true
end

function Index:items_for_message(message_id)
	local widget_items = {}

	for _, qstate in ipairs(self.questions_by_message[message_id] or {}) do
		if not self.rendered_question_ids[qstate.request_id] then
			table.insert(widget_items, widget_item("question", qstate.request_id, qstate.timestamp, qstate))
		end
	end
	for _, pstate in ipairs(self.permissions_by_message[message_id] or {}) do
		if not pstate.call_id and not self.rendered_perm_ids[pstate.permission_id] then
			table.insert(widget_items, widget_item("permission", pstate.permission_id, pstate.timestamp, pstate))
		end
	end
	for _, estate in ipairs(self.edits_by_message[message_id] or {}) do
		if not estate.call_id and not self.rendered_edit_ids[estate.permission_id] then
			table.insert(widget_items, widget_item("edit", estate.permission_id, estate.timestamp, estate))
		end
	end

	return widget_items
end

function Index:has_question_widget_for_tool_call(message_id, call_id)
	for _, qstate in ipairs(self.questions_by_message[message_id] or {}) do
		if
			(not qstate.call_id or qstate.call_id == call_id)
			and self:should_render_session_widget(qstate.session_id, qstate.status)
		then
			return true
		end
	end

	if type(call_id) ~= "string" or call_id == "" then
		return false
	end

	for _, qstate in ipairs(self.questions_by_call[call_id] or {}) do
		if
			not qstate.message_id
			and qstate.session_id == (self.current_session and self.current_session.id)
			and self:should_render_session_widget(qstate.session_id, qstate.status)
		then
			return true
		end
	end

	return false
end

function Index:has_edit_widget_for_tool_call(message_id, call_id)
	for _, estate in ipairs(self.edits_by_message[message_id] or {}) do
		if
			(not estate.call_id or estate.call_id == call_id)
			and self:should_render_session_widget(estate.session_id, estate.status)
		then
			return true
		end
	end

	if type(call_id) ~= "string" or call_id == "" then
		return false
	end

	for _, estate in ipairs(self.edits_by_call[call_id] or {}) do
		if
			not estate.message_id
			and estate.session_id == (self.current_session and self.current_session.id)
			and self:should_render_session_widget(estate.session_id, estate.status)
		then
			return true
		end
	end

	return false
end

function Index:items_for_tool_call(message_id, call_id)
	if type(call_id) ~= "string" or call_id == "" then
		return {}
	end

	local widget_items = {}
	for _, qstate in ipairs(self.questions_by_message[message_id] or {}) do
		if qstate.call_id == call_id and not self.rendered_question_ids[qstate.request_id] then
			table.insert(widget_items, widget_item("question", qstate.request_id, qstate.timestamp, qstate))
		end
	end
	for _, qstate in ipairs(self.questions_by_call[call_id] or {}) do
		if
			not qstate.message_id
			and qstate.session_id == (self.current_session and self.current_session.id)
			and not self.rendered_question_ids[qstate.request_id]
		then
			table.insert(widget_items, widget_item("question", qstate.request_id, qstate.timestamp, qstate))
		end
	end

	for _, pstate in ipairs(self.permissions_by_message[message_id] or {}) do
		if pstate.call_id == call_id and not self.rendered_perm_ids[pstate.permission_id] then
			table.insert(widget_items, widget_item("permission", pstate.permission_id, pstate.timestamp, pstate))
		end
	end
	for _, pstate in ipairs(self.permissions_by_call[call_id] or {}) do
		if
			not pstate.message_id
			and pstate.session_id == (self.current_session and self.current_session.id)
			and not self.rendered_perm_ids[pstate.permission_id]
		then
			table.insert(widget_items, widget_item("permission", pstate.permission_id, pstate.timestamp, pstate))
		end
	end

	for _, estate in ipairs(self.edits_by_message[message_id] or {}) do
		if estate.call_id == call_id and not self.rendered_edit_ids[estate.permission_id] then
			table.insert(widget_items, widget_item("edit", estate.permission_id, estate.timestamp, estate))
		end
	end
	for _, estate in ipairs(self.edits_by_call[call_id] or {}) do
		if
			not estate.message_id
			and estate.session_id == (self.current_session and self.current_session.id)
			and not self.rendered_edit_ids[estate.permission_id]
		then
			table.insert(widget_items, widget_item("edit", estate.permission_id, estate.timestamp, estate))
		end
	end

	return widget_items
end

function Index:items_for_child_session(child_session_id)
	local widget_items = {}

	for _, qstate in ipairs(self.questions_by_session[child_session_id] or {}) do
		if
			qstate.request_id
			and not self.rendered_question_ids[qstate.request_id]
			and self:should_render_session_widget(qstate.session_id, qstate.status)
		then
			table.insert(widget_items, widget_item("question", qstate.request_id, qstate.timestamp, qstate))
		end
	end
	for _, pstate in ipairs(self.permissions_by_session[child_session_id] or {}) do
		if
			pstate.permission_id
			and not self.rendered_perm_ids[pstate.permission_id]
			and self:should_render_session_widget(pstate.session_id, pstate.status)
		then
			table.insert(widget_items, widget_item("permission", pstate.permission_id, pstate.timestamp, pstate))
		end
	end
	for _, estate in ipairs(self.edits_by_session[child_session_id] or {}) do
		if
			estate.permission_id
			and not self.rendered_edit_ids[estate.permission_id]
			and self:should_render_session_widget(estate.session_id, estate.status)
		then
			table.insert(widget_items, widget_item("edit", estate.permission_id, estate.timestamp, estate))
		end
	end

	return widget_items
end

function Index:orphan_groups(session_msg_ids)
	local groups = {
		questions = {},
		permissions = {},
		edits = {},
	}

	for _, qstate in ipairs(self.all_questions) do
		if
			not self.rendered_question_ids[qstate.request_id]
			and not (qstate.message_id and session_msg_ids[qstate.message_id])
			and self:should_render_session_widget(qstate.session_id, qstate.status)
		then
			table.insert(groups.questions, qstate)
		end
	end
	for _, pstate in ipairs(self.all_permissions) do
		if
			not self.rendered_perm_ids[pstate.permission_id]
			and not (pstate.message_id and session_msg_ids[pstate.message_id])
			and self:should_render_session_widget(pstate.session_id, pstate.status)
		then
			table.insert(groups.permissions, pstate)
		end
	end
	for _, estate in ipairs(self.all_edits) do
		if
			not self.rendered_edit_ids[estate.permission_id]
			and not (estate.message_id and session_msg_ids[estate.message_id])
			and edit_state.get_resolution(estate.permission_id) == "pending"
			and self:should_render_session_widget(estate.session_id, estate.status)
		then
			table.insert(groups.edits, estate)
		end
	end

	return groups
end

return M
