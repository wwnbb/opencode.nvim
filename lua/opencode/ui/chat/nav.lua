local cs = require("opencode.ui.chat.state")
return cs.factory("nav", function(view)
-- Session navigation: drill into child sessions and back.

local M = {}

local state = view
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")
local session_lock = require("opencode.session.lock")
local focus = require("opencode.session.focus")
local chat_tasks = cs.module(view, require("opencode.ui.chat.tasks"))
local positions = cs.module(view, require("opencode.ui.chat.positions"))
local navigation_request = 0

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

local function add_range(items, item, id, kind)
	if type(item) ~= "table" then
		return
	end
	local start_line, end_line = positions.range(item)
	if not start_line or end_line < start_line then
		return
	end
	local copy = vim.tbl_extend("force", {}, item, {
		start_line = start_line,
		end_line = end_line,
	})
	if id ~= nil then copy.id = id end
	if kind ~= nil then copy.kind = kind end
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

local function collect_messages(role, unsorted)
	local items = {}
	for _, pos in ipairs(state.message_positions or {}) do
		if not role or pos.role == role then
			add_range(items, pos)
		end
	end
	return unsorted and items or sorted_ranges(items)
end

local function collect_messages_and_widgets()
	local items = collect_messages(nil, true)
	for _, spec in ipairs(WIDGET_LINE_MAPS) do
		for id, pos in pairs(state[spec.map] or {}) do
			add_range(items, pos, id, spec.kind)
		end
	end
	return sorted_ranges(items)
end

local function collect_pending_permissions()
	local items = {}
	for id, pos in pairs(state.permissions or {}) do
		if pos.status == "pending" then
			add_range(items, pos, id, "permission")
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
		cs.module(view, interactions).sync_widget_selection_from_cursor()
	end
	return true
end

---Jump to a rendered message by its server ID.
---@param message_id string
---@return boolean
function M.jump_to_message(message_id)
	if not valid_chat_window() then return false end
	for _, pos in ipairs(state.message_positions or {}) do
		if pos.id == message_id then
			local start_line, end_line = positions.range(pos)
			if start_line and end_line >= start_line then
				local line = first_content_line({ start_line = start_line, end_line = end_line })
				if not line then return false end
				vim.api.nvim_win_set_cursor(state.winid, { line + 1, 0 })
				local ok, interactions = pcall(require, "opencode.ui.chat.interactions")
				if ok and interactions and type(interactions.sync_widget_selection_from_cursor) == "function" then
					cs.module(view, interactions).sync_widget_selection_from_cursor()
				end
				return true
			end
		end
	end
	return false
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

local function resolve_child_lock(child_session_id, tool_part, callback)
	return session_lock.resolve(child_session_id, tool_part, {
		get_session = actions.get_session,
		load_messages = actions.load_session_messages,
		tool_part = chat_tasks.resolve_tool_part,
	}, callback)
end

-- Switch this view after the caller prepared its stack; when focus moved away
-- the switch is superseded and previous_stack is restored. `after` runs before
-- that restore either way.
local function switch_view_session(session_id, title, opts, initial_input, previous_stack, after)
	local switched = focus.with_session_focus(view, function()
		return actions.set_view_session(view, session_id, title, opts)
	end, initial_input)
	if after then after() end
	if switched == false then
		state.session_stack = previous_stack
		return false
	end
	return true
end

---Enter a child session (drill down into subagent output).
---@param part_id string
function M.enter_child_session(part_id)
	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	local tool_part = chat_tasks.resolve_tool_part(pos)
	if not tool_part then
		return
	end
	local sync = require("opencode.sync")
	local stored_part = sync.get_part(tool_part.messageID, tool_part.id)
	local app_state = require("opencode.state")
	local current = cs.session(view)
	local initial_input = focus.capture_input(view)
	local pending = require("opencode.session.pending")
	local token, generation = pending.token(current.id), view.generation
	navigation_request = navigation_request + 1
	local request = navigation_request
	local function is_current()
		return request == navigation_request and pending.is_current(token) and cs.valid(view, generation) and cs.session(view).id == current.id
	end
	chat_tasks.resolve_task_child_session_id(pos, function(err, child_session_id)
		if not is_current() then return end
		if err then
			vim.notify("Failed to resolve child session: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		if not child_session_id then
			require("opencode.ui.palette.family").show({ view = view })
			return
		end

		if current.id == child_session_id then
			return
		end

		local current_tool_part = chat_tasks.resolve_tool_part(pos) or tool_part
		resolve_child_lock(child_session_id, current_tool_part, function(lock_err, record)
			if not is_current() then return end
			local latest_pos = state.tasks[part_id]
			if not latest_pos or (stored_part and not sync.get_part(tool_part.messageID, tool_part.id)) then return end
			current_tool_part = chat_tasks.resolve_tool_part(latest_pos)
			if require("opencode.events.util").resolve_task_child_session_id(current_tool_part) ~= child_session_id then return end
			if lock_err or not record then
				vim.notify("Cannot enter subagent session: " .. require("opencode.events.util").format_session_error(lock_err,
					{ fallback = "Session metadata is unavailable" }), vim.log.levels.ERROR)
				return
			end

			session_lock.set(child_session_id, record)
			actions.remember_session(record.child_session, { touch = false, reason = "child_navigation" })
			local previous_stack = vim.list_slice(state.session_stack)
			table.insert(state.session_stack, {
				id = current.id,
				name = current.name or "Session",
				runtime = app_state.is_runtime_session(current.id),
			})

			local input = current_tool_part.state and current_tool_part.state.input or {}
			local title = record.child_session.title or record.child_session.name or input.description or "Subagent"
			if not switch_view_session(child_session_id, title, {
				reason = "child_navigation",
				preserve_cache = true,
				runtime = false,
			}, initial_input, previous_stack) then return end

			vim.schedule(function()
				render_coordinator.request({ session_id = child_session_id, reason = "child_navigation_loaded", immediate = true })
			end)
		end)
	end)
end

local function show_parent_tail(session_id)
	local target = cs.current()
	if cs.session(target).id ~= session_id then return end
	local generation = target.generation
	vim.schedule(function()
		if not cs.valid(target, generation) or cs.session(target).id ~= session_id
			or not cs.is_chat_buffer_displayed(target) then return end
		-- Finish the session reset and throttled render before positioning the viewport.
		require("opencode.ui.chat").for_view(target).do_render()
		cs.module(target, require("opencode.ui.chat.cursor")).scroll_to_bottom()
	end)
end

-- Family navigation uses native ancestry and keeps children out of root tabs.
function M.open_family_session(session_id, opts)
	opts = opts or {}
	local app_state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local source_id = cs.session(view).id
	local initial_input = focus.capture_input(view)
	local token, generation = pending.token(source_id), view.generation
	local directory = app_state.get_session_directory(source_id)
	navigation_request = navigation_request + 1
	local request = navigation_request
	resolve_child_lock(session_id, { state = {} }, function(err, record)
		if not cs.valid(view, generation) or request ~= navigation_request or not pending.is_current(token) or cs.session(view).id ~= source_id
			or app_state.get_session_directory(source_id) ~= directory then return end
		if err or not record or record.child_session.id ~= session_id then
			vim.notify("Cannot open family session: " .. require("opencode.events.util").format_session_error(err,
				{ fallback = "Session metadata is unavailable" }), vim.log.levels.WARN)
			return
		end
		actions.remember_session(record.child_session, { touch = false, reason = "family_navigation" })
		local info = record.child_session
		local child = type(info.parentID) == "string" and info.parentID ~= ""
		if child then session_lock.set(session_id, record) else session_lock.clear(session_id) end
		local previous_stack = vim.list_slice(state.session_stack)
		if opts.parent then
			while #state.session_stack > 0 do
				if table.remove(state.session_stack).id == session_id then break end
			end
		else state.session_stack = {} end
		if not switch_view_session(session_id, info.title or info.name or session_id, {
			reason = "family_navigation", preserve_cache = true, runtime = not child,
		}, initial_input, previous_stack, opts.parent and function() show_parent_tail(session_id) end) then return end
		render_coordinator.request({ session_id = session_id, reason = "family_navigation_loaded", immediate = true })
	end)
end

---Leave current child session and return to parent.
function M.leave_child_session()
	navigation_request = navigation_request + 1
	local app_state = require("opencode.state")
	local current_id = cs.session(view).id
	local native_parent = (app_state.get_session_record(current_id) or {}).parentID
	if type(native_parent) == "string" and native_parent ~= "" then
		if native_parent == current_id then
			vim.notify("Session family has a parent cycle", vim.log.levels.WARN)
			return
		end
		M.open_family_session(native_parent, { parent = true })
		return
	end
	local previous_stack = vim.list_slice(state.session_stack)
	local parent
	repeat
		parent = table.remove(state.session_stack)
	until not parent or (app_state.get_session_record(parent.id)
		and (parent.runtime == false or app_state.is_runtime_session(parent.id)))
	if not parent then return end

	if not switch_view_session(parent.id, parent.name, {
		reason = "child_navigation",
		preserve_cache = true,
		runtime = parent.runtime ~= false,
	}, nil, previous_stack, function() show_parent_tail(parent.id) end) then return end

	vim.schedule(function()
		render_coordinator.request({ session_id = parent.id, reason = "child_navigation", immediate = true })
	end)
end

return M

end)
