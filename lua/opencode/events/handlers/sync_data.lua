local M = {}

function M.setup(events)
	local sync = require("opencode.sync")
	local client = require("opencode.client")
	local logger = require("opencode.logger")
	local schedule = require("opencode.util.schedule")

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

	local function report_initial_sync_error(kind, err)
		local message = "Failed to fetch " .. kind .. ": " .. tostring(err and (err.message or err.error) or err)
		logger.warn("Failed to fetch " .. kind, { error = err })
		vim.notify("OpenCode " .. message, vim.log.levels.WARN)
		events.emit("local_notice", {
			role = "system",
			kind = "sync_error",
			content = message,
		})
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

	---@param spec table
	---@return string
	local function sync_kind(spec)
		if spec.loaded_event then
			return (spec.loaded_event:gsub("_loaded$", ""))
		end
		return spec.kind
	end

	---@param spec table
	local function fetch_initial_item(spec)
		spec.request(function(err, data)
			schedule.schedule_pcall("initial sync " .. spec.kind, function()
				if err then
					if not spec.quiet_errors then
						report_initial_sync_error(spec.kind, err)
					end
					return
				end

				local payload, should_emit = spec.on_success(data)
				if should_emit == false then
					return
				end

				if spec.debug_summary then
					logger.debug(spec.debug_label or (spec.kind .. " loaded"), spec.debug_summary(payload, data))
				elseif spec.debug_label then
					logger.debug(spec.debug_label)
				end

				if spec.loaded_event then
					events.emit(spec.loaded_event, payload)
				end
				events.emit("sync_changed", {
					kind = sync_kind(spec),
					action = "loaded",
				})

				if spec.after_emit then
					spec.after_emit(payload, data)
				end
			end)
		end)
	end

	local initial_sync_specs = {
		{
			kind = "config providers",
			request = function(callback)
				client.get_config_providers(callback)
			end,
			loaded_event = "providers_loaded",
			on_success = function(data)
				if not data then
					return nil, false
				end
				local providers = data.providers or {}
				sync.handle_providers(providers)
				if data.default then
					sync.handle_provider_defaults(data.default)
				end
				return providers
			end,
			debug_label = "Providers loaded",
			debug_summary = function(providers, data)
				return summarize_providers(providers, data and data.default)
			end,
			after_emit = function(providers)
				local local_ok, local_state = pcall(require, "opencode.local")
				if local_ok and local_state.model and type(local_state.model.cleanup) == "function" then
					local_state.model.cleanup()
				end

				if #providers == 0 then
					logger.warn("No providers connected. Use :OpenCode command palette to connect a provider.")
				end
			end,
		},
		{
			kind = "agents",
			request = function(callback)
				client.list_agents(callback)
			end,
			loaded_event = "agents_loaded",
			on_success = function(agents)
				if not agents then
					return nil, false
				end
				sync.handle_agents(agents)
				return agents
			end,
			debug_label = "Agents loaded",
			debug_summary = summarize_agents,
		},
		{
			kind = "config",
			request = function(callback)
				client.get_config(callback)
			end,
			loaded_event = "config_loaded",
			on_success = function(config)
				if not config then
					return nil, false
				end
				sync.handle_config(config)
				if config.command then
					sync.handle_commands(config.command)
				end
				return config
			end,
			debug_label = "Config loaded",
			debug_summary = function(config)
				return {
					model = config.model,
					model_kind = value_kind(config.model),
					default_agent = config.default_agent,
					command_count = count_keys(config.command),
				}
			end,
		},
		{
			kind = "skills",
			request = function(callback)
				client.list_skills(callback)
			end,
			loaded_event = "skills_loaded",
			on_success = function(skills)
				sync.handle_skills(skills)
				return skills
			end,
			debug_label = "Skills loaded",
			debug_summary = function(skills)
				return { count = skills and #skills or 0 }
			end,
		},
		{
			kind = "mcp",
			request = function(callback)
				client.get_mcp_status(callback)
			end,
			quiet_errors = true,
			on_success = function(mcp)
				if not mcp then
					return nil, false
				end
				sync.handle_mcp(mcp)
				return mcp
			end,
			debug_label = "MCP status loaded",
		},
	}

	-- Fetch initial data when connected (like TUI does on startup)
	events.on("connected", function()
		schedule.schedule_pcall("initial sync fetch start", function()
			logger.debug("Fetching initial sync data (providers, agents, config, skills)")
			for _, spec in ipairs(initial_sync_specs) do
				fetch_initial_item(spec)
			end
		end)
	end)
end

return M
