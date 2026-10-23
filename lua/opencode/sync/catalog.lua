-- Provider, agent, and location catalogs owned by sync.lua. The data stays in
-- sync's store; catalog_for gives session-scoped lookups: a directory other than
-- the active catalog location reads that location's entries, and each domain
-- without a loaded entry falls back to the active store.
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

---@param sync table The sync facade; catalog reads and writes go through its public names
---@param store table Sync's store, which holds the catalog domains
---@return table
function M.new(sync, store)
	local C = {}
	local catalog_generation = 0
	local UTILITY_AGENT_NAMES = {
		compaction = true,
		summary = true,
		title = true,
	}

	---@param field string
	local function bump_store_counter(field)
		store[field] = (store[field] or 0) + 1
		if field == "provider_revision" then catalog_generation = catalog_generation + 1 end
	end

	function C.get_catalog_generation()
		return catalog_generation
	end

	function C.get_location_catalog(directory, domain)
		local entry = store.catalogs[directory] and store.catalogs[directory][domain]
		return entry and vim.deepcopy(entry) or nil
	end

	function C.get_catalog_location()
		return store.catalog_location
	end

	---Catalog for a session directory: the active store when directory is nil or the
	---active location, that location's entries otherwise (active store per missing domain).
	---@param directory string|nil
	---@return opencode.SyncCatalog
	function C.catalog_for(directory)
		return M.for_directory(sync, store.catalogs, store.catalog_location, directory)
	end

	local function apply_catalog(domain, data)
		if domain == "providers" then
			sync.handle_providers(data.providers)
			sync.handle_provider_defaults(data.default)
		elseif domain == "agents" then sync.handle_agents(data)
		elseif domain == "commands" then sync.handle_commands(data)
		elseif domain == "skills" then sync.handle_skills(data)
		elseif domain == "mcp" then sync.handle_mcp(data)
		elseif domain == "config" then sync.handle_config(data) end
	end

	function C.handle_location_catalog(directory, domain, data, err)
		catalog_generation = catalog_generation + 1
		store.catalogs[directory] = store.catalogs[directory] or {}
		local previous = store.catalogs[directory][domain]
		local entry = { status = err and "failed" or "loaded", error = err,
			data = err and previous and previous.data or data }
		store.catalogs[directory][domain] = entry
		if not err and store.catalog_location == directory then apply_catalog(domain, data) end
	end

	function C.select_catalog_location(directory)
		if store.catalog_location == directory then return end
		store.catalog_location = directory
		store.provider, store.provider_default, store.agent, store.command, store.skill, store.mcp, store.config = {}, {}, {}, {}, {}, {}, {}
		for domain, entry in pairs(store.catalogs[directory] or {}) do
			if entry.data then apply_catalog(domain, entry.data) end
		end
		bump_store_counter("provider_revision")
		bump_store_counter("agent_revision")
	end

	---Handle provider data update
	---@param providers table[] Array of provider objects
	function C.handle_providers(providers)
		store.provider = providers or {}
		bump_store_counter("provider_revision")
	end

	---Handle provider defaults
	---@param defaults table<string, string> { [providerID] = default_modelID }
	function C.handle_provider_defaults(defaults)
		store.provider_default = defaults or {}
		bump_store_counter("provider_revision")
	end

	---Get provider/model metadata revision.
	---@return number
	function C.get_provider_revision()
		return store.provider_revision or 0
	end

	---Get all providers
	---@return table[]
	function C.get_providers()
		return store.provider or {}
	end

	---Get provider defaults
	---@return table<string, string>
	function C.get_provider_defaults()
		return store.provider_default or {}
	end

	---Get a specific provider by ID
	---@param provider_id string
	---@return table|nil
	function C.get_provider(provider_id)
		for _, provider in ipairs(store.provider) do
			if provider.id == provider_id then
				return provider
			end
		end
		return nil
	end

	---Get a model from a provider
	---@param provider_id string
	---@param model_id string
	---@return table|nil
	function C.get_model(provider_id, model_id)
		local provider = sync.get_provider(provider_id)
		if provider and provider.models then
			return provider.models[model_id]
		end
		return nil
	end

	-- Agent management

	---Handle agent data update
	---@param agents table[] Array of agent objects
	function C.handle_agents(agents)
		store.agent = agents or {}
		bump_store_counter("agent_revision")
	end

	---Get agent metadata revision.
	---@return number
	function C.get_agent_revision()
		return store.agent_revision or 0
	end

	---Get all agents
	---@return table[]
	function C.get_agents()
		return store.agent or {}
	end

	---Check whether an agent should be selectable as a primary chat agent.
	---@param agent table|nil Agent object
	---@return boolean visible Whether the agent should be shown in primary-agent UI
	function C.is_visible_agent(agent)
		if type(agent) ~= "table" then
			return false
		end
		-- JSON null decodes to vim.NIL, which is truthy; only boolean true means hidden.
		if agent.hidden == true then
			return false
		end

		local name = agent.name or agent.id
		if type(name) == "string" and UTILITY_AGENT_NAMES[name] then
			return false
		end

		return agent.mode ~= "subagent"
	end

	---Filter agents to primary-capable, user-visible entries.
	---@param agents table[]|nil Array of agent objects
	---@return table[] agents Filtered agents
	function C.filter_visible_agents(agents)
		local visible = {}
		for _, agent in ipairs(agents or {}) do
			if sync.is_visible_agent(agent) then
				table.insert(visible, agent)
			end
		end
		return visible
	end

	---Get filtered agents (excluding subagents, hidden agents, and utility agents)
	---@return table[]
	function C.get_visible_agents()
		return sync.filter_visible_agents(store.agent)
	end

	---Check whether an agent should be mentionable via @ autocomplete.
	---@param agent table|nil Agent object
	---@return boolean mentionable Whether the agent should be shown in @ autocomplete
	function C.is_mentionable_agent(agent)
		if type(agent) ~= "table" then
			return false
		end
		-- JSON null decodes to vim.NIL, which is truthy; only boolean true means hidden.
		if agent.hidden == true then
			return false
		end

		local name = agent.name or agent.id
		if type(name) ~= "string" or name == "" then
			return false
		end

		return agent.mode ~= "primary"
	end

	---Filter agents to entries mentionable via @ autocomplete.
	---@param agents table[]|nil Array of agent objects
	---@return table[] agents Filtered agents
	function C.filter_mentionable_agents(agents)
		local mentionable = {}
		for _, agent in ipairs(agents or {}) do
			if sync.is_mentionable_agent(agent) then
				table.insert(mentionable, agent)
			end
		end
		return mentionable
	end

	---Get agents mentionable via @ autocomplete.
	---@return table[]
	function C.get_mentionable_agents()
		return sync.filter_mentionable_agents(store.agent)
	end

	---Get a specific agent by name
	---@param name string
	---@return table|nil
	function C.get_agent(name)
		for _, agent in ipairs(store.agent) do
			if agent.id == name then return agent end
		end
		for _, agent in ipairs(store.agent) do
			if agent.name == name then
				return agent
			end
		end
		return nil
	end

	-- Config management

	---Handle config update
	---@param config table
	function C.handle_config(config)
		store.config = config or {}
	end

	---Get config
	---@return table
	function C.get_config()
		return store.config or {}
	end

	-- Command management

	---Handle custom commands update
	---@param commands table[]
	function C.handle_commands(commands)
		store.command = commands or {}
	end

	---Get commands
	---@return table[]
	function C.get_commands()
		return store.command or {}
	end

	-- Skill management

	---Handle skills update
	---@param skills table[]
	function C.handle_skills(skills)
		store.skill = skills or {}
	end

	---Get skills
	---@return table[]
	function C.get_skills()
		return store.skill or {}
	end

	-- MCP management

	---Handle MCP status update
	---@param mcp table<string, table>
	function C.handle_mcp(mcp)
		store.mcp = mcp or {}
	end

	---Get MCP status
	---@return table<string, table>
	function C.get_mcp()
		return store.mcp or {}
	end

	---Drop every catalog domain; message data is cleared by sync.clear_all.
	function C.reset()
		catalog_generation = catalog_generation + 1
		store.provider_revision = 0
		store.agent_revision = 0
		store.provider = {}
		store.catalogs = {}
		store.catalog_location = nil
		store.provider_default = {}
		store.agent = {}
		store.command = {}
		store.skill = {}
		store.config = {}
		store.mcp = {}
	end

	return C
end

return M
