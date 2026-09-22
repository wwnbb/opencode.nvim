local M = {}

function M.providers(providers, models, default)
	local result, by_id = {}, {}
	for _, provider in ipairs(providers) do
		local value = vim.deepcopy(provider)
		value._v2, value.models = vim.deepcopy(provider), {}
		by_id[value.id] = value
		result[#result + 1] = value
	end
	for _, model in ipairs(models) do
		local provider = by_id[model.providerID]
		if provider and model.enabled == true then
			local value = vim.deepcopy(model)
			value._v2, value.upstream_model_id = vim.deepcopy(model), model.modelID
			-- Existing internal modelID references mean logical catalog IDs.
			value.modelID = model.id
			value.variants, value.variant_order = {}, {}
			for _, variant in ipairs(model.variants or {}) do
				value.variants[variant.id] = vim.deepcopy(variant)
				value.variant_order[#value.variant_order + 1] = variant.id
			end
			value.cost_tiers = vim.deepcopy(model.cost or {})
			value.cost = {}
			for _, tier in ipairs(model.cost or {}) do
				if not tier.tier then value.cost = vim.deepcopy(tier); break end
			end
			local capabilities = model.capabilities or {}
			value.tool_call = capabilities.tools == true
			value.attachment = vim.tbl_contains(capabilities.input or {}, "image")
			provider.models[model.id] = value
		end
	end
	local defaults = {}
	if type(default) == "table" then defaults[default.providerID] = default.id end
	return { providers = result, default = defaults, server_default = vim.deepcopy(default) }
end

function M.agents(agents)
	local result = vim.deepcopy(agents)
	for _, agent in ipairs(result) do
		agent._v2 = vim.deepcopy(agent)
		if type(agent.model) == "table" then agent.model.modelID = agent.model.id end
	end
	return result
end

function M.mcp(records)
	local result = {}
	for _, record in ipairs(records) do
		result[record.name] = vim.tbl_extend("force", vim.deepcopy(record), vim.deepcopy(record.status))
		result[record.name]._v2 = vim.deepcopy(record)
	end
	return result
end

return M
