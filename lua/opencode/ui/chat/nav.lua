-- Session navigation: drill into child sessions and back.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")

---@return boolean
function M.is_navigating()
	return state.navigating
end

---Enter a child session (drill down into subagent output).
---@param part_id string
function M.enter_child_session(part_id)
	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	local chat_tasks = require("opencode.ui.chat.tasks")

	chat_tasks.resolve_task_child_session_id(pos.tool_part, function(err, child_session_id)
		if err then
			vim.notify("Failed to resolve child session: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		if not child_session_id then
			vim.notify("No child session available yet", vim.log.levels.WARN)
			return
		end

			local app_state = require("opencode.state")
			local sync = require("opencode.sync")

		local current = app_state.get_session()
		if current.id == child_session_id then
			return
		end

		local input = pos.tool_part.state and pos.tool_part.state.input or {}
		table.insert(state.session_stack, {
			id = current.id,
			name = current.name or "Session",
			runtime = app_state.is_runtime_session(current.id),
		})

		local child_name = input.description or "Subagent"

			actions.set_active_session(child_session_id, child_name, {
				reason = "child_navigation",
				preserve_cache = true,
				runtime = false,
			})

		local messages = sync.get_messages(child_session_id)
		if #messages > 0 then
			vim.schedule(function()
				render_coordinator.request({ session_id = child_session_id, reason = "child_navigation" })
			end)
		else
				actions.load_session_messages(child_session_id, { limit = 100 }, function(fetch_err)
					vim.schedule(function()
						if fetch_err then
							vim.notify("Failed to load subagent messages: " .. tostring(fetch_err), vim.log.levels.ERROR)
							M.leave_child_session()
							return
						end

						render_coordinator.request({ session_id = child_session_id, reason = "child_navigation_loaded" })
					end)
				end)
			end
	end)
end

---Leave current child session and return to parent.
function M.leave_child_session()
	if #state.session_stack == 0 then
		return
	end

	local parent = table.remove(state.session_stack)

	actions.set_active_session(parent.id, parent.name, {
		reason = "child_navigation",
		preserve_cache = true,
		runtime = parent.runtime ~= false,
	})

	vim.schedule(function()
		render_coordinator.request({ session_id = parent.id, reason = "child_navigation" })
	end)
end

return M
