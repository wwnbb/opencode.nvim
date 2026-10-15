-- Temporary buffer mappings restore the previous owner only while still ours.
local M = {}
local canonical

local function keycode(key)
	return vim.api.nvim_replace_termcodes(key, true, true, true)
end

local function local_mapping(mode, bufnr, key)
	for _, mapping in ipairs(bufnr and vim.api.nvim_buf_get_keymap(bufnr, mode) or vim.api.nvim_get_keymap(mode)) do
		if keycode(mapping.lhs) == key then return mapping end
	end
end

function M.install(mode, bufnr, key, callback, opts)
	local resolved = canonical(key)
	local mapping = { mode = mode, bufnr = bufnr, key = resolved, callback = callback,
		previous = local_mapping(mode, bufnr, resolved) }
	local options = vim.tbl_extend("force", opts or {}, bufnr and { buffer = bufnr } or {})
	vim.keymap.set(mode, key, callback, options)
	mapping.installed = local_mapping(mode, bufnr, resolved)
	return mapping
end

function M.restore(mapping)
	if not mapping or (mapping.bufnr and not vim.api.nvim_buf_is_valid(mapping.bufnr)) then return end
	local current = local_mapping(mapping.mode, mapping.bufnr, mapping.key)
	if not current or not vim.deep_equal(current, mapping.installed) then return end
	vim.keymap.del(mapping.mode, current.lhs, mapping.bufnr and { buffer = mapping.bufnr } or {})
	if mapping.previous then
		local function restore() vim.fn.mapset(mapping.mode, false, mapping.previous) end
		if mapping.bufnr then vim.api.nvim_buf_call(mapping.bufnr, restore) else restore() end
	end
end

local defaults = require("opencode.keymap_defaults")
local effective_hints = {}
local installed_buffers = {}
vim.api.nvim_create_autocmd("BufWipeout", {
	group = vim.api.nvim_create_augroup("OpenCodeActionKeymaps", { clear = true }),
	callback = function(event) installed_buffers[event.buf] = nil end,
})

function M.keys(value)
	if type(value) == "string" then return value ~= "" and { value } or {} end
	local keys, seen = {}, {}
	for _, key in ipairs(type(value) == "table" and value or {}) do
		local code = canonical(key)
		if not seen[code] then keys[#keys + 1], seen[code] = key, true end
	end
	return keys
end

-- Leader expansion matters when detecting collisions with literal key sequences.
canonical = function(key)
	key = key:gsub("<[Ll][Ee][Aa][Dd][Ee][Rr]>", function() return vim.g.mapleader or "\\" end)
	key = key:gsub("<[Ll][Oo][Cc][Aa][Ll][Ll][Ee][Aa][Dd][Ee][Rr]>", function() return vim.g.maplocalleader or "\\" end)
	return keycode(key)
end

function M.matches(value, key)
	for _, lhs in ipairs(M.keys(value)) do
		if canonical(lhs) == canonical(key) then return true end
	end
	return false
end

local function default_group(scope)
	local parent = defaults.parents[scope]
	return vim.tbl_extend("force", parent and default_group(parent) or {}, defaults[scope] or {})
end

local function resolve(scope, values)
	local config = require("opencode.state").get_config() or {}
	local result, customized = default_group(scope), {}
	local function overlay(group)
		local parent = defaults.parents[group]
		if parent then overlay(parent) end
		local configured = group == "global" and config.keymaps or (config[group] or {}).keymaps
		local original = default_group(group)
		local explicit = (config._keymap_overrides or {})[group] or {}
		for action, value in pairs(configured or {}) do
			if explicit[action] or not vim.deep_equal(value, original[action]) then
				result[action], customized[action] = value, true
			end
		end
	end
	overlay(scope)
	local original = default_group(scope)
	for action, value in pairs(values or {}) do
		customized[action] = (customized[action] and vim.deep_equal(value, result[action]))
			or not vim.deep_equal(value, original[action])
		result[action] = value
	end
	return result, customized
end

M.resolve = resolve
M.code = canonical

function M.get(scope, values)
	local result = resolve(scope, values)
	return result
end

function M.label(scope, action, values)
	local resolved, customized = resolve(scope, values)
	local effective = effective_hints[scope]
	local value = resolved[action]
	if effective and vim.deep_equal(effective.customized, customized)
		and vim.deep_equal(effective.values, resolved) and effective.actions[action] ~= nil then
		value = effective.actions[action]
	end
	local keys = M.keys(value)
	return #keys > 0 and table.concat(keys, " / ") or "(disabled)"
end

function M.number_labels(scope, first, last, values)
	local keys, normal = {}, true
	for index = first, last do
		local value = M.label(scope, "select_" .. index, values)
		normal = normal and value == tostring(index)
		keys[#keys + 1] = value
	end
	return normal and (first .. "-" .. last) or table.concat(keys, " / ")
end

--- Collect a surface's actions before installing them so configured keys win
--- over defaults regardless of declaration order. Two custom actions must not
--- silently replace each other. Each callback receives the actual pressed lhs.
function M.mapper(scope, bufnr, values)
	local definitions = {}
	local function map(mode, action, rhs, opts)
		if rhs == nil then return end
		definitions[#definitions + 1] = { mode = mode, action = action, rhs = rhs, opts = opts or {} }
	end
	local function apply()
		local chosen, order, hints, groups = {}, {}, {}, {}
		for _, definition in ipairs(definitions) do
			local opts = vim.tbl_extend("force", { noremap = true, silent = true }, definition.opts)
			local group = opts.scope or scope
			if not groups[group] then groups[group] = { resolve(group, group == scope and values or nil) } end
			local keys, customized = unpack(groups[group])
			local value = opts.keys
			if value == nil then value = keys[definition.action] end
			local custom = opts.keys ~= nil or customized[definition.action] == true
			local filter, aliases = opts.filter, opts.aliases
			opts.scope, opts.keys, opts.filter, opts.aliases = nil, nil, nil, nil
			hints[group] = hints[group] or { values = keys, customized = customized, actions = {} }
			hints[group].actions[definition.action] = {}
			for _, mode in ipairs(type(definition.mode) == "table" and definition.mode or { definition.mode }) do
				for _, lhs in ipairs(M.keys(value)) do
					if not filter or filter(lhs, mode) then
						local id = mode .. "\0" .. canonical(lhs)
						local previous = chosen[id]
						local name = group .. "." .. definition.action
						if previous and previous.custom and custom and previous.name ~= name then
							error("opencode.nvim: conflicting keymaps " .. previous.name .. " and " .. name
								.. " for " .. lhs .. " in " .. mode .. " mode", 2)
						end
						if not previous then order[#order + 1] = id end
						if not previous or custom or not previous.custom then
							chosen[id] = { mode = mode, key = lhs, rhs = definition.rhs, opts = opts, custom = custom, name = name, group = group, action = definition.action, aliases = aliases }
						end
					end
				end
			end
		end
		local buffer_key = bufnr or 0
		local scopes = installed_buffers[buffer_key] or {}
		for _, previous in ipairs(scopes[scope] or {}) do M.restore(previous) end
		local installed = {}
		for _, id in ipairs(order) do
			local binding = chosen[id]
			local rhs = binding.rhs
			if type(rhs) == "function" then
				local callback = rhs
				rhs = function() return callback(binding.key) end
			end
			installed[#installed + 1] = M.install(binding.mode, bufnr, binding.key, rhs, binding.opts)
			installed[#installed].action, installed[#installed].group = binding.action, binding.group
			installed[#installed].lhs = binding.key
			local hint = hints[binding.group]
			table.insert(hint.actions[binding.action], binding.key)
			for _, action in ipairs(binding.aliases or {}) do
				for _, lhs in ipairs(M.keys(hint.values[action])) do
					if M.matches(lhs, binding.key) then
						hint.actions[action] = hint.actions[action] or {}
						table.insert(hint.actions[action], lhs)
					end
				end
			end
		end
		for group, hint in pairs(hints) do
			local previous = effective_hints[group]
			if previous and vim.deep_equal(previous.customized, hint.customized) and vim.deep_equal(previous.values, hint.values) then
				-- Some surfaces use separate input and content buffers for one scope.
				hint.actions = vim.tbl_extend("force", previous.actions, hint.actions)
			end
			effective_hints[group] = hint
		end
		scopes[scope] = installed
		installed_buffers[buffer_key] = scopes
		return installed
	end
	return map, apply
end

return M
