-- Permission widget lifecycle and handlers for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

local permission_widget = require("opencode.ui.permission_widget")
local widget_base = require("opencode.ui.widget_base")
local permission_state = require("opencode.permission.state")
local widget_support = require("opencode.ui.chat.widget_support")

local function schedule_render()
	require("opencode.ui.chat").schedule_render()
end

-- ─── Pending queue ────────────────────────────────────────────────────────────

function M.process_pending_permissions()
	if #state.pending_permissions == 0 then
		return
	end

	local logger = require("opencode.logger")
	logger.debug("Processing pending permissions", { count = #state.pending_permissions })

	local pending = state.pending_permissions
	state.pending_permissions = {}

	for _, pp in ipairs(pending) do
		local pstate = permission_state.get_permission(pp.permission_id)
		if pstate and pstate.status == "pending" then
			M.add_permission_message(pp.permission_id, pstate, pp.status)
			logger.debug("Displayed pending permission", { permission_id = pp.permission_id })
		else
			logger.debug("Skipping stale pending permission", {
				permission_id = pp.permission_id,
				reason = pstate and pstate.status or "not found",
			})
		end
	end
end

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

	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not state.visible then
		table.insert(state.pending_permissions, {
			permission_id = permission_id,
			perm_data = perm_data,
			status = status,
			timestamp = os.time(),
		})
		logger.debug("Permission queued (chat not visible)", {
			permission_id = permission_id,
			pending_count = #state.pending_permissions,
		})
		return
	end

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

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, p_lines)

	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + #p_lines)
	for _, hl in ipairs(p_highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(
			state.bufnr,
			chat_hl_ns,
			pos.start_line + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	state.permissions[perm_id].end_line = pos.start_line + #p_lines - 1
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

	local client = require("opencode.client")
	client.respond_permission(perm_id, reply, {}, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to respond to permission: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end
			if reply == "reject" then
				permission_state.mark_rejected(perm_id)
				M.update_permission_status(perm_id, "rejected")
			else
				permission_state.mark_approved(perm_id, reply)
				M.update_permission_status(perm_id, "approved")
			end
		end)
	end)
end

function M.handle_permission_reject(perm_id)
	local client = require("opencode.client")
	client.respond_permission(perm_id, "reject", {}, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to reject permission: " .. tostring(err), vim.log.levels.ERROR)
				return
			end
			permission_state.mark_rejected(perm_id)
			M.update_permission_status(perm_id, "rejected")
		end)
	end)
end

return M
