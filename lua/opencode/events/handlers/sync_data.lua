local M = {}

function M.setup(events)
	local sync = require("opencode.sync")
	local client = require("opencode.client")
	local logger = require("opencode.logger")

	---@param value any
	---@return string
	local function value_kind(value)
		if value == nil then
			return "nil"
		end
		if value == vim.NIL then
			return "vim.NIL"
		end
		return type(value)
	end

	---@param tbl table|nil
	---@return number
	local function count_keys(tbl)
		local count = 0
		if type(tbl) ~= "table" then
			return count
		end
		for _, _ in pairs(tbl) do
			count = count + 1
		end
		return count
	end

	---@param providers table[]
	---@param defaults table|nil
	---@return table
	local function summarize_providers(providers, defaults)
		local sample = {}
		local model_count = 0
		for _, provider in ipairs(providers or {}) do
			local provider_model_count = count_keys(provider.models)
			model_count = model_count + provider_model_count
			if #sample < 6 then
				table.insert(sample, {
					id = provider.id,
					name = provider.name,
					model_count = provider_model_count,
					default_model = type(provider.id) == "string" and defaults and defaults[provider.id] or nil,
				})
			end
		end
		return {
			count = #(providers or {}),
			model_count = model_count,
			default_count = count_keys(defaults),
			sample = sample,
		}
	end

	---@param agents table[]
	---@return table
	local function summarize_agents(agents)
		local visible = {}
		local hidden_true_count = 0
		local hidden_null_count = 0
		local subagent_count = 0
		for _, agent in ipairs(agents or {}) do
			if agent.hidden == true then
				hidden_true_count = hidden_true_count + 1
			elseif agent.hidden == vim.NIL then
				hidden_null_count = hidden_null_count + 1
			end
			if agent.mode == "subagent" then
				subagent_count = subagent_count + 1
			end
			if sync.is_visible_agent(agent) and #visible < 8 then
				table.insert(visible, agent.name or agent.id)
			end
		end
		return {
			count = #(agents or {}),
			visible_count = #sync.get_visible_agents(),
			visible_sample = visible,
			hidden_true_count = hidden_true_count,
			hidden_null_count = hidden_null_count,
			subagent_count = subagent_count,
		}
	end

	-- Update input info bar when providers/agents load (if input is visible)
	local function refresh_input_info_bar()
		local input_ok, input = pcall(require, "opencode.ui.input")
		if input_ok and input.is_visible and input.is_visible() then
			input.update_info_bar()
		end
	end

	events.on("providers_loaded", function()
		refresh_input_info_bar()
	end)

	events.on("agents_loaded", function()
		refresh_input_info_bar()
	end)

	events.on("config_loaded", function()
		refresh_input_info_bar()
	end)

	-- Fetch initial data when connected (like TUI does on startup)
	events.on("connected", function()
		vim.schedule(function()
			logger.debug("Fetching initial sync data (providers, agents, config, skills)")

			-- Fetch providers with models (using /config/providers like TUI does)
			-- This returns { providers: Provider[], default: { providerID: modelID } }
			client.get_config_providers(function(err, data)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch config providers", { error = err })
						return
					end
					if data then
						-- Handle providers array
						local providers = data.providers or {}
						sync.handle_providers(providers)

						-- Handle defaults mapping
						if data.default then
							sync.handle_provider_defaults(data.default)
						end

						logger.debug("Providers loaded", summarize_providers(providers, data.default))

						-- Emit event for UI updates
						events.emit("providers_loaded", providers)

						-- Warn if no providers are connected
						if #providers == 0 then
							logger.warn("No providers connected. Use :OpenCode command palette to connect a provider.")
						end
					end
				end)
			end)

			-- Fetch agents
			client.list_agents(function(err, agents)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch agents", { error = err })
						return
					end
					if agents then
						sync.handle_agents(agents)
						-- Emit event for UI updates
						events.emit("agents_loaded", agents)
						logger.debug("Agents loaded", summarize_agents(agents))
					end
				end)
			end)

			-- Fetch config
			client.get_config(function(err, config)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch config", { error = err })
						return
					end
					if config then
						sync.handle_config(config)
						-- Handle commands from config
						if config.command then
							sync.handle_commands(config.command)
						end
						events.emit("config_loaded", config)
						logger.debug("Config loaded", {
							model = config.model,
							model_kind = value_kind(config.model),
							default_agent = config.default_agent,
							command_count = count_keys(config.command),
						})
					end
				end)
			end)

			-- Fetch skills
			client.list_skills(function(err, skills)
				vim.schedule(function()
					if err then
						logger.warn("Failed to fetch skills", { error = err })
						return
					end
					sync.handle_skills(skills)
					events.emit("skills_loaded", skills)
					logger.debug("Skills loaded", { count = skills and #skills or 0 })
				end)
			end)

			-- Fetch MCP status
			client.get_mcp_status(function(err, mcp)
				vim.schedule(function()
					if not err and mcp then
						sync.handle_mcp(mcp)
						logger.debug("MCP status loaded")
					end
				end)
			end)
		end)
	end)
end

return M
