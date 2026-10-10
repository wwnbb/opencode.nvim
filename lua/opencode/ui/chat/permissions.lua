-- Permission widget lifecycle and handlers for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

local permission_widget = require("opencode.ui.permission_widget")
local widget_base = require("opencode.ui.widget_base")
local permission_state = require("opencode.permission.state")
local pending = require("opencode.session.pending")
local widget_support = require("opencode.ui.chat.widget_support")
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")
local events = require("opencode.events")

local function schedule_render()
	render_coordinator.request({ kind = "permission" })
end

-- ─── Add / update ─────────────────────────────────────────────────────────────

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
	local permission_id, pos = widget_support.find_widget_context_at_cursor(state.permissions, state.winid, function(pos)
		return pos.status == "pending"
	end)
	if not permission_id or not pos then
		return nil, nil, nil, nil
	end
	local pstate = permission_state.get_permission(permission_id)
	if not pstate or pstate.status ~= "pending" then
		return nil, nil, nil, nil
	end
	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1
	return permission_id, pstate, pos, cursor_line
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

	local meta = widget_support.get_interactive_meta(pos, pstate, "permission")
	if not pos.meta_state then
		local _, _, fallback = permission_widget.get_lines_for_permission(permission_id, pstate)
		meta = fallback
	end
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

	events.safe_emit("permission_selection_changed", {
		permission_id = permission_id,
		selected = option_index,
	})
	events.safe_emit("interaction_changed", {
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

	local p_lines, p_highlights, p_meta
	local status = pstate.status or "pending"
	if status == "approved" then
		p_lines, p_highlights = permission_widget.get_approved_lines(perm_id, pstate)
	elseif status == "rejected" then
		p_lines, p_highlights = permission_widget.get_rejected_lines(perm_id, pstate)
	else
		p_lines, p_highlights, p_meta = permission_widget.get_lines_for_permission(perm_id, pstate)
	end

	if widget_support.replace_rendered_block(pos, { lines = p_lines, highlights = p_highlights }) then
		pos.status = status
		widget_support.set_interactive_meta(pos, p_meta or widget_base.make_meta(), pstate, "permission")
	end
end

-- ─── Handlers ─────────────────────────────────────────────────────────────────

local function respond_permission(perm_id, pstate, reply)
	if not pstate or permission_state.get_permission(perm_id) ~= pstate or pstate.status ~= "pending" then return end
	local token = pending.token(pstate.session_id)
	local message = vim.trim(pstate.message or "")
	actions.respond_permission(perm_id, reply, { message = message ~= "" and message or nil }, function(err)
		vim.schedule(function()
			if not pending.is_current(token) or permission_state.get_permission(perm_id) ~= pstate or pstate.status ~= "pending" then return end
			if err then
				vim.notify("Failed to respond to permission: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end
			if reply == "reject" then
				if not permission_state.mark_rejected(perm_id) then return end
				events.safe_emit("permission_rejected", {
					permission_id = perm_id,
				})
				M.update_permission_status(perm_id, "rejected")
			else
				if not permission_state.mark_approved(perm_id, reply) then return end
				events.safe_emit("permission_approved", {
					permission_id = perm_id,
					reply = reply,
				})
				M.update_permission_status(perm_id, "approved")
			end
			events.safe_emit("interaction_changed", {
				kind = "permission",
				action = reply == "reject" and "rejected" or "approved",
				id = perm_id,
			})
		end)
	end)
end

function M.handle_permission_confirm(perm_id, pstate)
	if not pstate then return end
	local selected = pstate.selected_option or 1
	local reply
	if selected == 1 then
		reply = "once"
	elseif selected == 2 and #(pstate.always or {}) > 0 then
		reply = "always"
	else
		reply = "reject"
	end
	respond_permission(perm_id, pstate, reply)
end

function M.handle_permission_reject(perm_id)
	respond_permission(perm_id, permission_state.get_permission(perm_id), "reject")
end

---@param perm_id string
function M.handle_permission_message(perm_id)
	local pstate = permission_state.get_permission(perm_id)
	if not pstate or pstate.status ~= "pending" then
		return
	end

	local input_ui = require("opencode.ui.input")
	local chat = require("opencode.ui.chat")
	local token = pending.token(pstate.session_id)

	local function finish(text)
		if not pending.is_current(token) or permission_state.get_permission(perm_id) ~= pstate or pstate.status ~= "pending" or pstate.submitting then return end
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
