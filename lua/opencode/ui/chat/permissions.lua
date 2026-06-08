-- Permission widget lifecycle and handlers for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

local permission_widget = require("opencode.ui.permission_widget")
local widget_base = require("opencode.ui.widget_base")
local permission_state = require("opencode.permission.state")
local widget_support = require("opencode.ui.chat.widget_support")
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local render = require("opencode.ui.chat.render")
local actions = require("opencode.actions")

local function schedule_render()
	render_coordinator.request({ kind = "permission" })
end

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

-- ─── Pending queue ────────────────────────────────────────────────────────────

function M.process_pending_permissions() end

-- ─── Add / update ─────────────────────────────────────────────────────────────

---@param permission_id string
---@param perm_data table  (kept for API compatibility, unused)
---@param status "pending" | "approved" | "rejected"
function M.add_permission_message(permission_id, perm_data, status)
	local logger = require("opencode.logger")

	logger.debug("add_permission_message called", {
		permission_id = permission_id,
		visible = state.visible,
	})

	local pstate = permission_state.get_permission(permission_id)
	if not pstate then
		logger.warn("Permission state not found", { permission_id = permission_id })
		return
	end

	widget_support.request_focus("permission", permission_id, status)

	schedule_render()
end

---@param permission_id string
---@param status "approved" | "rejected"
function M.update_permission_status(permission_id, status)
	local logger = require("opencode.logger")
	logger.debug("update_permission_status: triggering re-render", {
		permission_id = permission_id,
		status = status,
	})
	schedule_render()
end

-- ─── Cursor query ─────────────────────────────────────────────────────────────

---@return string|nil permission_id
---@return table|nil pstate
---@return table|nil pos
---@return number|nil cursor_line
local function get_pending_permission_context_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil, nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1

	for permission_id, pos in pairs(state.permissions) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line and pos.status == "pending" then
			local pstate = permission_state.get_permission(permission_id)
			if pstate and pstate.status == "pending" then
				return permission_id, pstate, pos, cursor_line
			end
		end
	end

	return nil, nil, nil, nil
end

---@return string|nil permission_id
---@return table|nil perm_state
function M.get_permission_at_cursor()
	local permission_id, pstate = get_pending_permission_context_at_cursor()
	return permission_id, pstate
end

---@return string|nil permission_id
---@return boolean changed
function M.sync_selected_option_from_cursor()
	local permission_id, pstate, pos, cursor_line = get_pending_permission_context_at_cursor()
	if not permission_id or not pstate or not pos or not cursor_line then
		return nil, false
	end

	local _, _, meta = permission_widget.get_lines_for_permission(permission_id, pstate)
	local option_count = meta and meta.interactive_count or 0
	local first_option_line = widget_base.get_focus_offset(meta)
	if option_count <= 0 or first_option_line == nil then
		return permission_id, false
	end

	local widget_line = cursor_line - pos.start_line
	if widget_line < first_option_line or widget_line >= (first_option_line + option_count) then
		return permission_id, false
	end

	local option_index = widget_line - first_option_line + 1
	if pstate.selected_option == option_index then
		return permission_id, false
	end

	if not permission_state.select_option(permission_id, option_index) then
		return permission_id, false
	end

	emit("permission_selection_changed", {
		permission_id = permission_id,
		selected = option_index,
	})
	emit("interaction_changed", {
		kind = "permission",
		action = "selection_changed",
		id = permission_id,
	})
	M.rerender_permission(permission_id)
	return permission_id, true
end

-- ─── In-place re-render ───────────────────────────────────────────────────────

---@param perm_id string
function M.rerender_permission(perm_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.permissions[perm_id]
	if not pos then
		return
	end

	local pstate = permission_state.get_permission(perm_id)
	if not pstate then
		return
	end

	local p_lines, p_highlights = permission_widget.get_lines_for_permission(perm_id, pstate)
	local old_end = pos.end_line
	local old_count = old_end - pos.start_line + 1
	local new_count = #p_lines
	local delta = new_count - old_count

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, p_lines)
	local clear_end = pos.start_line + math.max(old_count, new_count)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, clear_end)
	render.apply_extmark_highlights(state.bufnr, chat_hl_ns, p_highlights, pos.start_line)

	vim.bo[state.bufnr].modifiable = false

	widget_support.shift_tracked_lines(old_end, delta)
	state.permissions[perm_id].end_line = pos.start_line + #p_lines - 1
	state.permissions[perm_id].highlights = p_highlights
end

-- ─── Handlers ─────────────────────────────────────────────────────────────────

function M.handle_permission_confirm(perm_id, pstate)
	local selected = pstate.selected_option or 1
	local reply
	if selected == 1 then
		reply = "once"
	elseif selected == 2 then
		reply = "always"
	else
		reply = "reject"
	end

	local message = vim.trim((pstate and pstate.message) or "")
	actions.respond_permission(perm_id, reply, { message = message ~= "" and message or nil }, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to respond to permission: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end
			if reply == "reject" then
				permission_state.mark_rejected(perm_id)
				emit("permission_rejected", {
					permission_id = perm_id,
				})
				M.update_permission_status(perm_id, "rejected")
			else
				permission_state.mark_approved(perm_id, reply)
				emit("permission_approved", {
					permission_id = perm_id,
					reply = reply,
				})
				M.update_permission_status(perm_id, "approved")
			end
			emit("interaction_changed", {
				kind = "permission",
				action = reply == "reject" and "rejected" or "approved",
				id = perm_id,
			})
		end)
	end)
end

function M.handle_permission_reject(perm_id)
	local pstate = permission_state.get_permission(perm_id)
	local message = vim.trim((pstate and pstate.message) or "")
	actions.respond_permission(perm_id, "reject", { message = message ~= "" and message or nil }, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to reject permission: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			permission_state.mark_rejected(perm_id)
			emit("permission_rejected", {
				permission_id = perm_id,
			})
			emit("interaction_changed", {
				kind = "permission",
				action = "rejected",
				id = perm_id,
			})
			M.update_permission_status(perm_id, "rejected")
		end)
	end)
end

---@param perm_id string
function M.handle_permission_message(perm_id)
	local pstate = permission_state.get_permission(perm_id)
	if not pstate or pstate.status ~= "pending" then
		return
	end

	local input_ui = require("opencode.ui.input")
	local chat = require("opencode.ui.chat")

	local function finish(text)
		permission_state.set_message(perm_id, text or "")
		M.rerender_permission(perm_id)
		chat.focus()
	end

	input_ui.show({
		winid = state.winid,
		float_dims = state.float_dims,
		text = pstate.message or "",
		persist_pending = false,
		add_history = false,
		on_send = finish,
		on_cancel = finish,
	})
end

return M
