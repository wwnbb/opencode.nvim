local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

local spinner = require("opencode.ui.spinner")
local chat_todos = require("opencode.ui.chat.todos")
local chat_tasks = require("opencode.ui.chat.tasks")
local render_state = require("opencode.ui.chat.render_state")
local events = require("opencode.events")

local schedule_render = function() end

function M.set_schedule_render(fn)
	schedule_render = type(fn) == "function" and fn or function() end
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
		schedule_render({ force = true })
	end
	return message.id
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
			events.safe_emit("question_removed", { request_id = request_id })
		end
	end
	local ok2, ps = pcall(require, "opencode.permission.state")
	if ok2 then
		for _, permission_id in ipairs(ps.clear_all() or {}) do
			events.safe_emit("permission_removed", { permission_id = permission_id })
		end
	end
	local ok3, es = pcall(require, "opencode.edit.state")
	if ok3 then
		for _, permission_id in ipairs(es.clear_all() or {}) do
			events.safe_emit("edit_removed", { permission_id = permission_id })
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
