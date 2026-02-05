-- opencode.nvim - Local state module (mirrors TUI's local.tsx)
-- Manages agent/model/variant selection with per-agent model preferences

local M = {}

local sync = require("opencode.sync")

-- Persistent state file path
local state_file = vim.fn.stdpath("data") .. "/opencode_local.json"

-- Internal state (like TUI's modelStore/agentStore)
local state = {
	ready = false,
	-- Current agent name
	agent = nil,
	-- Per-agent model selection: { [agentName] = { providerID, modelID } }
	model = {},
	-- Recent models (most recent first)
	recent = {},
	-- Favorite models
	favorite = {},
	-- Per-model variant selection: { ["providerID/modelID"] = variantName }
	variant = {},
}

-- State change listeners
local listeners = {}

---Emit state change
---@param key string
---@param old_val any
---@param new_val any
local function emit(key, old_val, new_val)
	for _, cb in ipairs(listeners) do
		pcall(cb, key, new_val, old_val)
	end
end

---Load persistent state from file
local function load_state()
	local file = io.open(state_file, "r")
	if file then
		local content = file:read("*all")
		file:close()
		local ok, data = pcall(vim.json.decode, content)
		if ok and type(data) == "table" then
			if type(data.recent) == "table" then
				state.recent = data.recent
			end
			if type(data.favorite) == "table" then
				state.favorite = data.favorite
			end
			if type(data.variant) == "table" then
				state.variant = data.variant
			end
		end
	end
	state.ready = true
end

---Save persistent state to file
local function save_state()
	if not state.ready then
		return
	end
	local dir = vim.fn.fnamemodify(state_file, ":h")
	vim.fn.mkdir(dir, "p")
	local file = io.open(state_file, "w")
	if file then
		local data = {
			recent = state.recent,
			favorite = state.favorite,
			variant = state.variant,
		}
		file:write(vim.json.encode(data))
		file:close()
	end
end

---Check if a model is valid (provider connected and model exists)
---@param model { providerID: string, modelID: string }
---@return boolean
local function is_model_valid(model)
	if not model or not model.providerID or not model.modelID then
		return false
	end
	local provider = sync.get_provider(model.providerID)
	if not provider or not provider.models then
		return false
	end
	return provider.models[model.modelID] ~= nil
end

---Get first valid model from multiple options (like TUI's getFirstValidModel)
---@vararg function Functions that return model or nil
---@return { providerID: string, modelID: string }|nil
local function get_first_valid_model(...)
	for _, fn in ipairs({ ... }) do
		local model = fn()
		if model and is_model_valid(model) then
			return model
		end
	end
	return nil
end

-- Agent module (like TUI's agent in local.tsx)
M.agent = {}

---Get list of available agents (excluding subagents and hidden)
---@return table[]
function M.agent.list()
	return sync.get_visible_agents()
end

---Get current agent
---@return table|nil
function M.agent.current()
	local agents = M.agent.list()
	if #agents == 0 then
		return nil
	end
	-- Find current agent or return first
	if state.agent then
		for _, agent in ipairs(agents) do
			if agent.name == state.agent then
				return agent
			end
		end
	end
	-- Default to first agent
	return agents[1]
end

---Set current agent by name
---@param name string
function M.agent.set(name)
	local agents = M.agent.list()
	-- Validate agent exists
	local found = false
	for _, agent in ipairs(agents) do
		if agent.name == name then
			found = true
			break
		end
	end
	if not found then
		vim.notify("Agent not found: " .. name, vim.log.levels.WARN)
		return
	end
	local old = state.agent
	state.agent = name
	emit("agent", old, name)
end

---Cycle to next/previous agent
---@param direction number 1 for next, -1 for previous
---@param opts? { silent?: boolean }
function M.agent.move(direction, opts)
	opts = opts or {}
	local agents = M.agent.list()
	if #agents == 0 then
		if not opts.silent then
			vim.notify("No agents available", vim.log.levels.WARN)
		end
		return
	end
	local current_idx = 1
	if state.agent then
		for i, agent in ipairs(agents) do
			if agent.name == state.agent then
				current_idx = i
				break
			end
		end
	end
	local next_idx = current_idx + direction
	if next_idx < 1 then
		next_idx = #agents
	elseif next_idx > #agents then
		next_idx = 1
	end
	local old = state.agent
	state.agent = agents[next_idx].name
	emit("agent", old, state.agent)
	-- If agent has a configured model, switch to it
	local agent = agents[next_idx]
	if agent.model and is_model_valid(agent.model) then
		M.model.set(agent.model, { silent = true })
	end
	-- Show feedback
	if not opts.silent then
		vim.notify("Agent: " .. (agent.name or state.agent), vim.log.levels.INFO)
	end
end

-- Model module (like TUI's model in local.tsx)
M.model = {}

---Get fallback model (from config, recent, or first available)
---@return { providerID: string, modelID: string }|nil
local function get_fallback_model()
	-- Check config default
	local config = sync.get_config()
	if config.model then
		-- Parse "providerID/modelID" format
		local provider_id, model_id = config.model:match("^([^/]+)/(.+)$")
		if provider_id and model_id then
			local m = { providerID = provider_id, modelID = model_id }
			if is_model_valid(m) then
				return m
			end
		end
	end

	-- Check recent models
	for _, item in ipairs(state.recent) do
		if is_model_valid(item) then
			return item
		end
	end

	-- Get first connected provider's default or first model
	local providers = sync.get_providers()
	local defaults = sync.get_provider_defaults()
	for _, provider in ipairs(providers) do
		local default_model = defaults[provider.id]
		if default_model then
			local m = { providerID = provider.id, modelID = default_model }
			if is_model_valid(m) then
				return m
			end
		end
		-- Try first model
		if provider.models then
			for model_id, _ in pairs(provider.models) do
				local m = { providerID = provider.id, modelID = model_id }
				if is_model_valid(m) then
					return m
				end
			end
		end
	end

	return nil
end

---Get current model key for the current agent
---@return { providerID: string, modelID: string }|nil
function M.model.current()
	local agent = M.agent.current()
	if not agent then
		return nil
	end
	return get_first_valid_model(
		-- Check per-agent selection
		function()
			return state.model[agent.name]
		end,
		-- Check agent's configured model
		function()
			return agent.model
		end,
		-- Fallback
		get_fallback_model
	)
end

---Get current model info (with name, provider name, etc.)
---@return { providerID: string, modelID: string, name: string, provider: string, reasoning: boolean }|nil
function M.model.parsed()
	local current = M.model.current()
	if not current then
		-- Check if providers are loaded yet
		local providers = sync.get_providers()
		if #providers == 0 then
			-- Providers not loaded yet - show loading state
			return {
				providerID = "",
				modelID = "",
				provider = "Loading...",
				name = "",
				reasoning = false,
			}
		end
		-- Providers loaded but no valid model - user needs to connect a provider
		return {
			providerID = "",
			modelID = "",
			provider = "Connect a provider",
			name = "No provider selected",
			reasoning = false,
		}
	end
	local provider = sync.get_provider(current.providerID)
	local model_info = provider and provider.models and provider.models[current.modelID]
	return {
		providerID = current.providerID,
		modelID = current.modelID,
		provider = provider and provider.name or current.providerID,
		name = model_info and model_info.name or current.modelID,
		reasoning = model_info and model_info.capabilities and model_info.capabilities.reasoning or false,
	}
end

---Get recent models
---@return { providerID: string, modelID: string }[]
function M.model.recent()
	return state.recent
end

---Get favorite models
---@return { providerID: string, modelID: string }[]
function M.model.favorite()
	return state.favorite
end

---Set current model for current agent
---@param model { providerID: string, modelID: string }
---@param opts? { recent?: boolean, silent?: boolean }
function M.model.set(model, opts)
	opts = opts or {}
	if not is_model_valid(model) then
		if not opts.silent then
			vim.notify(
				string.format("Model %s/%s is not valid", model.providerID or "?", model.modelID or "?"),
				vim.log.levels.WARN
			)
		end
		return
	end
	local agent = M.agent.current()
	if agent then
		state.model[agent.name] = { providerID = model.providerID, modelID = model.modelID }
	end
	if opts.recent then
		-- Add to recent, remove duplicates
		local new_recent = { { providerID = model.providerID, modelID = model.modelID } }
		for _, item in ipairs(state.recent) do
			if item.providerID ~= model.providerID or item.modelID ~= model.modelID then
				table.insert(new_recent, item)
			end
			if #new_recent >= 10 then
				break
			end
		end
		state.recent = new_recent
		save_state()
	end
	emit("model", nil, model)
end

---Cycle through recent models
---@param direction number 1 for next, -1 for previous
---@param opts? { silent?: boolean }
function M.model.cycle(direction, opts)
	opts = opts or {}
	local current = M.model.current()
	if not current then
		if not opts.silent then
			vim.notify("No model selected", vim.log.levels.WARN)
		end
		return
	end
	local recent = state.recent
	if #recent == 0 then
		if not opts.silent then
			vim.notify("No recent models", vim.log.levels.INFO)
		end
		return
	end
	-- Find current in recent
	local current_idx = 1
	for i, item in ipairs(recent) do
		if item.providerID == current.providerID and item.modelID == current.modelID then
			current_idx = i
			break
		end
	end
	local next_idx = current_idx + direction
	if next_idx < 1 then
		next_idx = #recent
	elseif next_idx > #recent then
		next_idx = 1
	end
	local next_model = recent[next_idx]
	if next_model then
		M.model.set(next_model, { silent = true })
		-- Show feedback
		if not opts.silent then
			local parsed = M.model.parsed()
			if parsed then
				vim.notify("Model: " .. (parsed.name or next_model.modelID), vim.log.levels.INFO)
			end
		end
	end
end

---Toggle favorite status for a model
---@param model { providerID: string, modelID: string }
function M.model.toggle_favorite(model)
	if not is_model_valid(model) then
		return
	end
	local exists = false
	for i, item in ipairs(state.favorite) do
		if item.providerID == model.providerID and item.modelID == model.modelID then
			table.remove(state.favorite, i)
			exists = true
			break
		end
	end
	if not exists then
		table.insert(state.favorite, 1, { providerID = model.providerID, modelID = model.modelID })
	end
	save_state()
	emit("favorite", nil, state.favorite)
end

-- Variant module (like TUI's variant in local.tsx)
M.variant = {}

---Get variant key for a model
---@param model { providerID: string, modelID: string }
---@return string
local function variant_key(model)
	return model.providerID .. "/" .. model.modelID
end

---Get current variant for current model
---@return string|nil
function M.variant.current()
	local model = M.model.current()
	if not model then
		return nil
	end
	return state.variant[variant_key(model)]
end

---Get available variants for current model
---@return string[]
function M.variant.list()
	local model = M.model.current()
	if not model then
		return {}
	end
	local provider = sync.get_provider(model.providerID)
	if not provider or not provider.models then
		return {}
	end
	local model_info = provider.models[model.modelID]
	if not model_info or not model_info.variants then
		return {}
	end
	local variants = {}
	for name, _ in pairs(model_info.variants) do
		table.insert(variants, name)
	end
	-- Sort variants for consistent order
	table.sort(variants)
	return variants
end

---Set variant for current model
---@param value string|nil
function M.variant.set(value)
	local model = M.model.current()
	if not model then
		return
	end
	local key = variant_key(model)
	local old = state.variant[key]
	state.variant[key] = value
	save_state()
	emit("variant", old, value)
end

---Cycle through variants (like ctrl+t in TUI)
---@param opts? { silent?: boolean }
function M.variant.cycle(opts)
	opts = opts or {}
	local variants = M.variant.list()
	if #variants == 0 then
		if not opts.silent then
			vim.notify("No variants available for this model", vim.log.levels.INFO)
		end
		return
	end
	local current = M.variant.current()
	local new_variant = nil
	if not current then
		-- No variant selected, select first
		new_variant = variants[1]
		M.variant.set(new_variant)
	else
		-- Find current index
		local current_idx = nil
		for i, v in ipairs(variants) do
			if v == current then
				current_idx = i
				break
			end
		end
		if not current_idx or current_idx >= #variants then
			-- At end or not found, reset to default (nil)
			M.variant.set(nil)
			new_variant = nil
		else
			-- Move to next
			new_variant = variants[current_idx + 1]
			M.variant.set(new_variant)
		end
	end
	-- Show feedback
	if not opts.silent then
		if new_variant then
			vim.notify("Variant: " .. new_variant, vim.log.levels.INFO)
		else
			vim.notify("Variant: default", vim.log.levels.INFO)
		end
	end
end

-- Subscribe to state changes
---@param callback function(key, new_val, old_val)
function M.on(callback)
	table.insert(listeners, callback)
end

---Remove listener
---@param callback function
function M.off(callback)
	for i, cb in ipairs(listeners) do
		if cb == callback then
			table.remove(listeners, i)
			break
		end
	end
end

---Initialize the module (call on plugin setup)
function M.setup()
	load_state()
end

---Check if ready
---@return boolean
function M.is_ready()
	return state.ready
end

return M
