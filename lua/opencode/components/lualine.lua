local M = {}

local opts = {
	enabled = true,
	icon = "OC",
	show_model = true,
	show_agent = true,
	show_status = true,
	show_message_count = true,
}

local STATUS_ICON = {
	idle = "idle",
	streaming = "stream",
	thinking = "think",
	paused = "pause",
	error = "error",
}

local function compact_model(model)
	if type(model) ~= "table" then
		return nil
	end
	local provider = model.providerID or model.provider
	local id = model.modelID or model.id or model.name
	if type(id) ~= "string" or id == "" then
		return nil
	end
	if type(provider) == "string" and provider ~= "" then
		return provider .. "/" .. id
	end
	return id
end

local function current_model()
	local ok, local_state = pcall(require, "opencode.local")
	if ok and local_state.model and type(local_state.model.parsed) == "function" then
		local model = compact_model(local_state.model.parsed())
		if model then
			return model
		end
	end

	local ok_state, state = pcall(require, "opencode.state")
	if not ok_state then
		return nil
	end
	local model = state.get_model()
	if type(model.name) == "string" and model.name ~= "" then
		return model.name
	end
	return compact_model(model)
end

local function current_agent()
	local ok, local_state = pcall(require, "opencode.local")
	if ok and local_state.agent and type(local_state.agent.current) == "function" then
		local agent = local_state.agent.current()
		if type(agent) == "table" then
			return agent.name or agent.id
		end
	end

	local ok_state, state = pcall(require, "opencode.state")
	if not ok_state then
		return nil
	end
	local agent = state.get_agent()
	return agent.name or agent.id
end

function M.setup(config)
	opts = vim.tbl_deep_extend("force", opts, config or {})
end

function M.component()
	if opts.enabled == false then
		return ""
	end

	local ok, state = pcall(require, "opencode.state")
	if not ok then
		return ""
	end

	local summary = state.get_status_summary()
	local parts = { opts.icon or "OC" }
	if opts.show_status ~= false then
		table.insert(parts, STATUS_ICON[summary.status] or tostring(summary.status or "idle"))
	end
	if opts.show_agent ~= false then
		local agent = current_agent()
		if type(agent) == "string" and agent ~= "" then
			table.insert(parts, agent)
		end
	end
	if opts.show_model ~= false then
		local model = current_model()
		if type(model) == "string" and model ~= "" then
			table.insert(parts, model)
		end
	end
	if opts.show_message_count ~= false and (summary.message_count or 0) > 0 then
		table.insert(parts, tostring(summary.message_count))
	end

	return table.concat(parts, " ")
end

return M
