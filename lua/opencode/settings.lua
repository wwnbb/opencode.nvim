-- Local preferences. One file owner holds global and directory scopes.
local M = {}
local state = require("opencode.state")

local definitions = {
	{ id = "thinking", title = "Thinking", path = { "session", "thinking" }, values = { "hide", "show" }, default = "hide" },
	{ id = "grouping", title = "Tool grouping", path = { "session", "grouping" }, values = { "none", "auto" }, default = "auto" },
	{ id = "verbosity", title = "Verbosity", path = { "session", "verbosity" }, values = { "low", "medium", "high" }, default = "medium" },
	{ id = "markdown", title = "Markdown", path = { "session", "markdown" }, values = { "rendered", "source" }, default = "rendered" },
	{ id = "diff_view", title = "Diff view", path = { "chat", "diff_view" }, values = { "auto", "split", "unified" }, default = "auto" },
	{ id = "editor_context", title = "Automatic editor context", path = { "input", "editor_context" }, values = { true, false }, default = true },
	{ id = "completion_model", title = "Completion model", path = { "completion", "model" }, kind = "model" },
	{ id = "completion_variant", title = "Completion reasoning", path = { "completion", "variant" }, kind = "variant" },
	{ id = "completion_max_lines", title = "Completion max lines", path = { "completion", "max_lines" }, kind = "integer", default = 12 },
	{ id = "explanation_model", title = "Explain model", path = { "explanation", "model" }, kind = "model" },
	{ id = "explanation_variant", title = "Explain reasoning", path = { "explanation", "variant" }, kind = "variant" },
}
local by_id = {}
for _, definition in ipairs(definitions) do by_id[definition.id] = definition end
local owner, owner_path, baseline

local function directory(value)
	value = value or vim.fn.getcwd()
	local normalized = vim.fs.normalize((vim.uv or vim.loop).fs_realpath(value) or vim.fn.fnamemodify(value, ":p"))
	return normalized == "/" and normalized or normalized:gsub("/$", "")
end

local function valid(definition, value)
	if not definition then return false end
	if definition.kind == "model" then
		return type(value) == "table" and type(value.providerID) == "string" and value.providerID:match("%S") ~= nil
			and type(value.modelID or value.id) == "string" and (value.modelID or value.id):match("%S") ~= nil
	elseif definition.kind == "variant" then
		return value == false or (type(value) == "string" and value:match("%S") ~= nil)
	elseif definition.kind == "integer" then
		return type(value) == "number" and value >= 1 and value < math.huge and value % 1 == 0
	end
	return vim.tbl_contains(definition.values, value)
end

local function saved()
	local values = owner and owner.data.settings or {}
	return type(values) == "table" and values or {}
end

local function scope_values(scope, cwd)
	local values = saved()
	if scope == "global" then return type(values.global) == "table" and values.global or {} end
	local directories = type(values.directories) == "table" and values.directories or {}
	return type(directories[cwd]) == "table" and directories[cwd] or {}
end

local function value_at(config, definition)
	config = config or {}
	local section = type(config[definition.path[1]]) == "table" and config[definition.path[1]] or {}
	local value = section[definition.path[2]]
	if valid(definition, value) then return value end
	return definition.default
end

local function effective(config, cwd)
	local next_config = vim.deepcopy(config or {})
	local global, local_values = scope_values("global"), scope_values("cwd", cwd)
	for _, feature in ipairs({ "completion", "explanation" }) do
		next_config[feature] = type(next_config[feature]) == "table" and next_config[feature] or {}
		next_config[feature].options = vim.deepcopy((baseline and baseline[feature] or {}).options)
	end
	for _, definition in ipairs(definitions) do
		local value = value_at(baseline, definition)
		local overridden = false
		if valid(definition, global[definition.id]) then value, overridden = global[definition.id], true end
		if valid(definition, local_values[definition.id]) then value, overridden = local_values[definition.id], true end
		local section = definition.path[1]
		next_config[section] = type(next_config[section]) == "table" and next_config[section] or {}
		if overridden and (definition.kind == "model" or definition.kind == "variant") then
			next_config[section].options = nil
		end
		if definition.kind == "variant" and value == false then value = nil end
		next_config[section][definition.path[2]] = value
	end
	return next_config
end

function M.setup(config)
	config = config or {}
	baseline = vim.deepcopy(config)
	local path = (config.settings or {}).file or vim.fn.stdpath("data") .. "/opencode_settings.json"
	path = vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
	if not owner or owner_path ~= path then
		owner, owner_path = require("opencode.preferences").open(path), path
	end
	local group = vim.api.nvim_create_augroup("OpenCodeSettings", { clear = true })
	vim.api.nvim_create_autocmd("DirChanged", { group = group, callback = function()
		local current = state.get_config()
		local next_config = effective(current, directory())
		if not vim.deep_equal(current, next_config) then state.set_config(next_config) end
	end })
	return effective(config, directory())
end

function M.list(cwd)
	cwd = directory(cwd)
	local config, result = state.get_config(), {}
	if cwd ~= directory() then config = effective(config, cwd) end
	local global, local_values = scope_values("global"), scope_values("cwd", cwd)
	for _, definition in ipairs(definitions) do
		local item = vim.deepcopy(definition)
		item.value = value_at(config, definition)
		item.scope = valid(definition, local_values[item.id]) and "cwd"
			or (valid(definition, global[item.id]) and "global" or "config")
		if definition.kind == "variant" then
			item.model = vim.deepcopy((config[definition.path[1]] or {}).model)
			item.custom_options = (config[definition.path[1]] or {}).options ~= nil
		end
		result[#result + 1] = item
	end
	return result
end

-- Save before applying so a failed write never masquerades as persistence.
function M.apply(id, value, scope, cwd)
	local definition = by_id[id]
	if not definition or (value ~= nil and not valid(definition, value)) then return false, "Unknown setting or value" end
	if scope ~= "global" and scope ~= "cwd" then return false, "Choose global or cwd scope" end
	if not owner then M.setup(state.get_config()) end
	cwd = directory(cwd)
	if scope == "global" and definition.kind == "variant" and type(value) == "string" then
		local model_definition = by_id[definition.path[1] .. "_model"]
		local local_model = scope_values("cwd", cwd)[model_definition.id]
		local global_model = scope_values("global")[model_definition.id]
		if not valid(model_definition, global_model) then global_model = value_at(baseline, model_definition) end
		if valid(model_definition, local_model) and (not global_model or local_model.providerID ~= global_model.providerID
			or (local_model.modelID or local_model.id) ~= (global_model.modelID or global_model.id)) then
			return false, "This directory uses a different model; save reasoning for this directory or change the global model first"
		end
	end
	local values = vim.deepcopy(saved())
	local target
	if scope == "global" then
		values.global = type(values.global) == "table" and values.global or {}
		target = values.global
	else
		values.directories = type(values.directories) == "table" and values.directories or {}
		values.directories[cwd] = type(values.directories[cwd]) == "table" and values.directories[cwd] or {}
		target = values.directories[cwd]
	end
	target[id] = vim.deepcopy(value)
	if definition.kind == "model" then
		-- A model's variants and provider options do not carry over to another model.
		local variant_id = definition.path[1] .. "_variant"
		target[variant_id] = nil
		if value ~= nil then target[variant_id] = false end
		if scope == "global" and type(values.directories) == "table" then
			for _, overrides in pairs(values.directories) do
				if type(overrides) == "table" and not valid(definition, overrides[id]) then overrides[variant_id] = nil end
			end
		end
	end
	if not owner.save({ settings = values }) then return false, "Could not save preferences; original file preserved" end
	state.set_config(effective(state.get_config(), directory()))
	return true
end

return M
