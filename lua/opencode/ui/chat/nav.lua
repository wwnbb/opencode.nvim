-- Session navigation: drill into child sessions and back.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

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
		local client = require("opencode.client")
		local sync = require("opencode.sync")

		local current = app_state.get_session()
		if current.id == child_session_id then
			return
		end

		local input = pos.tool_part.state and pos.tool_part.state.input or {}
		table.insert(state.session_stack, {
			id = current.id,
			name = current.name or "Session",
		})

		local child_name = input.description or "Subagent"

		state.navigating = true
		app_state.set_session(child_session_id, child_name)
		state.navigating = false

		local messages = sync.get_messages(child_session_id)
		if #messages > 0 then
			vim.schedule(function()
				require("opencode.ui.chat").do_render()
			end)
		else
			client.get_messages(child_session_id, {}, function(fetch_err, response)
				vim.schedule(function()
					if fetch_err then
						vim.notify("Failed to load subagent messages: " .. tostring(fetch_err), vim.log.levels.ERROR)
						M.leave_child_session()
						return
					end

					if response and type(response) == "table" then
						for _, msg_with_parts in ipairs(response) do
							local info = msg_with_parts.info
							if info then
								info.sessionID = child_session_id
								sync.handle_message_updated(info)
							end
							local parts = msg_with_parts.parts
							if parts then
								for _, part in ipairs(parts) do
									sync.handle_part_updated(part)
								end
							end
						end
					end

					require("opencode.ui.chat").do_render()
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

	local app_state = require("opencode.state")
	local parent = table.remove(state.session_stack)

	state.navigating = true
	app_state.set_session(parent.id, parent.name)
	state.navigating = false

	vim.schedule(function()
		require("opencode.ui.chat").do_render()
	end)
end

return M
