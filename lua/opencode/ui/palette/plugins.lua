local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")
local pending = require("opencode.session.pending")

local function report(action, err)
	local message = (err.status == 404 or err.status == 405 or err.status == 501 or err.status == 503) and "This server does not support this plugin operation" or tostring(err.message or err)
	if err.status == 503 then message = "Server plugin operations are temporarily unavailable" .. (err.message and (": " .. err.message) or "") end
	vim.notify("Could not " .. action .. ": " .. message, vim.log.levels.ERROR)
end

local function source(plugin)
	return plugin.source.target or plugin.source.path or plugin.source.type
end

local function details(plugin)
	local lines = { plugin.id or source(plugin), "Source: " .. source(plugin), "Status: " .. plugin.state.status }
	if plugin.source.version then lines[#lines + 1] = "Version: " .. plugin.source.version end
	if plugin.state.error then
		lines[#lines + 1] = ""
		vim.list_extend(lines, vim.split(plugin.state.error, "\n", { plain = true }))
	end
	if plugin.state.ref then lines[#lines + 1] = "Diagnostic: " .. plugin.state.ref end
	local float = require("opencode.ui.float")
	local popup, bufnr = float.create_centered_popup({ title = " Server Plugin ", width = 76, height = math.min(22, #lines + 2) })
	popup:mount(); popup:render(lines)
	float.setup_close_keymaps(bufnr, function() popup:close() end)
end

function M.show(opts)
	opts = vim.deepcopy(opts or { directory = state.get_session_directory(state.get_session().id) or vim.fn.getcwd() })
	local token = pending.token()
	local function display(plugins)
		if not pending.is_current(token) then return end
		if #plugins == 0 then vim.notify("No server plugins found", vim.log.levels.INFO); return end
		local items = {}
		for _, plugin in ipairs(plugins) do
			local description = { plugin.state.status, plugin.source.type }
			if plugin.source.version then description[#description + 1] = plugin.source.version end
			if plugin.source.updating then description[#description + 1] = "updating"
			elseif plugin.source.outdated then description[#description + 1] = "update available" end
			items[#items + 1] = { label = plugin.id or source(plugin), description = table.concat(description, ", "), plugin = plugin }
		end
		local function check(ctx, target)
			if not pending.is_current(token) then return end
			ctx.close()
			actions.check_server_plugins(target, opts, function(err, result)
				if not pending.is_current(token) then return end
				if err then report("check plugin updates", err) else display(result) end
			end)
		end
		require("opencode.ui.menu").open({ title = " Server Plugins ", message = opts.directory, items = items, width = 76, searchable = true,
			on_select = function(item) if pending.is_current(token) then details(item.plugin) end end,
			keys = {
				{ key = "c", label = "c:check selected", handler = function(ctx, item)
					if item.plugin.source.type ~= "package" then vim.notify("Only package plugins have updates", vim.log.levels.INFO); return end
					check(ctx, item.plugin.source.target)
				end },
				{ key = "C", label = "C:check all", handler = function(ctx) check(ctx) end },
				{ key = "u", label = "u:update selected", handler = function(ctx, item)
					if not pending.is_current(token) then return end
					local plugin = item.plugin
					if plugin.source.type ~= "package" or not plugin.source.outdated or plugin.source.updating then
						vim.notify("Check for an available package update first", vim.log.levels.INFO); return
					end
					ctx.close()
					vim.notify("Updating " .. plugin.source.target .. "…", vim.log.levels.INFO)
					actions.update_server_plugins({ plugin.source.target }, opts, function(err)
						if not pending.is_current(token) then return end
						if err then report("update plugin", err); return end
						vim.notify("Server plugin updated", vim.log.levels.INFO)
						M.show(opts)
					end)
				end },
			} })
	end
	actions.list_server_plugins(opts, function(err, plugins)
		if not pending.is_current(token) then return end
		if err then report("list server plugins", err) else display(plugins) end
	end)
end

function M.register(palette)
	palette.register({ id = "system.plugins", title = "Server Plugins", description = "Inspect server plugins and check or update package plugins",
		category = "system", slash = { name = "plugins" }, on_select = function(context) return context.run() end,
		run = function() M.show() end })
end

return M
