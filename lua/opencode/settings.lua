-- Local display preferences. One file owner holds global and directory scopes.
local M = {}
local state = require("opencode.state")

local definitions = {
	{ id = "thinking", title = "Thinking", path = { "session", "thinking" }, values = { "hide", "show" }, default = "hide" },
	{ id = "grouping", title = "Tool grouping", path = { "session", "grouping" }, values = { "none", "auto" }, default = "auto" },
	{ id = "verbosity", title = "Verbosity", path = { "session", "verbosity" }, values = { "low", "medium", "high" }, default = "medium" },
	{ id = "markdown", title = "Markdown", path = { "session", "markdown" }, values = { "rendered", "source" }, default = "rendered" },
	{ id = "diff_view", title = "Diff view", path = { "chat", "diff_view" }, values = { "auto", "split", "unified" }, default = "auto" },
	{ id = "editor_context", title = "Automatic editor context", path = { "input", "editor_context" }, values = { true, false }, default = true },
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
	return definition and vim.tbl_contains(definition.values, value)
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
	for _, definition in ipairs(definitions) do
		local value = value_at(baseline, definition)
		if valid(definition, global[definition.id]) then value = global[definition.id] end
		if valid(definition, local_values[definition.id]) then value = local_values[definition.id] end
		local section = definition.path[1]
		next_config[section] = type(next_config[section]) == "table" and next_config[section] or {}
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
	local global, local_values = scope_values("global"), scope_values("cwd", cwd)
	for _, definition in ipairs(definitions) do
		local item = vim.deepcopy(definition)
		item.value = value_at(config, definition)
		item.scope = valid(definition, local_values[item.id]) and "cwd"
			or (valid(definition, global[item.id]) and "global" or "config")
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
	local values = vim.deepcopy(saved())
	if scope == "global" then
		values.global = type(values.global) == "table" and values.global or {}
		values.global[id] = value
	else
		values.directories = type(values.directories) == "table" and values.directories or {}
		values.directories[cwd] = type(values.directories[cwd]) == "table" and values.directories[cwd] or {}
		values.directories[cwd][id] = value
	end
	if not owner.save({ settings = values }) then return false, "Could not save display preferences; original file preserved" end
	state.set_config(effective(state.get_config(), directory()))
	return true
end

return M
