-- Typed form projection owned by question.state; no HTTP or UI dependencies.
local M = {}

local function enabled(field, values)
	for _, rule in ipairs(field.when or {}) do
		local equal = values[rule.key] ~= nil and vim.deep_equal(values[rule.key], rule.value)
		if (rule.op == "eq" and not equal) or (rule.op == "neq" and equal) then return false end
	end
	return true
end
M.enabled = enabled

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
		custom = (field.type == "string" and (not field.options or #field.options == 0 or field.custom == true))
			or field.type == "number" or field.type == "integer" or (field.type == "multiselect" and field.custom == true),
		url = field.url }
end

function M.rebuild(item)
	if item.status == "confirming" then return end
	local current = item.questions[item.current_tab or 1]
	local key = current and current.key
	item.questions, item.selections, item.current_tab = {}, {}, 1
	for _, field in ipairs(item.form.fields) do
		if field.hidden ~= true and enabled(field, item.values) then
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
		local selection = { selected_indices = {}, custom_input = "",
			is_answered = field.required ~= true and field.type ~= "external", ready_to_advance = false }
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

function M.pull(item)
	local errors = {}
	for _, q in ipairs(item.questions) do
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
				if custom == nil then errors[q.key] = "Enter a number" end
			end
			if custom ~= nil then values[#values + 1] = custom end
		end
		if q.field_type == "multiselect" then
			if selection.is_answered then item.values[q.key] = values end
		elseif #values > 0 then item.values[q.key] = values[1]
		elseif selection.custom_present then item.values[q.key] = nil end
	end
	item.parse_errors = errors
end

function M.answer(item)
	M.pull(item)
	local answer = vim.empty_dict()
	for _, field in ipairs(item.form.fields) do
		if field.type ~= "external" and enabled(field, item.values) and item.values[field.key] ~= nil then
			answer[field.key] = vim.deepcopy(item.values[field.key])
		end
	end
	return answer
end

function M.validate(item)
	local answer, errors = M.answer(item), {}
	for _, field in ipairs(item.form.fields) do
		if enabled(field, item.values) then
			local value, err = answer[field.key], item.parse_errors[field.key]
			if not vim.tbl_contains({ "external", "string", "boolean", "integer", "number", "multiselect" }, field.type) then
				err = "Unsupported field type: " .. tostring(field.type)
			elseif field.type == "external" then err = "Waiting for the external step"
			elseif value == nil then
				if field.required then err = err or "Required field" end
			elseif field.type == "number" or field.type == "integer" then
				if type(value) ~= "number" or value ~= value or math.abs(value) == math.huge then err = "Enter a finite number"
				elseif field.type == "integer" and value % 1 ~= 0 then err = "Enter a whole number"
				elseif type(field.minimum) == "number" and value < field.minimum then err = "Minimum: " .. field.minimum
				elseif type(field.maximum) == "number" and value > field.maximum then err = "Maximum: " .. field.maximum end
			elseif field.type == "boolean" then
				if type(value) ~= "boolean" then err = "Choose Yes or No" end
			elseif field.type == "string" then
				local length = type(value) == "string" and vim.str_utfindex(value, "utf-16") or 0
				if type(value) ~= "string" then err = "Enter text"
				elseif field.required and value == "" then err = "Required field"
				elseif field.minLength and length < field.minLength then err = "Minimum length: " .. field.minLength
				elseif field.maxLength and length > field.maxLength then err = "Maximum length: " .. field.maxLength end
			elseif field.type == "multiselect" then
				if type(value) ~= "table" then err = "Select one or more values"
				elseif field.minItems and #value < field.minItems then err = "Select at least " .. field.minItems
				elseif field.maxItems and #value > field.maxItems then err = "Select at most " .. field.maxItems end
			else err = "Unsupported field type: " .. tostring(field.type) end
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
