-- Edit widget lifecycle, handlers, and diff utilities for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

local edit_widget = require("opencode.ui.edit_widget")
local edit_state = require("opencode.edit.state")

local INLINE_DIFF_WIN_VAR = "opencode_inline_diff_split"

local inline_diff_state = {
	active = false,
	actual_win = nil,
	actual_buf = nil,
	proposed_win = nil,
	proposed_buf = nil,
	edit_id = nil,
	file_index = nil,
}

local readonly_warning_state = {
	resolve = {},
	diff = {},
}

---@param winid number|nil
---@return boolean
local function is_valid_window(winid)
	return winid ~= nil and vim.api.nvim_win_is_valid(winid)
end

---@param bufnr number|nil
---@return boolean
local function is_valid_buffer(bufnr)
	return bufnr ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

local function reset_inline_diff_state()
	inline_diff_state.active = false
	inline_diff_state.actual_win = nil
	inline_diff_state.actual_buf = nil
	inline_diff_state.proposed_win = nil
	inline_diff_state.proposed_buf = nil
	inline_diff_state.edit_id = nil
	inline_diff_state.file_index = nil
end

---@return boolean
local function is_inline_diff_state_valid()
	if not inline_diff_state.active then
		return false
	end
	if not is_valid_window(inline_diff_state.actual_win) or not is_valid_window(inline_diff_state.proposed_win) then
		return false
	end
	if not is_valid_buffer(inline_diff_state.actual_buf) or not is_valid_buffer(inline_diff_state.proposed_buf) then
		return false
	end
	if vim.api.nvim_win_get_buf(inline_diff_state.actual_win) ~= inline_diff_state.actual_buf then
		return false
	end
	if vim.api.nvim_win_get_buf(inline_diff_state.proposed_win) ~= inline_diff_state.proposed_buf then
		return false
	end
	return true
end

local function ensure_inline_diff_state()
	if not inline_diff_state.active then
		return
	end
	if is_inline_diff_state_valid() then
		return
	end
	reset_inline_diff_state()
end

---@param winid number
local function mark_inline_diff_window(winid)
	if not is_valid_window(winid) then
		return
	end
	pcall(vim.api.nvim_win_set_var, winid, INLINE_DIFF_WIN_VAR, true)
end

---@param winid number|nil
local function clear_inline_diff_mark(winid)
	if not is_valid_window(winid) then
		return
	end
	if not pcall(vim.api.nvim_win_del_var, winid, INLINE_DIFF_WIN_VAR) then
		pcall(vim.api.nvim_win_set_var, winid, INLINE_DIFF_WIN_VAR, false)
	end
end

---@param winid number|nil
local function disable_diff_on_window(winid)
	if not is_valid_window(winid) then
		return
	end
	pcall(vim.api.nvim_win_call, winid, function()
		vim.cmd("diffoff!")
	end)
end

---@param winid number|nil
---@return boolean
local function is_inline_diff_window_marked(winid)
	if not is_valid_window(winid) then
		return false
	end
	local ok, marked = pcall(vim.api.nvim_win_get_var, winid, INLINE_DIFF_WIN_VAR)
	return ok and marked == true
end

---@return number[]
local function list_marked_inline_diff_windows()
	local wins = {}
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if is_inline_diff_window_marked(winid) then
			table.insert(wins, winid)
		end
	end
	return wins
end

---@param wins number[]
---@return number|nil, number|nil
local function find_actual_from_marked_windows(wins)
	for _, winid in ipairs(wins) do
		if is_valid_window(winid) then
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if is_valid_buffer(bufnr) and vim.bo[bufnr].buftype ~= "nofile" then
				return winid, bufnr
			end
		end
	end
	for _, winid in ipairs(wins) do
		if is_valid_window(winid) then
			local bufnr = vim.api.nvim_win_get_buf(winid)
			if is_valid_buffer(bufnr) then
				return winid, bufnr
			end
		end
	end
	return nil, nil
end

---@param winid number|nil
---@param force boolean
---@return boolean, string|nil
local function close_window(winid, force)
	if not is_valid_window(winid) then
		return true
	end
	local ok, err = pcall(vim.api.nvim_win_close, winid, force)
	if ok then
		return true
	end
	return false, tostring(err)
end

---@param err string|nil
---@return boolean
local function is_last_window_close_error(err)
	return type(err) == "string" and err:match("E444") ~= nil
end

---@param winid number|nil
---@return number|nil, number|nil, string|nil
local function normalize_surviving_inline_diff_window(winid)
	if not is_valid_window(winid) then
		return nil, nil, nil
	end

	local bufnr = vim.api.nvim_win_get_buf(winid)
	local is_scratch = is_valid_buffer(bufnr) and vim.bo[bufnr].buftype == "nofile"

	clear_inline_diff_mark(winid)
	disable_diff_on_window(winid)

	if not is_scratch then
		if is_valid_buffer(bufnr) then
			return winid, bufnr, nil
		end
		return nil, nil, nil
	end

	local ok_close, err = close_window(winid, true)
	if ok_close then
		if is_valid_buffer(bufnr) then
			pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
		end
		return nil, nil, nil
	end

	if is_last_window_close_error(err) then
		local old_buf = bufnr
		local ok_new, new_err = pcall(vim.api.nvim_win_call, winid, function()
			vim.cmd("enew")
		end)
		if ok_new then
			if is_valid_buffer(old_buf) then
				pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
			end
			return nil, nil, nil
		end
		return nil, nil, tostring(new_err)
	end

	return nil, nil, err
end

---@param winid number
---@param option string
---@return any
local function get_window_option(winid, option)
	local ok, value = pcall(function()
		return vim.wo[winid][option]
	end)
	if ok then
		return value
	end
	return nil
end

---@param path string|nil
---@return string
local function normalize_path(path)
	if not path or path == "" then
		return ""
	end
	return vim.fn.fnamemodify(path, ":p")
end

---@param winid number|nil
---@return boolean
local function is_usable_anchor_window(winid)
	if not is_valid_window(winid) then
		return false
	end
	if state.winid and winid == state.winid then
		return false
	end
	if is_inline_diff_window_marked(winid) then
		return false
	end
	if get_window_option(winid, "previewwindow") then
		return false
	end
	if get_window_option(winid, "winfixwidth") then
		return false
	end
	if get_window_option(winid, "winfixbuf") then
		return false
	end

	local bufnr = vim.api.nvim_win_get_buf(winid)
	if not is_valid_buffer(bufnr) then
		return false
	end

	local buftype = vim.bo[bufnr].buftype
	if buftype == "nofile" or buftype == "help" or buftype == "quickfix" or buftype == "terminal" or buftype == "prompt" then
		return false
	end

	local ft = vim.bo[bufnr].filetype or ""
	if ft:match("^opencode") then
		return false
	end
	if ft == "gitrebase" or ft == "gitcommit" then
		return false
	end
	if ft == "NvimTree" or ft:match("^neo%-tree") then
		return false
	end

	return true
end

---@return number|nil
local function find_anchor_window()
	local seen = {}
	local ordered = {}
	local alt_winnr = vim.fn.winnr("#")
	if alt_winnr and alt_winnr > 0 then
		table.insert(ordered, alt_winnr)
	end
	local max_winnr = vim.fn.winnr("$")
	for nr = 1, max_winnr do
		table.insert(ordered, nr)
	end

	for _, nr in ipairs(ordered) do
		if not seen[nr] then
			seen[nr] = true
			local winid = vim.fn.win_getid(nr)
			if is_usable_anchor_window(winid) then
				return winid
			end
		end
	end

	local current = vim.api.nvim_get_current_win()
	if is_usable_anchor_window(current) then
		return current
	end
	return nil
end

---@return number
local function create_fallback_anchor_window()
	vim.cmd("belowright new")
	local winid = vim.api.nvim_get_current_win()
	local bufnr = vim.api.nvim_get_current_buf()
	vim.bo[bufnr].bufhidden = "delete"
	return winid
end

---@param anchor_win number
---@param filepath string
---@return boolean, number|string
local function ensure_actual_file_window(anchor_win, filepath)
	if not is_valid_window(anchor_win) then
		return false, "Invalid target window"
	end

	local target_abs = normalize_path(filepath)
	local current_buf = vim.api.nvim_win_get_buf(anchor_win)
	local current_abs = normalize_path(vim.api.nvim_buf_get_name(current_buf))

	if current_abs ~= target_abs then
		if vim.bo[current_buf].modified then
			return false, "Save or discard changes in the current file window before opening diff split."
		end
		local ok, err = pcall(vim.api.nvim_win_call, anchor_win, function()
			vim.cmd("edit " .. vim.fn.fnameescape(filepath))
		end)
		if not ok then
			return false, "Failed to open file for diff split: " .. tostring(err)
		end
	end

	return true, vim.api.nvim_win_get_buf(anchor_win)
end

local function schedule_render()
	require("opencode.ui.chat").schedule_render()
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

---@param filepath string
---@param content string
---@return boolean, string|nil
local function write_file(filepath, content)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	if dir and dir ~= "" then
		vim.fn.mkdir(dir, "p")
	end

	local fd, err = io.open(filepath, "w")
	if not fd then
		return false, err
	end

	local ok, write_err = pcall(function()
		fd:write(content)
	end)
	fd:close()
	if not ok then
		return false, tostring(write_err)
	end

	return true
end

---@return string|nil, number|nil, table|nil, table|nil
local function get_inline_diff_edit_context()
	local edit_id = inline_diff_state.edit_id
	local file_index = inline_diff_state.file_index
	if not edit_id or not file_index then
		return nil, nil, nil, nil
	end

	local estate = edit_state.get_edit(edit_id)
	if not estate or estate.status ~= "pending" then
		return edit_id, file_index, nil, nil
	end

	return edit_id, file_index, estate, estate.files[file_index]
end

---@param edit_id string
local function refresh_inline_diff_edit(edit_id)
	if edit_state.are_all_resolved(edit_id) then
		M.finalize_edit(edit_id)
	else
		M.rerender_edit(edit_id)
	end
end

local function confirm_inline_diff_file()
	local edit_id, file_index, _, file = get_inline_diff_edit_context()
	if not edit_id or not file_index or not file or file.status ~= "pending" then
		return
	end

	if is_valid_window(inline_diff_state.actual_win) then
		vim.api.nvim_win_call(inline_diff_state.actual_win, function()
			vim.cmd("silent! write")
		end)
	end

	local ok, err = edit_state.resolve_file(edit_id, file_index)
	if not ok then
		vim.notify("Failed to confirm file: " .. (err or "unknown"), vim.log.levels.ERROR)
		return
	end

	M.close_inline_diff_split({ silent = true })
	refresh_inline_diff_edit(edit_id)
end

local function reject_inline_diff_file()
	local edit_id, file_index, _, file = get_inline_diff_edit_context()
	if not edit_id or not file_index or not file or file.status ~= "pending" then
		return
	end

	local filepath = file.filepath
	local before = file.before or ""
	local file_type = file.file_type or "update"
	local ok = true
	local err

	if file_type == "add" and before == "" then
		if vim.fn.filereadable(filepath) == 1 then
			ok, err = os.remove(filepath)
		end
	else
		ok, err = write_file(filepath, before)
	end

	if not ok then
		vim.notify("Failed to reject file: " .. tostring(err or "unknown"), vim.log.levels.ERROR)
		return
	end

	if is_valid_buffer(inline_diff_state.actual_buf) then
		pcall(vim.api.nvim_buf_call, inline_diff_state.actual_buf, function()
			vim.cmd("silent! edit!")
		end)
	end

	local reject_ok, reject_err = edit_state.reject_file(edit_id, file_index)
	if not reject_ok then
		vim.notify("Failed to reject file: " .. (reject_err or "unknown"), vim.log.levels.ERROR)
		return
	end

	M.close_inline_diff_split({ silent = true })
	refresh_inline_diff_edit(edit_id)
end

local function apply_inline_diff_hunks()
	if not is_valid_window(inline_diff_state.actual_win) then
		return
	end

	vim.api.nvim_set_current_win(inline_diff_state.actual_win)
	pcall(function()
		vim.cmd("%diffget")
	end)
end

local function show_inline_diff_help()
	local help = {
		"Diff Split Keymaps:",
		"",
		"  do       - Obtain hunk from proposed (LEFT) into actual (RIGHT)",
		"  dp       - Put hunk from actual (RIGHT) to proposed (LEFT)",
		"  ]c       - Jump to next change",
		"  [c       - Jump to previous change",
		"  <C-y>    - Apply ALL remaining proposed hunks at once",
		"  <C-a>    - Save file as-is and resolve it in the edit widget",
		"  <C-s>    - Same as <C-a>",
		"  <C-x>    - Reject current file and restore the original content",
		"  q        - Close the diff split",
		"  ?        - Show this help",
		"",
		"Tip: use <C-y> to apply all proposed changes, then <C-a> to confirm.",
	}
	vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
end

-- ─── Pending queue ────────────────────────────────────────────────────────────

function M.process_pending_edits()
	if #state.pending_edits == 0 then
		return
	end

	local logger = require("opencode.logger")
	logger.debug("Processing pending edits", { count = #state.pending_edits })

	local pending = state.pending_edits
	state.pending_edits = {}

	for _, pe in ipairs(pending) do
		local estate = edit_state.get_edit(pe.permission_id)
		if estate and estate.status == "pending" then
			M.add_edit_message(pe.permission_id, estate, pe.status)
			logger.debug("Displayed pending edit", { permission_id = pe.permission_id })
		else
			logger.debug("Skipping stale pending edit", {
				permission_id = pe.permission_id,
				reason = estate and estate.status or "not found",
			})
		end
	end
end

-- ─── Add ─────────────────────────────────────────────────────────────────────

---@param permission_id string
---@param edit_data table
---@param status "pending" | "sent"
function M.add_edit_message(permission_id, edit_data, status)
	local logger = require("opencode.logger")

	logger.debug("add_edit_message called", {
		permission_id = permission_id,
		visible = state.visible,
	})

	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not state.visible then
		table.insert(state.pending_edits, {
			permission_id = permission_id,
			edit_data = edit_data,
			status = status,
			timestamp = os.time(),
		})
		logger.debug("Edit queued (chat not visible)", {
			permission_id = permission_id,
			pending_count = #state.pending_edits,
		})
		return
	end

	local estate = edit_state.get_edit(permission_id)
	if not estate then
		logger.warn("Edit state not found", { permission_id = permission_id })
		return
	end

	if status == "pending" then
		state.focus_edit = permission_id
	end

	schedule_render()
end

-- ─── Cursor query ─────────────────────────────────────────────────────────────

---@param estate table
---@param widget_line number
---@return number|nil
local function map_widget_line_to_file_index(estate, widget_line)
	if not estate or estate.status ~= "pending" then
		return nil
	end

	if widget_line < 2 then
		return nil
	end

	local line = 2
	for i, file in ipairs(estate.files or {}) do
		local block_start = line
		line = line + 1

		local diff_lines = file.diff_lines or {}
		if estate.expanded_files and estate.expanded_files[i] and #diff_lines > 0 then
			line = line + #diff_lines
		end

		local block_end = line - 1
		if widget_line >= block_start and widget_line <= block_end then
			return i
		end
	end

	return nil
end

---@return string|nil, table|nil, table|nil, number|nil
local function get_pending_edit_context_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil, nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1

	for eid, pos in pairs(state.edits) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line and pos.status == "pending" then
			local estate = edit_state.get_edit(eid)
			if estate and estate.status == "pending" then
				return eid, estate, pos, cursor_line
			end
		end
	end

	return nil, nil, nil, nil
end

---@return string|nil permission_id
function M.get_edit_at_cursor()
	local eid = get_pending_edit_context_at_cursor()
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
	local file_index = map_widget_line_to_file_index(estate, widget_line)
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

---@param edit_id string permission_id
function M.rerender_edit(edit_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.edits[edit_id]
	if not pos then
		return
	end

	local estate = edit_state.get_edit(edit_id)
	if not estate then
		return
	end

	local e_lines, e_highlights
	if estate.status == "sent" then
		e_lines, e_highlights = edit_widget.get_resolved_lines(edit_id, estate)
	else
		e_lines, e_highlights = edit_widget.get_lines_for_edit(edit_id, estate)
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, e_lines)

	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + #e_lines)
	for _, hl in ipairs(e_highlights) do
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
		pcall(
			vim.api.nvim_buf_set_extmark,
			state.bufnr,
			chat_hl_ns,
			pos.start_line + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	state.edits[edit_id].end_line = pos.start_line + #e_lines - 1
end

-- ─── Finalize ─────────────────────────────────────────────────────────────────

---@param permission_id string
function M.finalize_edit(permission_id)
	local estate = edit_state.get_edit(permission_id)
	if not estate then
		return
	end

	local resolution = edit_state.get_resolution(permission_id)
	local reply = (resolution == "all_rejected") and "reject" or "once"
	local client = require("opencode.client")
	client.respond_permission(permission_id, reply, {}, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to send edit reply: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end
			clear_readonly_warnings(permission_id)
			edit_state.mark_sent(permission_id)
			schedule_render()
		end)
	end)
end

-- ─── File handlers ────────────────────────────────────────────────────────────

function M.handle_edit_accept_file()
	M.sync_selected_file_from_cursor()

	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	local file = estate.files[estate.selected_file]
	if not file or file.status ~= "pending" then
		return
	end

	if edit_state.is_readonly(eid) then
		edit_state.accept_all(eid)
		M.finalize_edit(eid)
		return
	end

	local ok, err = edit_state.accept_file(eid, estate.selected_file)
	if not ok then
		vim.notify("Failed to accept file: " .. (err or "unknown"), vim.log.levels.ERROR)
		return
	end

	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

function M.handle_edit_reject_file()
	M.sync_selected_file_from_cursor()

	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	local file = estate.files[estate.selected_file]
	if not file or file.status ~= "pending" then
		return
	end

	if edit_state.is_readonly(eid) then
		edit_state.reject_all(eid)
		M.finalize_edit(eid)
		return
	end

	local ok, err = edit_state.reject_file(eid, estate.selected_file)
	if not ok then
		vim.notify("Failed to reject file: " .. (err or "unknown"), vim.log.levels.ERROR)
		return
	end

	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

function M.handle_edit_accept_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	edit_state.accept_all(eid)
	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

function M.handle_edit_reject_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	edit_state.reject_all(eid)
	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

function M.handle_edit_resolve_file()
	M.sync_selected_file_from_cursor()

	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	if edit_state.is_readonly(eid) then
		warn_readonly_once(eid, "resolve", "Readonly edit review does not support manual resolve.")
		return
	end

	local file = estate.files[estate.selected_file]
	if not file or file.status ~= "pending" then
		return
	end

	local ok, err = edit_state.resolve_file(eid, estate.selected_file)
	if not ok then
		vim.notify("Failed to resolve file: " .. (err or "unknown"), vim.log.levels.ERROR)
		return
	end

	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

function M.handle_edit_resolve_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	if edit_state.is_readonly(eid) then
		warn_readonly_once(eid, "resolve", "Readonly edit review does not support manual resolve.")
		return
	end
	edit_state.resolve_all(eid)
	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

function M.handle_edit_toggle_diff()
	M.sync_selected_file_from_cursor()

	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end
	edit_state.toggle_inline_diff(eid, estate.selected_file)
	M.rerender_edit(eid)
end

-- ─── Diff viewers ─────────────────────────────────────────────────────────────

function M.handle_edit_diff_tab()
	M.sync_selected_file_from_cursor()

	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end
	if edit_state.is_readonly(eid) then
		warn_readonly_once(eid, "diff", "Readonly edit review does not support opening diff editors.")
		return
	end
	local file = estate.files[estate.selected_file]
	if not file then
		return
	end

	local native_diff = require("opencode.ui.native_diff")
	native_diff.show(nil, {
		{
			filePath = file.filepath,
			relativePath = file.relative_path,
			before = file.before,
			after = file.after,
			type = file.file_type,
		},
	}, {
		-- Pass back-reference so the diff tab can sync status to the chat widget
		edit_id = eid,
		file_index = estate.selected_file,
	})
end

function M.handle_edit_diff_split()
	M.sync_selected_file_from_cursor()

	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end
	if edit_state.is_readonly(eid) then
		warn_readonly_once(eid, "diff", "Readonly edit review does not support opening diff editors.")
		return
	end
	local file = estate.files[estate.selected_file]
	if not file then
		return
	end
	M.open_inline_diff_split(file, {
		edit_id = eid,
		file_index = estate.selected_file,
	})
end

--- Check whether a window belongs to the OpenCode inline diff split.
---@param winid number|nil
---@return boolean
function M.is_inline_diff_window(winid)
	return is_inline_diff_window_marked(winid)
end

--- Close the active OpenCode inline diff split (if any).
---@param opts? table { check_unsaved?: boolean, unsaved_message?: string, silent?: boolean }
---@return boolean ok
---@return string|nil err
---@return number|nil reusable_win
---@return number|nil reusable_buf
function M.close_inline_diff_split(opts)
	opts = opts or {}
	local marked_wins = list_marked_inline_diff_windows()
	local tracked_active = inline_diff_state.active and is_inline_diff_state_valid()
	if not tracked_active and not inline_diff_state.active and #marked_wins == 0 then
		return true, nil, nil, nil
	end

	local check_unsaved = opts.check_unsaved == true
	local unsaved_message = opts.unsaved_message or "Save or discard inline diff changes before continuing."
	local silent = opts.silent == true

	local actual_win = tracked_active and inline_diff_state.actual_win or nil
	local actual_buf = tracked_active and inline_diff_state.actual_buf or nil
	if not is_valid_window(actual_win) or not is_valid_buffer(actual_buf) then
		actual_win, actual_buf = find_actual_from_marked_windows(marked_wins)
	end

	if check_unsaved and is_valid_buffer(actual_buf) and vim.bo[actual_buf].modified then
		if not silent then
			vim.notify(unsaved_message, vim.log.levels.WARN)
		end
		return false, "unsaved_changes", nil, nil
	end

	if state.visible and is_valid_window(state.winid) and state.winid ~= vim.api.nvim_get_current_win() then
		pcall(vim.api.nvim_set_current_win, state.winid)
	end

	local valid_marked = {}
	local marked_set = {}
	for _, winid in ipairs(marked_wins) do
		if is_valid_window(winid) and not marked_set[winid] then
			marked_set[winid] = true
			table.insert(valid_marked, winid)
		end
	end
	if #valid_marked == 0 then
		reset_inline_diff_state()
		return true, nil, nil, nil
	end

	if not is_valid_window(actual_win) or not marked_set[actual_win] then
		actual_win, actual_buf = find_actual_from_marked_windows(valid_marked)
	end

	local close_err
	local reusable_win
	local reusable_buf
	local ordered_wins = {}

	for _, winid in ipairs(valid_marked) do
		if winid ~= actual_win then
			table.insert(ordered_wins, winid)
		end
	end
	if is_valid_window(actual_win) and marked_set[actual_win] then
		table.insert(ordered_wins, actual_win)
	end

	if #ordered_wins == 1 then
		local only_win = ordered_wins[1]
		local only_buf = is_valid_window(only_win) and vim.api.nvim_win_get_buf(only_win) or nil
		local is_actual = is_valid_window(actual_win) and only_win == actual_win
		local norm_win, norm_buf, norm_err = normalize_surviving_inline_diff_window(only_win)
		if is_actual and is_valid_window(norm_win) and is_valid_buffer(norm_buf) then
			reusable_win = norm_win
			reusable_buf = norm_buf
		elseif norm_err then
			close_err = norm_err
		elseif is_valid_buffer(only_buf) and vim.bo[only_buf].buftype == "nofile" then
			reusable_win = nil
			reusable_buf = nil
		end
	else
		for _, winid in ipairs(ordered_wins) do
			if is_valid_window(winid) then
				local ok_close, err = close_window(winid, true)
				if not ok_close then
					local is_actual = is_valid_window(actual_win) and winid == actual_win
					if is_actual and is_last_window_close_error(err) then
						local norm_win, norm_buf, norm_err = normalize_surviving_inline_diff_window(winid)
						if is_valid_window(norm_win) and is_valid_buffer(norm_buf) then
							reusable_win = norm_win
							reusable_buf = norm_buf
						elseif norm_err and not close_err then
							close_err = norm_err
						end
					else
						local _, _, norm_err = normalize_surviving_inline_diff_window(winid)
						if not close_err then
							close_err = norm_err or err
						end
					end
				end
			end
		end
	end

	if close_err and not silent then
		vim.notify("Could not fully close diff split: " .. tostring(close_err), vim.log.levels.WARN)
	end

	if is_valid_buffer(inline_diff_state.proposed_buf) then
		pcall(vim.api.nvim_buf_delete, inline_diff_state.proposed_buf, { force = true })
	end

	reset_inline_diff_state()
	return true, close_err, reusable_win, reusable_buf
end

---Open a vertical diff split near chat for a single file.
---@param file table  File entry from edit state
---@param opts? table { edit_id?: string, file_index?: number }
function M.open_inline_diff_split(file, opts)
	opts = opts or {}
	ensure_inline_diff_state()
	local ok_close, _, reusable_win = M.close_inline_diff_split({
		check_unsaved = true,
		unsaved_message = "Save or discard inline diff changes before opening another diff split.",
	})
	if not ok_close then
		return
	end

	if state.visible and state.config and state.config.layout == "float" then
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		if chat_ok and type(chat.close) == "function" then
			chat.close()
		end
	end

	local filepath = file.filepath
	local after_content = file.after or ""
	local anchor_win = is_valid_window(reusable_win) and reusable_win or find_anchor_window()
	if not anchor_win then
		anchor_win = create_fallback_anchor_window()
	end
	if not is_valid_window(anchor_win) then
		vim.notify("Could not find a usable window for diff split.", vim.log.levels.WARN)
		return
	end

	local ok_actual, actual_result = ensure_actual_file_window(anchor_win, filepath)
	if not ok_actual then
		vim.notify(tostring(actual_result), vim.log.levels.WARN)
		return
	end

	local actual_win = anchor_win
	local actual_buf = actual_result
	vim.api.nvim_set_current_win(actual_win)

	mark_inline_diff_window(actual_win)

	vim.cmd("leftabove vsplit")
	local proposed_win = vim.api.nvim_get_current_win()
	mark_inline_diff_window(proposed_win)
	local proposed_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(proposed_win, proposed_buf)

	local proposed_lines = vim.split(after_content, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(proposed_buf, 0, -1, false, proposed_lines)

	vim.bo[proposed_buf].buftype = "nofile"
	vim.bo[proposed_buf].bufhidden = "wipe"
	vim.bo[proposed_buf].swapfile = false
	vim.bo[proposed_buf].modifiable = false

	local ft = vim.filetype.match({ filename = filepath })
	if ft and ft ~= "" then
		vim.bo[proposed_buf].filetype = ft
	end

	local relative = file.relative_path or vim.fn.fnamemodify(filepath, ":t")
	pcall(vim.api.nvim_buf_set_name, proposed_buf, "[proposed] " .. relative)

	vim.api.nvim_win_call(proposed_win, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_win_call(actual_win, function()
		vim.cmd("diffthis")
	end)

	inline_diff_state.active = true
	inline_diff_state.actual_win = actual_win
	inline_diff_state.actual_buf = actual_buf
	inline_diff_state.proposed_win = proposed_win
	inline_diff_state.proposed_buf = proposed_buf
	inline_diff_state.edit_id = opts.edit_id
	inline_diff_state.file_index = opts.file_index

	vim.api.nvim_set_current_win(actual_win)

	for _, buf in ipairs({ actual_buf, proposed_buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			local keymap_opts = { buffer = buf, noremap = true, silent = true }

			vim.keymap.set("n", "<C-a>", confirm_inline_diff_file, keymap_opts)
			vim.keymap.set("n", "<C-s>", confirm_inline_diff_file, keymap_opts)
			vim.keymap.set("n", "<C-x>", reject_inline_diff_file, keymap_opts)
			vim.keymap.set("n", "<C-y>", apply_inline_diff_hunks, keymap_opts)
			vim.keymap.set("n", "?", show_inline_diff_help, keymap_opts)
			vim.keymap.set("n", "q", function()
				M.close_inline_diff_split({
					check_unsaved = true,
					unsaved_message = "Save or discard inline diff changes before closing the diff split.",
				})
			end, keymap_opts)
		end
	end

	pcall(function()
		vim.cmd("normal! ]c")
	end)
end

return M
