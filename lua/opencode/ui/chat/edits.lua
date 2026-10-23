local cs = require("opencode.ui.chat.state")
return cs.factory("edits", function(view)
-- Edit widget lifecycle and handlers for the chat buffer. The inline diff
-- window manager lives in ui/chat/inline_diff.lua.

local M = {}

local state = view

local edit_widget = require("opencode.ui.edit_widget")
local edit_state = require("opencode.edit.state")
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local inline_diff = cs.module(view, require("opencode.ui.chat.inline_diff"))
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")

local readonly_warning_state = {
	resolve = {},
	diff = {},
}

local READONLY_MESSAGES = {
	resolve = "Readonly edit review does not support manual resolve.",
	diff = "Readonly edit review does not support opening diff editors.",
}

---@param label string
---@param err string|nil
local function notify_edit_action_error(label, err)
	vim.notify("Failed to " .. label .. ": " .. (err or "unknown error"), vim.log.levels.ERROR)
end

local function schedule_render()
	render_coordinator.request({ kind = "edit" })
end

---@param permission_id string
---@param kind "resolve"|"diff"
---@param message string
local function warn_readonly_once(permission_id, kind, message)
	if readonly_warning_state[kind][permission_id] then
		return
	end
	readonly_warning_state[kind][permission_id] = true
	vim.notify(message, vim.log.levels.WARN)
end

---@param permission_id string
local function clear_readonly_warnings(permission_id)
	readonly_warning_state.resolve[permission_id] = nil
	readonly_warning_state.diff[permission_id] = nil
end

---@param edit_id string
function M.refresh_edit(edit_id)
	if not edit_id then
		return false
	end
	if edit_state.are_all_resolved(edit_id) then
		return M.finalize_edit(edit_id)
	else
		M.rerender_edit(edit_id)
		return true
	end
end

-- ─── Inline diff review callbacks ─────────────────────────────────────────────

---The split's file while its review is still pending.
---@param edit_id string|nil
---@param file_index number|nil
---@return table|nil
local function pending_inline_diff_file(edit_id, file_index)
	if not edit_id or not file_index then
		return nil
	end
	local estate = edit_state.get_edit(edit_id)
	if not estate or estate.status ~= "pending" then
		return nil
	end
	local file = estate.files[file_index]
	if not file or file.status ~= "pending" then
		return nil
	end
	return file
end

local INLINE_DIFF_CALLBACKS = {
	confirm = function(edit_id, file_index)
		if not pending_inline_diff_file(edit_id, file_index) then
			return
		end

		local ok, err = edit_state.resolve_file(edit_id, file_index)
		if not ok then
			vim.notify("Failed to confirm file: " .. (err or "unknown"), vim.log.levels.ERROR)
			return
		end

		M.close_inline_diff_split({ silent = true })
		M.refresh_edit(edit_id)
	end,
	reject = function(edit_id, file_index)
		if not pending_inline_diff_file(edit_id, file_index) then
			return
		end

		local reject_ok, reject_err = edit_state.reject_file(edit_id, file_index)
		if not reject_ok then
			vim.notify("Failed to reject file: " .. (reject_err or "unknown"), vim.log.levels.ERROR)
			return
		end

		local actual_buf = inline_diff.actual_buf()
		if actual_buf ~= nil and vim.api.nvim_buf_is_valid(actual_buf) then
			pcall(vim.api.nvim_buf_call, actual_buf, function()
				vim.cmd("silent! edit!")
			end)
		end

		M.close_inline_diff_split({ silent = true })
		M.refresh_edit(edit_id)
	end,
}

-- ─── Cursor query ─────────────────────────────────────────────────────────────

---@param estate table
---@param pos table|nil
---@param widget_line number
---@return number|nil
local function map_widget_line_to_file_index(estate, pos, widget_line)
	if not estate then
		return nil
	end

	local ranges = pos and pos.meta and pos.meta.file_ranges
	if type(ranges) == "table" then
		for _, range in ipairs(ranges) do
			if
				type(range) == "table"
				and type(range.index) == "number"
				and type(range.start_line) == "number"
				and type(range.end_line) == "number"
				and widget_line >= range.start_line
				and widget_line <= range.end_line
			then
				return range.index
			end
		end
		return nil
	end

	return nil
end

---@return string|nil, table|nil, table|nil, number|nil
local function get_edit_context_at_cursor(allow_sent)
	return widget_support.context_at_cursor(state.edits, edit_state.get_edit, function(status)
		return status == "pending" or (allow_sent and status == "sent")
	end)
end

local function get_pending_edit_context_at_cursor()
	return get_edit_context_at_cursor(false)
end

---@return string|nil, table|nil, table|nil, number|nil
local function get_diffable_edit_context_at_cursor()
	return get_edit_context_at_cursor(true)
end

---@return string|nil permission_id
function M.get_edit_at_cursor()
	local eid = get_pending_edit_context_at_cursor()
	return eid
end

---@return string|nil permission_id
function M.get_diffable_edit_at_cursor()
	local eid = get_diffable_edit_context_at_cursor()
	return eid
end

---@return string|nil edit_id
---@return boolean changed
function M.sync_selected_file_from_cursor()
	local eid, estate, pos, cursor_line = get_pending_edit_context_at_cursor()
	if not eid or not estate or not pos or not cursor_line then
		return nil, false
	end

	local widget_line = cursor_line - pos.start_line
	local file_index = map_widget_line_to_file_index(estate, pos, widget_line)
	if not file_index or file_index == estate.selected_file then
		return eid, false
	end

	if not edit_state.move_selection_to(eid, file_index) then
		return eid, false
	end

	M.rerender_edit(eid)
	return eid, true
end

-- ─── In-place re-render ───────────────────────────────────────────────────────

---Unlike questions and permissions, edits only refresh pos.meta here: their
---position keeps its rendered status and no interactive meta snapshot.
---@param edit_id string permission_id
function M.rerender_edit(edit_id)
	local pos, _, replaced, meta = widget_support.rerender_widget(state.edits, edit_id, edit_state.get_edit, edit_widget.render)
	if replaced then
		pos.meta = meta
	end
end

-- ─── Finalize ─────────────────────────────────────────────────────────────────

---@param permission_id string
function M.finalize_edit(permission_id)
	local estate = edit_state.get_edit(permission_id)
	if not estate or estate.transport ~= "review_rpc" then return false end
	local pending = require("opencode.session.pending")
	local token = pending.token(estate.session_id)

	local function on_reply(err)
		vim.schedule(function()
			if not pending.is_current(token) or edit_state.get_edit(permission_id) ~= estate then return end
			if err then
				vim.notify("Failed to send edit reply: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end
			clear_readonly_warnings(permission_id)
			edit_state.mark_sent(permission_id)
			schedule_render()
		end)
	end
	return actions.reply_review(permission_id, on_reply)
end

---@param edit_id string
---@param file_index number Selected pending file (checked by with_selected_file)
---@param action fun(permission_id: string, file_index: number): boolean, string|nil
---@param error_label string
---@return boolean
local function apply_edit_file_action(edit_id, file_index, action, error_label)
	local ok, err = action(edit_id, file_index)
	if not ok then
		notify_edit_action_error(error_label, err)
		return false
	end

	M.refresh_edit(edit_id)
	return true
end

---@param edit_id string
---@param action fun(permission_id: string): boolean, string|nil, table[]|nil
---@param error_label string
---@return boolean
local function apply_edit_batch_action(edit_id, action, error_label)
	local ok, err = action(edit_id)
	if not ok then
		notify_edit_action_error(error_label, err)
		M.rerender_edit(edit_id)
		return false
	end

	M.refresh_edit(edit_id)
	return true
end

-- ─── File handlers ────────────────────────────────────────────────────────────

---Shared handler preamble: sync the selected file from the cursor, then find
---the pending review at the cursor. A readonly review is refused with a
---one-time warning when `readonly_warn` names the warning kind; `pending_file`
---also requires the selected file to be pending and passes it to `fn`.
---@param fn fun(edit_id: string, estate: table, file: table|nil)
---@param opts? { readonly_warn?: "resolve"|"diff", pending_file?: boolean }
local function with_selected_file(fn, opts)
	opts = opts or {}
	M.sync_selected_file_from_cursor()

	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	if opts.readonly_warn and edit_state.is_readonly(eid) then
		warn_readonly_once(eid, opts.readonly_warn, READONLY_MESSAGES[opts.readonly_warn])
		return
	end

	local file
	if opts.pending_file then
		file = estate.files[estate.selected_file]
		if not file or file.status ~= "pending" then
			return
		end
	end
	fn(eid, estate, file)
end

function M.handle_edit_accept_file()
	with_selected_file(function(eid, estate)
		if edit_state.is_readonly(eid) then
			apply_edit_batch_action(eid, edit_state.accept_all, "accept edit")
			return
		end
		apply_edit_file_action(eid, estate.selected_file, edit_state.accept_file, "accept file")
	end, { pending_file = true })
end

function M.handle_edit_reject_file()
	with_selected_file(function(eid, estate)
		if edit_state.is_readonly(eid) then
			apply_edit_batch_action(eid, edit_state.reject_all, "reject edit")
			return
		end
		apply_edit_file_action(eid, estate.selected_file, edit_state.reject_file, "reject file")
	end, { pending_file = true })
end

function M.handle_edit_accept_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	apply_edit_batch_action(eid, edit_state.accept_all, "accept edit")
end

function M.handle_edit_reject_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	apply_edit_batch_action(eid, edit_state.reject_all, "reject edit")
end

function M.handle_edit_resolve_file()
	with_selected_file(function(eid, estate)
		apply_edit_file_action(eid, estate.selected_file, edit_state.resolve_file, "resolve file")
	end, { readonly_warn = "resolve", pending_file = true })
end

function M.handle_edit_resolve_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	if edit_state.is_readonly(eid) then
		warn_readonly_once(eid, "resolve", READONLY_MESSAGES.resolve)
		return
	end
	apply_edit_batch_action(eid, edit_state.resolve_all, "resolve edit")
end

function M.handle_edit_message()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate or estate.status ~= "pending" or estate.submitting then
		return
	end

	local input_ui = require("opencode.ui.input")
	local chat = cs.module(view, require("opencode.ui.chat"))
	local pending = require("opencode.session.pending")
	local token = pending.token(estate.session_id)
	local generation = view.generation

	local function finish(text)
		if not cs.valid(view, generation) or not pending.is_current(token) or edit_state.get_edit(eid) ~= estate then return end
		if not edit_state.set_message(eid, text or "") then return end
		M.rerender_edit(eid)
		chat.focus()
	end

	input_ui.show({
		view = view,
		winid = state.winid,
		float_dims = state.float_dims,
		text = estate.message or "",
		persist_pending = false,
		add_history = false,
		on_send = finish,
		on_cancel = finish,
	})
end

function M.handle_edit_toggle_diff()
	local eid, estate, pos, cursor_line = get_diffable_edit_context_at_cursor()
	if not eid or not estate or not pos or not cursor_line then
		return
	end

	local widget_line = cursor_line - pos.start_line
	local file_index = map_widget_line_to_file_index(estate, pos, widget_line)
	if file_index then
		edit_state.set_selection(eid, file_index)
	end
	edit_state.toggle_inline_diff(eid, estate.selected_file)
	M.rerender_edit(eid)
end

-- ─── Diff viewers ─────────────────────────────────────────────────────────────

---@param eid string
---@param estate table
local function open_diff_tab(eid, estate)
	local files = {}
	local start_index = nil
	for index, file in ipairs(estate.files or {}) do
		if file.status == "pending" then
			table.insert(files, {
				filePath = file.filepath,
				relativePath = file.relative_path,
				before = file.before,
				after = file.after,
				type = file.file_type,
				edit_file_index = index,
			})
			if index == estate.selected_file then
				start_index = #files
			end
		end
	end
	if #files == 0 then
		vim.notify("No pending files to review in diff", vim.log.levels.INFO)
		return
	end

	local input = require("opencode.ui.input")
	local input_had_focus = input.is_visible()
		and vim.tbl_contains(input.get_winids(), vim.api.nvim_get_current_win())
	local native_diff = require("opencode.ui.native_diff")
	native_diff.show(files, {
		view = view,
		-- Pass back-reference so the diff tab can sync status to the chat widget
		edit_id = eid,
		file_index = estate.selected_file,
		start_index = start_index or 1,
		-- native_diff only restores the previous window; return to the chat when
		-- that window is gone, and to the input only if it had focus at open.
		on_close = function(ctx)
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if not chat_ok then return end
			if not ctx.restored and (view.visible or view.suspended) then
				chat.focus_view(view)
			end
			chat = cs.module(view, chat)
			if input_had_focus and chat.is_visible() then
				chat.focus_input()
			end
		end,
	})
end

function M.handle_edit_diff_tab()
	with_selected_file(open_diff_tab, { readonly_warn = "diff" })
end

function M.handle_edit_diff_split()
	with_selected_file(function(eid, estate)
		local file = estate.files[estate.selected_file]
		if not file then
			return
		end
		M.open_inline_diff_split(file, {
			edit_id = eid,
			file_index = estate.selected_file,
		})
	end, { readonly_warn = "diff" })
end

--- Check whether a window belongs to the OpenCode inline diff split.
---@param winid number|nil
---@return boolean
function M.is_inline_diff_window(winid)
	return inline_diff.is_window(winid)
end

--- Close the active OpenCode inline diff split (if any).
---@param opts? table { check_unsaved?: boolean, unsaved_message?: string, silent?: boolean, preserve_actual?: boolean }
---@return boolean ok Whether dismissal was allowed (false for unsaved changes).
---@return string|nil err Refusal or first cleanup error; may accompany true.
---@return number|nil reusable_win
---@return number|nil reusable_buf
function M.close_inline_diff_split(opts)
	return inline_diff.close(opts)
end

---Open a vertical diff split near chat for a single file.
---@param file table  File entry from edit state
---@param opts? table { edit_id?: string, file_index?: number }
function M.open_inline_diff_split(file, opts)
	return inline_diff.open(file, opts, INLINE_DIFF_CALLBACKS)
end

return M

end)
