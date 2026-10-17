local cs = require("opencode.ui.chat.state")
return cs.factory("widget_index", function(view)
local M = {}

local question_state = require("opencode.question.state")
local permission_state = require("opencode.permission.state")
local edit_state = require("opencode.edit.state")
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))

local Index = {}
Index.__index = Index

local WIDGET_ORDER = {
	question = 1,
	permission = 2,
	edit = 3,
}

local WIDGETS = {
	{ kind = "question", group = "questions", id = "request_id", rendered = "rendered_question_ids", store = question_state },
	{ kind = "permission", group = "permissions", id = "permission_id", rendered = "rendered_perm_ids", store = permission_state },
	{ kind = "edit", group = "edits", id = "permission_id", rendered = "rendered_edit_ids", store = edit_state },
}
local WIDGET_BY_KIND = {}
for _, spec in ipairs(WIDGETS) do WIDGET_BY_KIND[spec.kind] = spec end

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
		rendered_local_notice_ids = {},
		widget_order = WIDGET_ORDER,
	}, Index)

	for _, spec in ipairs(WIDGETS) do
		local group = spec.group
		local all = spec.store.get_all()
		self["all_" .. group] = all
		self[group .. "_by_message"], self[group .. "_by_call"], self[group .. "_by_session"] = {}, {}, {}
		self[spec.rendered] = {}
		for _, item in ipairs(all) do
			add_to_map(self[group .. "_by_message"], item.message_id, item)
			add_to_map(self[group .. "_by_call"], item.call_id, item)
			add_to_map(self[group .. "_by_session"], item.session_id, item)
		end
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

function Index:has_pending_interaction()
	for _, qstate in ipairs(self.all_questions) do
		if
			(qstate.status == "pending" or qstate.status == "confirming")
			and self:should_render_session_widget(qstate.session_id, qstate.status)
		then
			return true
		end
	end
	for _, pstate in ipairs(self.all_permissions) do
		if
			(pstate.status == nil or pstate.status == "pending")
			and self:should_render_session_widget(pstate.session_id, pstate.status)
		then
			return true
		end
	end
	for _, estate in ipairs(self.all_edits) do
		if
			(estate.status == nil or estate.status == "pending")
			and self:should_render_session_widget(estate.session_id, estate.status)
		then
			return true
		end
	end
	return false
end

function Index:is_rendered(kind, id)
	local spec = WIDGET_BY_KIND[kind]
	return spec ~= nil and self[spec.rendered][id] == true
end

function Index:mark_rendered(kind, id)
	local spec = WIDGET_BY_KIND[kind]
	if spec and id then self[spec.rendered][id] = true end
end

function Index:mark_local_notice_rendered(id)
	if id then
		self.rendered_local_notice_ids[id] = true
	end
end

function Index:is_local_notice_rendered(id)
	return id and self.rendered_local_notice_ids[id] == true
end

local function collect(self, items, spec, records, predicate)
	for _, data in ipairs(records or {}) do
		local id = data[spec.id]
		if not self[spec.rendered][id] and (not predicate or predicate(data)) then
			table.insert(items, widget_item(spec.kind, id, data.timestamp, data))
		end
	end
end

function Index:items_for_message(message_id)
	local items = {}
	for _, spec in ipairs(WIDGETS) do
		collect(self, items, spec, self[spec.group .. "_by_message"][message_id], function(data)
			return spec.kind == "question" or not data.call_id
		end)
	end
	return items
end

local function has_widget_for_tool_call(self, kind, message_id, call_id)
	if type(call_id) ~= "string" or call_id == "" then return false end
	local group = WIDGET_BY_KIND[kind].group
	for _, data in ipairs(self[group .. "_by_message"][message_id] or {}) do
		if data.call_id == call_id and self:should_render_session_widget(data.session_id, data.status) then return true end
	end
	for _, data in ipairs(self[group .. "_by_call"][call_id] or {}) do
		if not data.message_id and data.session_id == (self.current_session and self.current_session.id)
			and self:should_render_session_widget(data.session_id, data.status) then return true end
	end
	return false
end

function Index:has_question_widget_for_tool_call(message_id, call_id)
	return has_widget_for_tool_call(self, "question", message_id, call_id)
end

function Index:has_edit_widget_for_tool_call(message_id, call_id)
	return has_widget_for_tool_call(self, "edit", message_id, call_id)
end

function Index:items_for_tool_call(message_id, call_id)
	if type(call_id) ~= "string" or call_id == "" then return {} end
	local items = {}
	for _, spec in ipairs(WIDGETS) do
		collect(self, items, spec, self[spec.group .. "_by_message"][message_id], function(data)
			return data.call_id == call_id
		end)
		collect(self, items, spec, self[spec.group .. "_by_call"][call_id], function(data)
			return not data.message_id and data.session_id == (self.current_session and self.current_session.id)
		end)
	end
	return items
end

function Index:items_for_child_session(child_session_id)
	local items = {}
	for _, spec in ipairs(WIDGETS) do
		collect(self, items, spec, self[spec.group .. "_by_session"][child_session_id], function(data)
			return data[spec.id] and self:should_render_session_widget(data.session_id, data.status)
		end)
	end
	return items
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
			and (qstate.status == "pending" or qstate.status == "confirming")
			and self:should_render_session_widget(qstate.session_id, qstate.status)
		then
			table.insert(groups.questions, qstate)
		end
	end
	for _, pstate in ipairs(self.all_permissions) do
		if
			not self.rendered_perm_ids[pstate.permission_id]
			and not (pstate.message_id and session_msg_ids[pstate.message_id])
			and (pstate.status == nil or pstate.status == "pending")
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

end)
