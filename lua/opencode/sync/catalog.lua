-- Session-scoped catalog lookup owned by sync.lua. A directory other than the
-- active catalog location reads that location's entries; each domain without a
-- loaded entry falls back to the active store.
local M = {}

---Find an agent by stable ID across the whole list first, then by display name.
---@param agents table[]
---@param name any
---@return table|nil agent
---@return integer|nil index
function M.find_agent(agents, name)
	if type(name) ~= "string" then return end
	for _, field in ipairs({ "id", "name" }) do
		for index, agent in ipairs(agents or {}) do
			if agent[field] == name then return agent, index end
		end
	end
end

---@class opencode.SyncCatalog
---@field location string|nil Directory whose location entries were consulted
---@field providers table[]
---@field defaults table<string, string>
---@field server_default table|nil Location's native default model reference
---@field agents table[]
---@field config table
---@field loaded { providers: boolean, agents: boolean, config: boolean } Location entry has data
local Catalog = {}
Catalog.__index = Catalog

---@param id string
---@return table|nil
function Catalog:provider(id)
	if not self._scoped.providers then return self._sync.get_provider(id) end
	for _, provider in ipairs(self.providers) do
		if provider.id == id then return provider end
	end
end

---@param provider_id string
---@param model_id string
---@return table|nil
function Catalog:model(provider_id, model_id)
	local provider = self:provider(provider_id)
	local models = provider and provider.models
	return type(models) == "table" and models[model_id] or nil
end

---@param name string
---@return table|nil
function Catalog:agent(name)
	if not self._scoped.agents then return self._sync.get_agent(name) end
	return (M.find_agent(self.agents, name))
end

---@param sync table The sync module (public getters stay stubbable)
---@param catalogs table<string, table> Location -> domain -> entry
---@param location string|nil Active catalog location
---@param directory string|nil Requested session directory
---@return opencode.SyncCatalog
function M.for_directory(sync, catalogs, location, directory)
	local entries = catalogs[directory or location] or {}
	local function data(domain)
		local entry = entries[domain]
		return entry and entry.data or nil
	end
	local providers, agents, config = data("providers"), data("agents"), data("config")
	local scoped = directory ~= nil and directory ~= location
	local scoped_providers = scoped and providers ~= nil
	local scoped_agents = scoped and agents ~= nil
	local scoped_config = scoped and config ~= nil
	return setmetatable({
		_sync = sync,
		_scoped = { providers = scoped_providers, agents = scoped_agents },
		location = directory or location,
		providers = scoped_providers and (providers.providers or {}) or sync.get_providers(),
		defaults = scoped_providers and (providers.default or {}) or sync.get_provider_defaults(),
		server_default = providers and providers.server_default or nil,
		agents = scoped_agents and agents or sync.get_agents(),
		config = scoped_config and config or sync.get_config(),
		loaded = { providers = providers ~= nil, agents = agents ~= nil, config = config ~= nil },
	}, Catalog)
end

return M
