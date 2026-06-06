local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

local spinner = require("opencode.ui.spinner")
local chat_todos = require("opencode.ui.chat.todos")
local chat_tasks = require("opencode.ui.chat.tasks")
local render_state = require("opencode.ui.chat.render_state")

local schedule_render = function() end

function M.set_schedule_render(fn)
	schedule_render = type(fn) == "function" and fn or function() end
end

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

local function stop_spinner_animation_timer()
	if not state.spinner_anim_timer then
		return
	end
	if vim.uv.is_closing(state.spinner_anim_timer) then
		state.spinner_anim_timer = nil
		return
	end
	state.spinner_anim_timer:stop()
	state.spinner_anim_timer:close()
	state.spinner_anim_timer = nil
end

---@param role string
---@param content string
---@param opts? table
function M.add_message(role, content, opts)
	opts = opts or {}

	local message = {
		role = role,
		content = content,
		timestamp = opts.timestamp or os.time(),
		id = opts.id or tostring(os.time()) .. "_" .. #state.local_notices,
		session_id = opts.session_id,
		agent = opts.agent,
		kind = opts.kind,
		child_session_id = opts.child_session_id,
		optimistic = opts.optimistic,
		tool_calls = opts.tool_calls,
	}

	table.insert(state.local_notices, message)
	if opts.render == false then
		schedule_render()
	else
		M.render_message(message)
	end
	return message.id
end

---@param message table
function M.render_message(message)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local lines = {}
	local highlights = {}

	if
		message.role == "assistant"
		and (not message.content or message.content == "")
		and (not message.reasoning or message.reasoning == "")
	then
		return
	end

	local role_display = message.role == "user" and "You" or (message.role == "assistant" and "Assistant" or "System")
	local time_str = os.date("%H:%M", message.timestamp)
	local id_display = message.id or "??????"
	local header_padding = string.rep(" ", math.max(1, 50 - #role_display - #time_str - #id_display - 3))
	local header_text = string.format(
		"%s [%s] %s%s",
		role_display,
		id_display,
		header_padding,
		time_str
	)
	table.insert(lines, header_text)
	table.insert(highlights, {
		line = #lines - 1,
		col_start = 0,
		col_end = #role_display,
		hl_group = message.role == "user" and "Identifier" or "Constant",
	})

	table.insert(lines, string.rep("─", 60))

	local content_lines = vim.split(message.content or "", "\n", { plain = true })
	for _, line in ipairs(content_lines) do
		table.insert(lines, line)
	end

	table.insert(lines, "")

	vim.bo[state.bufnr].modifiable = true
	local line_count = vim.api.nvim_buf_line_count(state.bufnr)
	vim.api.nvim_buf_set_lines(state.bufnr, line_count, line_count, false, lines)

	for _, hl in ipairs(highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(state.bufnr, line_count + hl.line, line_count + hl.line + 1, false)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(
			state.bufnr,
			chat_hl_ns,
			line_count + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	if state.auto_scroll and state.visible and state.winid then
		local cursor = vim.api.nvim_win_get_cursor(state.winid)
		local win_height = vim.api.nvim_win_get_height(state.winid)
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		if cursor[1] >= buf_lines - win_height - 1 then
			vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
		end
	end
end

function M.clear()
	chat_todos.close_window()
	state.local_notices = {}
	render_state.reset_chat_surface({ reset_expansions = true })
	state.last_render_time = 0
	state.render_scheduled = false

	if spinner.is_active() then
		spinner.stop()
	end
	stop_spinner_animation_timer()
	chat_tasks.stop_task_animation_timer()
	state.task_anim_frame = 1

	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
		vim.bo[state.bufnr].modifiable = false
	end

	local ok, qs = pcall(require, "opencode.question.state")
	if ok then
		for _, request_id in ipairs(qs.clear_all() or {}) do
			emit("question_removed", { request_id = request_id })
		end
	end
	local ok2, ps = pcall(require, "opencode.permission.state")
	if ok2 then
		for _, permission_id in ipairs(ps.clear_all() or {}) do
			emit("permission_removed", { permission_id = permission_id })
		end
	end
	local ok3, es = pcall(require, "opencode.edit.state")
	if ok3 then
		for _, permission_id in ipairs(es.clear_all() or {}) do
			emit("edit_removed", { permission_id = permission_id })
		end
	end
end

---@param session_id string|nil
function M.clear_session_view(session_id)
	state.local_notices = vim.tbl_filter(function(message)
		if not session_id or session_id == "" then
			return false
		end
		return message.session_id and message.session_id ~= session_id
	end, state.local_notices or {})

	render_state.reset_chat_surface({ reset_expansions = true })
	state.last_render_time = 0
	state.render_scheduled = false

	schedule_render({ force = true })
end

return M
