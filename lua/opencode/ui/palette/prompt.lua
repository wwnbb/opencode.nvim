local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")
function M.register(palette)
	palette.register({ id = "prompt.cancel_pending", title = "Cancel Pending Input", category = "prompt",
		description = "Remove one queued input; keep the current response running",
		enabled = function() return state.is_connected() and state.get_session().id ~= nil end,
		action = function()
			local sid = state.get_session().id
			if not sid then return end
			actions.list_pending_inputs(sid, function(err, inputs)
				if err then vim.notify("Could not load pending inputs: " .. tostring(err.message or err), vim.log.levels.ERROR); return end
				local items = {}
				for _, input in ipairs(inputs) do
					local text = input.payload and input.payload.text or input.type or "Input"
					items[#items + 1] = { label = tostring(text):gsub("[\r\n]", " "), value = input.id }
				end
				if #items == 0 then vim.notify("No pending inputs", vim.log.levels.INFO); return end
				require("opencode.ui.menu").open({ title = " Cancel Pending Input ", items = items,
					width = 60, searchable = true, on_select = function(item)
						actions.cancel_pending_input(sid, item.value, function(cancel_err)
							if cancel_err then vim.notify("Could not cancel input: " .. tostring(cancel_err.message or cancel_err), vim.log.levels.ERROR) end
						end)
					end })
			end)
		end })
	palette.register({ id = "action.skills", title = "Run Skills", description = "Select and activate skills", category = "prompt", suggested = true,
		action = function()
			local session = state.get_session()
			if not session.id or not state.is_connected() then vim.notify("Select a connected session first", vim.log.levels.WARN); return end
			local opts = { session_id = session.id, directory = state.get_session_directory(session.id) or vim.fn.getcwd() }
			opts._selection = require("opencode.selectors").send_selection(opts)
			actions.list_skills(function(err, skills)
				if err then vim.notify("Could not load skills", vim.log.levels.WARN); return end
				local items = {}
				for _, skill in ipairs(skills) do items[#items + 1] = { label = skill.name, value = skill.id, skill = skill, description = skill.description } end
				if #items == 0 then vim.notify("No skills available", vim.log.levels.INFO); return end
				require("opencode.ui.menu").open({ items = items, title = " Select Skills ", width = 60, searchable = true,
					multi_select = true, confirm_label = "run", on_select = function(selected)
						local chosen = {}; for _, item in ipairs(selected) do chosen[#chosen + 1] = item.skill end
						actions.run_skills(chosen, opts)
					end })
			end, opts)
		end })
end
return M
