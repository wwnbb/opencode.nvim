-- opencode.nvim - Agent palette commands

local M = {}

local client = require("opencode.client")
local lifecycle = require("opencode.lifecycle")
local state = require("opencode.state")
local sync = require("opencode.sync")
function M.register(palette)
	palette.register({
		id = "agent.switch",
		title = "Switch Agent",
		description = "Change the AI agent",
		category = "agent",
		keybind = "<leader>oa",
		action = function()
			lifecycle.ensure_connected(function()
				client.list_agents(function(err, agents)
					if err then
						vim.schedule(function()
							vim.notify("Failed to list agents: " .. tostring(err.message or err), vim.log.levels.ERROR)
						end)
						return
					end
					vim.schedule(function()
						sync.handle_agents(agents)
						local visible_agents = sync.get_visible_agents()
						if #visible_agents == 0 then
							vim.notify("No agents available", vim.log.levels.WARN)
							return
						end

						local items = {}
						for _, agent in ipairs(visible_agents) do
							table.insert(items, {
								label = (agent.name or agent.id)
									.. (agent.description and (" - " .. agent.description) or ""),
								value = agent.id,
								agent = agent,
							})
						end

						local float = require("opencode.ui.float")
						float.create_searchable_menu(items, function(item)
							-- Use local.lua module for agent selection (like TUI's local.tsx)
							local lc_ok, lc = pcall(require, "opencode.local")
							if lc_ok then
								lc.agent.set(item.agent.name)
							end
							-- Also update old state for backward compatibility
							state.set_agent(item.agent.id, item.agent.name)
							-- Update input info bar if visible
							local input_ok, input = pcall(require, "opencode.ui.input")
							if input_ok and input.is_visible and input.is_visible() then
								input.update_info_bar()
							end
						end, { title = " Switch Agent ", width = 60 })
					end)
				end)
			end)
		end,
	})
end

return M
