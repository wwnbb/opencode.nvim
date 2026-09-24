local M = {}

function M.setup(events)
	local sync = require("opencode.sync")
	local client = require("opencode.client")
	local state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local revisions, scheduled = {}, {}
	local methods = {
		providers = "get_config_providers", agents = "list_agents", commands = "list_commands",
		skills = "list_skills", mcp = "get_mcp_status", config = "get_config",
	}
	local domains = {
		["provider.updated"] = "providers", ["model.updated"] = "providers",
		["agent.updated"] = "agents", ["command.updated"] = "commands",
		["skill.updated"] = "skills", ["mcp.status.changed"] = "mcp",
		["mcp.resources.changed"] = "mcp", ["config.updated"] = "config",
		["credential.updated"] = "providers", ["credential.switched"] = "providers",
		["integration.updated"] = "providers",
	}
	local function current_directory()
		return state.normalize_directory(state.get_session_directory(state.get_session().id) or vim.fn.getcwd())
	end
	local function refresh(domain, directory)
		local key = directory .. "\0" .. domain
		revisions[key] = (revisions[key] or 0) + 1
		local revision, token = revisions[key], pending.token()
		client[methods[domain]](function(err, data)
			if revisions[key] ~= revision or not pending.is_current(token) then return end
			sync.handle_location_catalog(directory, domain, data, err)
			if err then
				local message = "Failed to fetch " .. domain .. ": " .. (err.message or "unknown error")
				if domain == "mcp" then require("opencode.logger").debug(message)
				else
					vim.notify("OpenCode: " .. message, vim.log.levels.WARN)
					events.emit("local_notice", { content = message, level = "warn" })
				end
				return
			end
			if sync.get_catalog_location() ~= directory then return end
			events.emit(domain .. "_loaded", domain == "providers" and data.providers or data)
			events.emit("sync_changed", { kind = domain, action = "loaded" })
			local ok, input = pcall(require, "opencode.ui.input")
			if ok and input.is_visible and input.is_visible() then input.update_info_bar() end
		end, { directory = directory })
	end
	local function refresh_all()
		local directory = current_directory()
		sync.select_catalog_location(directory)
		for domain in pairs(methods) do refresh(domain, directory) end
	end
	events.on("connected", refresh_all)
	events.on("session_change", function()
		if state.is_connected() then refresh_all() end
	end)
	events.on("catalog_invalidated", function(data)
		local domain = domains[data.type]
		if not domain then return end
		local directory = state.normalize_directory(data.location and data.location.directory or current_directory())
		local key = directory .. "\0" .. domain
		if scheduled[key] then return end
		local token = pending.token()
		scheduled[key] = true
		vim.defer_fn(function()
			scheduled[key] = nil
			if pending.is_current(token) then refresh(domain, directory) end
		end, 100)
	end)
end

return M
