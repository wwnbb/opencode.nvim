-- Session navigation: drill into child sessions and back.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")

local WIDGET_LINE_MAPS = {
	{ kind = "question", map = "questions" },
	{ kind = "permission", map = "permissions" },
	{ kind = "edit", map = "edits" },
	{ kind = "task", map = "tasks" },
	{ kind = "tool", map = "tools" },
}

local function valid_chat_window()
	return state.bufnr
		and vim.api.nvim_buf_is_valid(state.bufnr)
		and state.winid
		and vim.api.nvim_win_is_valid(state.winid)
end

local function add_range(items, item)
	if type(item) ~= "table" then
		return
	end
	local start_line = tonumber(item.start_line)
	local end_line = tonumber(item.end_line)
	if not start_line or not end_line or end_line < start_line then
		return
	end
	local copy = vim.tbl_extend("force", {}, item, {
		start_line = start_line,
		end_line = end_line,
	})
	table.insert(items, copy)
end

local function sorted_ranges(items)
	table.sort(items, function(a, b)
		if a.start_line ~= b.start_line then
			return a.start_line < b.start_line
		end
		if a.end_line ~= b.end_line then
			return a.end_line < b.end_line
		end
		return tostring(a.kind or a.role or a.id or "") < tostring(b.kind or b.role or b.id or "")
	end)
	return items
end

local function collect_messages(role)
	local items = {}
	for _, pos in ipairs(state.message_positions or {}) do
		if not role or pos.role == role then
			add_range(items, pos)
		end
	end
	return sorted_ranges(items)
end

local function collect_messages_and_widgets()
	local items = collect_messages()
	for _, spec in ipairs(WIDGET_LINE_MAPS) do
		for id, pos in pairs(state[spec.map] or {}) do
			add_range(items, vim.tbl_extend("force", {}, pos, {
				id = id,
				kind = spec.kind,
			}))
		end
	end
	return sorted_ranges(items)
end

local function collect_pending_permissions()
	local items = {}
	for id, pos in pairs(state.permissions or {}) do
		if pos.status == "pending" then
			add_range(items, vim.tbl_extend("force", {}, pos, {
				id = id,
				kind = "permission",
			}))
		end
	end
	return sorted_ranges(items)
end

local function first_content_line(pos)
	if not valid_chat_window() then
		return nil
	end
	local line_count = vim.api.nvim_buf_line_count(state.bufnr)
	local start_line = math.max(0, math.min(pos.start_line, line_count - 1))
	local end_line = math.max(start_line, math.min(pos.end_line, line_count - 1))
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, start_line, end_line + 1, false)
	for idx, line in ipairs(lines) do
		if type(line) == "string" and vim.trim(line) ~= "" then
			return start_line + idx - 1
		end
	end
	return start_line
end

local function jump_ranges(items, direction)
	if not valid_chat_window() or #items == 0 then
		return false
	end

	local cursor_line = vim.api.nvim_win_get_cursor(state.winid)[1] - 1
	local count = math.max(tonumber(vim.v.count1) or 1, 1)
	local target = nil

	for _ = 1, count do
		target = nil
		if direction > 0 then
			for _, pos in ipairs(items) do
				if pos.start_line > cursor_line then
					target = pos
					break
				end
			end
		else
			for idx = #items, 1, -1 do
				local pos = items[idx]
				if pos.start_line < cursor_line then
					target = pos
					break
				end
			end
		end

		if not target then
			break
		end
		cursor_line = target.start_line
	end

	if not target then
		return false
	end

	local target_line = first_content_line(target)
	if not target_line then
		return false
	end
	vim.api.nvim_win_set_cursor(state.winid, { target_line + 1, 0 })
	local ok, interactions = pcall(require, "opencode.ui.chat.interactions")
	if ok and interactions and type(interactions.sync_widget_selection_from_cursor) == "function" then
		interactions.sync_widget_selection_from_cursor()
	end
	return true
end

---@return boolean
function M.is_navigating()
	return state.navigating
end

---@param direction 1|-1
function M.jump_user_message(direction)
	return jump_ranges(collect_messages("user"), direction)
end

---@param direction 1|-1
function M.jump_message_or_widget(direction)
	return jump_ranges(collect_messages_and_widgets(), direction)
end

---@param direction 1|-1
function M.jump_pending_permission(direction)
	return jump_ranges(collect_pending_permissions(), direction)
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
