-- opencode.nvim - Agent palette commands

local M = {}

local actions = require("opencode.actions")

function M.register(palette)
	palette.register({
		id = "agent.switch",
		title = "Switch Agent",
		description = "Change the AI agent",
		category = "agent",
		slash = { name = "agents" },
		run = function(context)
			local palette_context = require("opencode.ui.palette.context")
			context = palette_context.capture(context)
			if not palette_context.valid(context) then return false end
			local current, token, directory = palette_context.guard(context,
				{ session_token = context.session_id, require_view = true, same_directory = "cwd" })
			actions.list_agents(function(err)
				if not current() then return end
				if context.view and require("opencode.ui.chat.state").current() ~= context.view then return end
				if err then
					vim.notify("Failed to list agents: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				local visible_agents = require("opencode.local").agent.list({ session_id = token.session_id })
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

				local menu = require("opencode.ui.menu")
				menu.open({
					context = context,
					items = items,
					title = " Switch Agent ",
					width = 60,
					searchable = true,
					on_select = function(item)
						if not current() then return end
						actions.select_agent(item.agent.id or item.agent.name, { session_id = token.session_id })
					end,
				})
			end, { directory = directory })
		end,
	})
end

return M
