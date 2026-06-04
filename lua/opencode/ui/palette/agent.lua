-- opencode.nvim - Agent palette commands

local M = {}

local sync = require("opencode.sync")
local actions = require("opencode.actions")

function M.register(palette)
	palette.register({
		id = "agent.switch",
		title = "Switch Agent",
		description = "Change the AI agent",
		category = "agent",
		keybind = "<leader>oa",
		action = function()
			actions.list_agents(function(err)
				if err then
					vim.notify("Failed to list agents: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				local visible_agents = sync.get_visible_agents()
				if #visible_agents == 0 then
					vim.notify("No agents available", vim.log.levels.WARN)
					return
				end

				local items = {}
				for _, agent in ipairs(visible_agents) do
					table.insert(items, {
						label = (agent.name or agent.id) .. (agent.description and (" - " .. agent.description) or ""),
						value = agent.id,
						agent = agent,
					})
				end

				local float = require("opencode.ui.float")
				float.create_searchable_menu(items, function(item)
					actions.select_agent(item.agent.name)
				end, { title = " Switch Agent ", width = 60 })
			end)
		end,
	})
end

return M
