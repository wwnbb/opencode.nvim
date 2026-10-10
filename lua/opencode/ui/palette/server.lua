local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")
local menu = require("opencode.ui.menu")

function M.show()
	local status = actions.managed_server_status()
	local info = state.get_server_info()
	local target = status.url or (tostring(info.host or "localhost") .. ":" .. tostring(info.port or "pending"))
	local items = { { value = "reconnect", label = "Reconnect", description = status.discovered and "Rediscover URL and credentials before connecting" or target } }
	if status.can_manage then
		items[#items + 1] = { value = "restart", label = "Restart native managed service", description = "Closes persistent terminals on this host" }
		items[#items + 1] = { value = "upgrade", label = "Update OpenCode on this host", description = "Native installer detection; unsupported installers report a failure" }
	end
	return menu.open({ title = " Server ", width = 82, sort = false, items = items,
		message = target .. (status.discovered and (" — native service PID " .. tostring(status.pid or "unverified")) or ""),
		on_select = function(item)
			if item.value == "reconnect" then actions.disconnect(); actions.reconnect(function() vim.notify("OpenCode reconnected", vim.log.levels.INFO) end); return end
			local fresh = actions.managed_server_status()
			if not fresh.can_manage or fresh.pid ~= status.pid or fresh.url ~= status.url then
				vim.notify("Managing host changed; reopen Server", vim.log.levels.WARN); return
			end
			menu.open({ title = " " .. item.label .. " ", width = 78, sort = false,
				message = item.value == "restart" and "Restarting shuts down persistent terminals." or "Runs the native updater for the local OpenCode installation.",
				items = { "Continue", "Cancel" }, on_select = function(choice)
					if choice ~= "Continue" then return end
					actions.manage_server(item.value, function(err)
						vim.notify(err and err.message or (item.value == "restart" and "Native service restarted; reconnecting" or "Native updater finished; restart the managed service to use the installed version"), err and vim.log.levels.WARN or vim.log.levels.INFO)
					end)
				end })
		end })
end

function M.register(palette)
	palette.register({ id = "system.server", title = "Server", category = "system", description = "Connection and managing-host actions",
		slash = { name = "server" }, run = M.show, on_select = function(context) return context.run() end })
end

return M
