-- Session navigation: drill into child sessions and back.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")
local session_lock = require("opencode.session.lock")
local chat_tasks = require("opencode.ui.chat.tasks")
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
	local start_line = tonumber(item.start_line)
	local end_line = tonumber(item.end_line)
	if not start_line or not end_line or end_line < start_line then
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
		interactions.sync_widget_selection_from_cursor()
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
			local start_line, end_line = tonumber(pos.start_line), tonumber(pos.end_line)
			if start_line and end_line and end_line >= start_line then
				local line = first_content_line({ start_line = start_line, end_line = end_line })
				if not line then return false end
				vim.api.nvim_win_set_cursor(state.winid, { line + 1, 0 })
				local ok, interactions = pcall(require, "opencode.ui.chat.interactions")
				if ok and interactions and type(interactions.sync_widget_selection_from_cursor) == "function" then
					interactions.sync_widget_selection_from_cursor()
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

---@param value any
---@return string|nil
local function nonempty_string(value)
	if type(value) ~= "string" then
		return nil
	end
	local result = vim.trim(value)
	return result ~= "" and result or nil
end

---@param value any
---@return table|nil
---@return string|nil
local function model_ref(value)
	if type(value) ~= "table" then
		return nil, nil
	end

	local provider_id = nonempty_string(value.providerID or value.providerId or value.provider_id)
	local model_id = nonempty_string(value.modelID or value.modelId or value.model_id or value.id)
	if not provider_id or not model_id then
		return nil, nil
	end
	return { providerID = provider_id, modelID = model_id }, nonempty_string(value.variant)
end

---@param tool_part table
---@param child_session table|nil
---@param messages table[]
---@return table|nil model
---@return string|nil variant
local function resolve_child_model(tool_part, child_session, messages)
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = type(tool_state.input) == "table" and tool_state.input or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}
	local metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	local metadata_candidates = {
		state_metadata.model,
		metadata.model,
		state_metadata,
		metadata,
		input.model,
	}
	local fallback_variant = nonempty_string(state_metadata.variant)
		or nonempty_string(metadata.variant)
		or nonempty_string(input.variant)
	for _, role in ipairs({ "assistant", "user" }) do
		for index = #messages, 1, -1 do
			local message = messages[index]
			if type(message) == "table" and message.role == role then
				local message_model = type(message.model) == "table" and message.model or message
				fallback_variant = fallback_variant or nonempty_string(message_model.variant)
			end
		end
	end
	if type(child_session) == "table" then
		fallback_variant = fallback_variant or nonempty_string(child_session.variant)
	end

	for _, candidate in ipairs(metadata_candidates) do
		local model, variant = model_ref(candidate)
		if model then
			return model, variant or fallback_variant
		end
	end

	for _, role in ipairs({ "assistant", "user" }) do
		for index = #messages, 1, -1 do
			local message = messages[index]
			if type(message) == "table" and message.role == role then
				local model, variant = model_ref(message.model)
				if not model then
					model, variant = model_ref(message)
				end
				if model then
					return model, variant or fallback_variant
				end
			end
		end
	end

	if type(child_session) == "table" then
		local model, variant = model_ref(child_session.model)
		if model then
			return model, variant or fallback_variant
		end
		model, variant = model_ref(child_session)
		if model then
			return model, variant or fallback_variant
		end
	end

	return nil, nil
end

---@param tool_part table
---@param child_session table|nil
---@param messages table[]
---@return string|nil
local function resolve_child_agent(tool_part, child_session, messages)
	if type(child_session) == "table" then
		local agent = nonempty_string(child_session.agent)
		if agent then
			return agent
		end
	end

	for _, role in ipairs({ "assistant", "user" }) do
		for index = #messages, 1, -1 do
			local message = messages[index]
			if type(message) == "table" and message.role == role then
				local agent = nonempty_string(message.agent)
				if agent then
					return agent
				end
			end
		end
	end

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}
	local metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	return nonempty_string(state_metadata.agent)
		or nonempty_string(metadata.agent)
		or nonempty_string(tool_state.input and tool_state.input.subagent_type)
end

---@param child_session_id string
---@param tool_part table
---@param callback fun(err: string|nil, record: table|nil)
local function resolve_child_lock(child_session_id, tool_part, callback, strict)
	local child_session = nil
	local pending = require("opencode.session.pending")
	local token = pending.token(child_session_id)
	actions.get_session(child_session_id, function(session_error, session)
		if not pending.is_current(token) then return end
		if strict and session_error then callback(session_error); return end
		child_session = type(session) == "table" and session or nil

		actions.load_session_messages(child_session_id, { limit = 100 }, function(messages_error, response)
			if not pending.is_current(token) then return end
			local sync = require("opencode.sync")
			local current_tool_part = chat_tasks.resolve_tool_part(tool_part) or tool_part
			local messages = sync.get_messages(child_session_id)
			if #messages == 0 and type(response) == "table" then
				messages = {}
				for _, item in ipairs(response) do
					table.insert(messages, type(item.info) == "table" and item.info or item)
				end
			end

			local model, variant = resolve_child_model(current_tool_part, child_session, messages)
			local agent = resolve_child_agent(current_tool_part, child_session, messages)
			local errors = {}
			if not model then
				table.insert(
					errors,
					"Unable to determine the subagent execution model"
						.. (messages_error and (": " .. tostring(messages_error)) or "")
				)
			end
			if not agent then
				table.insert(errors, "Unable to determine the subagent agent")
			end

			local record = {
				agent = agent,
				model = model,
				variant = variant,
				child_session = child_session or { id = child_session_id },
				task = vim.deepcopy(current_tool_part),
			}
			if #errors > 0 then
				record.error = table.concat(errors, "; ")
				record.pending = not model
			end
			callback(nil, record)
		end)
	end)
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
	local app_state = require("opencode.state")
	local current = app_state.get_session()
	local pending = require("opencode.session.pending")
	local token = pending.token(current.id)
	navigation_request = navigation_request + 1
	local request = navigation_request
	local function is_current()
		return request == navigation_request and pending.is_current(token) and app_state.get_session().id == current.id
	end
	chat_tasks.resolve_task_child_session_id(pos, function(err, child_session_id)
		if not is_current() then return end
		if err then
			vim.notify("Failed to resolve child session: " .. tostring(err), vim.log.levels.WARN)
			return
		end
		if not child_session_id then
			vim.notify("No child session available yet", vim.log.levels.WARN)
			return
		end

		if current.id == child_session_id then
			return
		end

		local current_tool_part = chat_tasks.resolve_tool_part(pos) or tool_part
		resolve_child_lock(child_session_id, current_tool_part, function(lock_err, record)
			if not is_current() then return end
			if lock_err or not record then
				session_lock.clear(child_session_id)
				vim.notify("Cannot enter subagent session: " .. tostring(lock_err or "unknown metadata error"), vim.log.levels.ERROR)
				return
			end

			session_lock.set(child_session_id, record)
			actions.remember_session(record.child_session, { touch = false, reason = "child_navigation" })
			table.insert(state.session_stack, {
				id = current.id,
				name = current.name or "Session",
				runtime = app_state.is_runtime_session(current.id),
			})

			current_tool_part = chat_tasks.resolve_tool_part(pos) or current_tool_part
			local input = current_tool_part.state and current_tool_part.state.input or {}
			actions.set_active_session(child_session_id, record.child_session.title or record.child_session.name or input.description or "Subagent", {
				reason = "child_navigation",
				preserve_cache = true,
				runtime = false,
			})

			vim.schedule(function()
				render_coordinator.request({ session_id = child_session_id, reason = "child_navigation_loaded" })
			end)
		end)
	end)
end

-- Family navigation uses native ancestry and keeps children out of root tabs.
function M.open_family_session(session_id, opts)
	opts = opts or {}
	local app_state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local source_id = app_state.get_session().id
	local token = pending.token(source_id)
	local snapshot = app_state.get_session_record(session_id)
	local directory = app_state.get_session_directory(source_id)
	navigation_request = navigation_request + 1
	local request = navigation_request
	resolve_child_lock(session_id, { state = {} }, function(err, record)
		if request ~= navigation_request or not pending.is_current(token) or app_state.get_session().id ~= source_id
			or app_state.get_session_directory(source_id) ~= directory then return end
		if err or not record or record.child_session.id ~= session_id then
			vim.notify("Cannot open family session: " .. require("opencode.events.util").format_session_error(err,
				{ fallback = "Session metadata is unavailable" }), vim.log.levels.WARN)
			return
		end
		local latest = app_state.get_session_record(session_id)
		if vim.deep_equal(snapshot, latest) then actions.remember_session(record.child_session, { touch = false, reason = "family_navigation" })
		else record.child_session = vim.tbl_deep_extend("force", {}, record.child_session, latest or {}) end
		local info = record.child_session
		local child = type(info.parentID) == "string" and info.parentID ~= ""
		if child then session_lock.set(session_id, record) else session_lock.clear(session_id) end
		if opts.parent then
			while #state.session_stack > 0 do
				if table.remove(state.session_stack).id == session_id then break end
			end
		else state.session_stack = {} end
		actions.set_active_session(session_id, info.title or info.name or session_id, {
			reason = "family_navigation", preserve_cache = true, runtime = not child,
		})
		render_coordinator.request({ session_id = session_id, reason = "family_navigation_loaded" })
	end, true)
end

---Leave current child session and return to parent.
function M.leave_child_session()
	navigation_request = navigation_request + 1
	local app_state = require("opencode.state")
	local current_id = app_state.get_session().id
	local native_parent = (app_state.get_session_record(current_id) or {}).parentID
	if type(native_parent) == "string" and native_parent ~= "" then
		if native_parent == current_id then
			vim.notify("Session family has a parent cycle", vim.log.levels.WARN)
			return
		end
		M.open_family_session(native_parent, { parent = true })
		return
	end
	local parent
	repeat
		parent = table.remove(state.session_stack)
	until not parent or (app_state.get_session_record(parent.id)
		and (parent.runtime == false or app_state.is_runtime_session(parent.id)))
	if not parent then return end

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
