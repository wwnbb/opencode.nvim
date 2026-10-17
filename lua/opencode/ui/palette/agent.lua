-- opencode.nvim - Agent palette commands

local M = {}

local actions = require("opencode.actions")
local state = require("opencode.state")

function M.register(palette)
	palette.register({
		id = "agent.switch",
		title = "Switch Agent",
		description = "Change the AI agent",
		category = "agent",
		slash = { name = "agents" },
		run = function(context)
			local owner = require("opencode.ui.palette")
			context = owner.capture_context(context)
			if not owner.context_valid(context) then return false end
			local pending = require("opencode.session.pending")
			local token = pending.token(context.session_id)
			local directory = state.get_session_directory(token.session_id) or vim.fn.getcwd()
			local function current()
				return pending.is_current(token) and owner.context_valid(context)
					and (state.get_session_directory(token.session_id) or vim.fn.getcwd()) == directory
			end
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
