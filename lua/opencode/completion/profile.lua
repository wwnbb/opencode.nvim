-- Stateless feature model configuration. Nothing here changes the chat model.
local M = {}

local private_prefixes = {
	completion = "__opencode_nvim_completion_",
	explanation = "__opencode_nvim_explanation_",
}

local function feature_name(kind)
	kind = kind or "completion"
	if not private_prefixes[kind] then return nil, "Unknown model profile: " .. tostring(kind) end
	return kind
end

local function is_object(value)
	if type(value) ~= "table" then return false end
	for key in pairs(value) do
		if type(key) ~= "string" then return false end
	end
	return true
end

-- JSONC accepts comments and trailing commas, but those sequences inside a
-- quoted string (URLs, regexes, prompt text) must remain untouched.
local function strip_jsonc(input)
	local out, index, quoted = {}, 1, false
	while index <= #input do
		local char, next_char = input:sub(index, index), input:sub(index + 1, index + 1)
		if quoted then
			out[#out + 1] = char
			if char == "\\" then
				out[#out + 1] = next_char
				index = index + 1
			elseif char == '"' then
				quoted = false
			end
		elseif char == '"' then
			quoted = true
			out[#out + 1] = char
		elseif char == "/" and next_char == "/" then
			index = input:find("[\r\n]", index + 2) or (#input + 1)
			out[#out + 1] = "\n"
		elseif char == "/" and next_char == "*" then
			local last = input:find("*/", index + 2, true)
			if not last then error("Unterminated JSONC comment") end
			index = last + 1
			out[#out + 1] = " "
		else
			out[#out + 1] = char
		end
		index = index + 1
	end
	local uncommented = table.concat(out)
	out, index, quoted = {}, 1, false
	while index <= #uncommented do
		local char = uncommented:sub(index, index)
		if quoted then
			out[#out + 1] = char
			if char == "\\" then
				out[#out + 1] = uncommented:sub(index + 1, index + 1)
				index = index + 1
			elseif char == '"' then quoted = false end
		elseif char == '"' then
			quoted = true
			out[#out + 1] = char
		elseif char ~= "," or not uncommented:sub(index + 1):match("^%s*[%]}]") then
			out[#out + 1] = char
		end
		index = index + 1
	end
	return table.concat(out)
end

-- Stable serialization makes equivalent option maps share a fingerprint.
-- It also rejects functions, cycles and non-finite numbers before startup.
local function canonical(value, seen)
	if value == vim.NIL then return "null" end
	local kind = type(value)
	if kind == "string" or kind == "boolean" then return vim.json.encode(value) end
	if kind == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return vim.json.encode(value)
	end
	if kind ~= "table" then error("Expected JSON value") end
	seen = seen or {}
	if seen[value] then error("Circular option value") end
	seen[value] = true
	local values = {}
	if vim.islist(value) then
		for _, item in ipairs(value) do values[#values + 1] = canonical(item, seen) end
		seen[value] = nil
		return "[" .. table.concat(values, ",") .. "]"
	end
	if not is_object(value) then error("Expected JSON object or array") end
	for _, key in ipairs(vim.fn.sort(vim.tbl_keys(value))) do
		values[#values + 1] = vim.json.encode(key) .. ":" .. canonical(value[key], seen)
	end
	seen[value] = nil
	return "{" .. table.concat(values, ",") .. "}"
end

local function nonempty(value)
	return type(value) == "string" and value:match("%S") ~= nil
end

---Validate configuration without requiring a running server.
---@return table|nil model Native model selector {providerID,id,variant?}
---@return string|nil error
function M.validate(config, runtime, kind)
	kind = kind or "completion"
	if not private_prefixes[kind] then return nil, "Unknown model profile: " .. tostring(kind) end
	config = config or {}
	local model = config.model
	if type(model) ~= "table" or not nonempty(model.providerID) or not nonempty(model.modelID or model.id) then
		return nil, "Configure " .. kind .. ".model = { providerID = '...', modelID = '...' } before requesting " .. kind
	end
	if config.variant ~= nil and not nonempty(config.variant) then
		return nil, kind .. ".variant must be a non-empty variant name"
	end
	if config.options ~= nil and config.variant ~= nil then
		return nil, "Use either " .. kind .. ".variant or " .. kind .. ".options, not both"
	end
	if config.options ~= nil then
		if runtime and runtime.managed == false then
			return nil, kind .. ".options requires a managed server; configure a variant on the external server and set " .. kind .. ".variant"
		end
		if not is_object(config.options) then return nil, kind .. ".options must contain settings, body, or headers objects" end
		for key, value in pairs(config.options) do
			if (key ~= "settings" and key ~= "body" and key ~= "headers") or not is_object(value) then
				return nil, kind .. ".options only accepts settings, body, and headers objects"
			end
			if key == "headers" then
				for _, header in pairs(value) do
					if type(header) ~= "string" then return nil, kind .. ".options.headers values must be strings" end
				end
			end
		end
		if not pcall(canonical, config.options) then return nil, kind .. ".options must contain JSON-serializable values" end
	end
	return { providerID = model.providerID, id = model.modelID or model.id, variant = config.variant }
end

local function fingerprint(config, model)
	local options = vim.empty_dict()
	for key, value in pairs(config.options) do
		options[key] = next(value) and value or vim.empty_dict()
	end
	return vim.fn.sha256(canonical({ providerID = model.providerID, id = model.id, options = options }))
end

local function ensure_object(parent, key)
	if parent[key] == nil then parent[key] = vim.empty_dict() end
	if not is_object(parent[key]) or vim.islist(parent[key]) then error("Expected configuration object") end
	return parent[key]
end

---Create a process-only V2 overlay, preserving unrelated config and variants.
---An invalid feature profile leaves the original environment untouched.
---@return string|nil overlay
---@return table|nil snapshot
---@return string|nil error
function M.prepare(config, existing, kind)
	local feature, kind_err = feature_name(kind)
	if not feature then return existing, nil, kind_err end
	if not config or not config.enabled or config.options == nil then return existing end
	local model, err = M.validate(config, { managed = true }, feature)
	if not model then return existing, nil, err end
	local ok, overlay, snapshot = pcall(function()
		local document = vim.empty_dict()
		if existing and existing:match("%S") then document = vim.json.decode(strip_jsonc(existing)) end
		if not is_object(document) or vim.islist(document) then error("Expected configuration object") end
		local providers = ensure_object(document, "providers")
		local provider = ensure_object(providers, model.providerID)
		local models = ensure_object(provider, "models")
		local configured_model = ensure_object(models, model.id)
		local variants = configured_model.variants or {}
		if not vim.islist(variants) then error("Expected variants array") end
		local digest = fingerprint(config, model)
		local prefix = private_prefixes[feature]
		local name, used = prefix .. digest, {}
		for _, variant in ipairs(variants) do
			if type(variant) ~= "table" or type(variant.id) ~= "string" then error("Invalid configured variant") end
			used[variant.id] = true
		end
		local suffix = 0
		while used[name] do
			suffix = suffix + 1
			name = prefix .. digest .. "_" .. suffix
		end
		local variant = { id = name }
		for key, value in pairs(config.options) do
			variant[key] = next(value) and vim.deepcopy(value) or vim.empty_dict()
		end
		variants[#variants + 1] = variant
		configured_model.variants = variants
		return vim.json.encode(document), { fingerprint = digest, variant = name }
	end)
	if not ok then
		return existing, nil, "Could not merge " .. feature .. ".options into OPENCODE_CONFIG_CONTENT; check its JSONC and providers/models/variants structure"
	end
	return overlay, snapshot
end

---Resolve against the profile actually installed in the owned process.
function M.resolve(config, runtime, kind)
	local feature, kind_err = feature_name(kind)
	if not feature then return nil, kind_err end
	runtime = runtime or {}
	local model, err = M.validate(config, runtime, feature)
	if not model then return nil, err end
	if config.options == nil then return model end
	if runtime.error then return nil, runtime.error end
	local active = runtime.active
	if not active or active.fingerprint ~= fingerprint(config, model) or not M.is_private_variant(active.variant, feature) then
		return nil, feature:gsub("^%l", string.upper) .. " options changed or are not loaded; restart the OpenCode server to apply " .. feature .. ".options"
	end
	model.variant = active.variant
	return model
end

function M.is_private_variant(name, kind)
	if type(name) ~= "string" then return false end
	if kind ~= nil then
		local prefix = private_prefixes[kind]
		return prefix ~= nil and name:sub(1, #prefix) == prefix
	end
	for _, prefix in pairs(private_prefixes) do
		if name:sub(1, #prefix) == prefix then return true end
	end
	return false
end

return M
