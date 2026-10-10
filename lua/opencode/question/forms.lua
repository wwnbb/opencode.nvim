-- Typed form projection owned by question.state; no HTTP or UI dependencies.
local M = {}
local validation = require("opencode.question.form_validation")

local function enabled(field, values)
	for _, rule in ipairs(field.when or {}) do
		local value = values[rule.key]
		if value == nil then return false end
		local equal = false
		if type(value) == "table" then
			for _, entry in ipairs(value) do
				if vim.deep_equal(entry, rule.value) then equal = true; break end
			end
		else
			equal = vim.deep_equal(value, rule.value)
		end
		if (rule.op == "eq" and not equal) or (rule.op == "neq" and equal) then return false end
	end
	return true
end
M.enabled = enabled

-- Conditions only see earlier fields that are themselves active. A hidden
-- field can still supply its default; an inactive field cannot supply an
-- answer or activate a later dependent field.
local function project(item, fields_only)
	local answer, active, preceding = not fields_only and vim.empty_dict() or nil, {}, {}
	for _, field in ipairs(item.form.fields) do
		if field.type == "external" or enabled(field, preceding) then
			active[field.key] = true
			local value = item.values[field.key]
			if value ~= nil then
				if answer then answer[field.key] = vim.deepcopy(value) end
				preceding[field.key] = value
			end
		end
	end
	return answer, active
end

local function options(field)
	if field.type == "boolean" then return { { label = "Yes", value = true }, { label = "No", value = false } } end
	local result = vim.deepcopy(field.options or {})
	if field.type == "multiselect" and field.custom == true then
		for _, value in ipairs(field.default or {}) do
			local present = false
			for _, option in ipairs(result) do if vim.deep_equal(option.value, value) then present = true; break end end
			if not present then result[#result + 1] = { label = tostring(value), value = value } end
		end
	end
	return result
end

local function question(field)
	return { key = field.key, field_type = field.type, header = field.title or field.key,
		question = field.description or field.title or field.key, options = options(field),
		multiple = field.type == "multiselect", required = field.required == true,
		custom = (field.type == "string" and (not field.options or field.custom == true))
			or field.type == "number" or field.type == "integer" or (field.type == "multiselect" and field.custom == true),
		url = field.url }
end

function M.rebuild(item)
	if item.status == "confirming" then return end
	local current = item.questions[item.current_tab or 1]
	local key = current and current.key
	item.questions, item.selections, item.current_tab = {}, {}, 1
	local _, active = project(item, true)
	for _, field in ipairs(item.form.fields) do
		if field.hidden ~= true and active[field.key] then
			local index = #item.questions + 1
			item.questions[index] = question(field)
			item.selections[index] = item.form_selections[field.key]
			if field.key == key then item.current_tab = index end
		end
	end
end

function M.init(item, form, context)
	item.form = vim.deepcopy(form)
	item.location = context and vim.deepcopy(context.location)
	item.values, item.form_selections, item.field_errors = {}, {}, {}
	for _, field in ipairs(form.fields) do
		local value = field.default
		local selection = { selected_indices = {}, custom_input = "", external_ready = false,
			is_answered = field.required ~= true and field.type ~= "external" and field.type ~= "multiselect" }
		if value ~= nil then
			item.values[field.key], selection.is_answered = vim.deepcopy(value), true
			local values = field.type == "multiselect" and value or { value }
			local choices = options(field)
			for _, entry in ipairs(values) do
				local found = false
				for i, option in ipairs(choices) do
					if vim.deep_equal(entry, option.value) then selection.selected_indices[#selection.selected_indices + 1], found = i, true; break end
				end
				if not found then selection.custom_input, selection.custom_present = tostring(entry), true end
			end
		end
		item.form_selections[field.key] = selection
	end
	M.rebuild(item)
end

local function external_selection(item, key)
	local selection = item.form_selections and item.form_selections[key]
	if not selection then return nil end
	for _, field in ipairs(item.form.fields) do
		if field.key == key and field.type == "external" then return selection end
	end
end

function M.mark_external_ready(item, key)
	local selection = external_selection(item, key)
	if not selection then return false end
	selection.external_ready = true
	return true
end

function M.acknowledge_external(item, key)
	local selection = external_selection(item, key)
	if not selection or not selection.external_ready then return false end
	item.values[key] = true
	selection.is_answered = true
	item.server_error = nil
	return true
end

function M.set_custom_input(item, tab_index, text)
	local field, selection = item.questions[tab_index], item.selections[tab_index]
	if not field or not selection or field.field_type == "external" then return false end
	selection.custom_input = text
	selection.custom_present = not field.multiple or (text ~= nil and text ~= "")
	selection.touched = true
	if field.multiple then
		selection.is_answered = #selection.selected_indices > 0 or selection.custom_present
	else
		selection.selected_indices = {}
		selection.is_answered = not field.required or (text ~= nil and text ~= "")
	end
	return true
end

function M.pull(item)
	local errors = {}
	for _, q in ipairs(item.questions) do
		if q.field_type ~= "external" then
			local selection = item.form_selections[q.key]
			local values = {}
			for _, index in ipairs(selection.selected_indices) do
				local option = q.options[index]
				if option then values[#values + 1] = option.value end
			end
			if selection.custom_present then
				local custom = selection.custom_input
				if q.field_type == "number" or q.field_type == "integer" then
					custom = tonumber(custom)
					if custom == nil then errors[q.key] = "Expected a number" end
				end
				local add_custom = custom ~= nil
				if q.field_type == "multiselect" then
					add_custom = add_custom and custom ~= "" and not vim.tbl_contains(values, custom)
				end
				if add_custom then values[#values + 1] = custom end
			end
			if q.field_type == "multiselect" then
				item.values[q.key] = selection.is_answered and values or nil
			elseif #values > 0 then
				local value = values[1]
				if q.field_type == "string" and not q.required and selection.touched and value == "" then
					item.values[q.key] = nil
				else
					item.values[q.key] = value
				end
			elseif selection.custom_present then item.values[q.key] = nil end
		end
	end
	item.parse_errors = errors
end

function M.answer(item)
	M.pull(item)
	local answer = project(item)
	return answer
end

function M.validate(item)
	M.pull(item)
	local answer, active = project(item)
	local errors = {}
	for _, field in ipairs(item.form.fields) do
		if active[field.key] then
			local err = item.parse_errors[field.key] or validation.validate(field, answer[field.key])
			if err then errors[field.key] = err end
		end
	end
	item.field_errors = errors
	return next(errors) == nil, errors
end

function M.display_answers(item, answer)
	local result = {}
	for _, q in ipairs(item.questions) do
		local value = answer[q.key]
		if q.field_type == "external" then value = value == true and "Acknowledged" or nil end
		local values = type(value) == "table" and value or (value ~= nil and { value } or {})
		local labels = {}
		for _, entry in ipairs(values) do
			local label = tostring(entry)
			for _, option in ipairs(q.options) do
				if vim.deep_equal(option.value, entry) then label = option.label; break end
			end
			labels[#labels + 1] = label
		end
		result[#result + 1] = labels
	end
	return result
end

return M
