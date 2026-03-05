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

---@return string|nil permission_id
function M.get_edit_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1

	for eid, pos in pairs(state.edits) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line and pos.status == "pending" then
			return eid
		end
	end

	return nil
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
			edit_state.mark_sent(permission_id)
			schedule_render()
		end)
	end)
end

-- ─── File handlers ────────────────────────────────────────────────────────────

function M.handle_edit_accept_file()
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
	edit_state.resolve_all(eid)
	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

function M.handle_edit_toggle_diff()
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
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	local estate = edit_state.get_edit(eid)
	if not estate then
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
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end
	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end
	local file = estate.files[estate.selected_file]
	if not file then
		return
	end
	M.open_inline_diff_split(file)
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
function M.close_inline_diff_split(opts)
	opts = opts or {}
	local marked_wins = list_marked_inline_diff_windows()
	local tracked_active = inline_diff_state.active and is_inline_diff_state_valid()
	if not tracked_active and not inline_diff_state.active and #marked_wins == 0 then
		return true
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
		return false, "unsaved_changes"
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
		return true
	end

	local total_windows = #vim.api.nvim_list_wins()
	local keep_win = nil
	if total_windows <= #valid_marked then
		if is_valid_window(actual_win) and marked_set[actual_win] then
			keep_win = actual_win
		else
			keep_win = valid_marked[1]
		end
	end

	if keep_win and is_valid_window(keep_win) and vim.api.nvim_get_current_win() ~= keep_win then
		pcall(vim.api.nvim_set_current_win, keep_win)
	end

	local close_err
	for _, winid in ipairs(valid_marked) do
		if not keep_win or winid ~= keep_win then
			local ok_close, err = close_window(winid, true)
			if not ok_close and not close_err then
				close_err = err
			end
		end
	end

	if keep_win and is_valid_window(keep_win) then
		pcall(vim.api.nvim_win_set_var, keep_win, INLINE_DIFF_WIN_VAR, false)
		pcall(vim.api.nvim_win_call, keep_win, function()
			vim.cmd("diffoff!")
		end)
	end

	if close_err and not silent then
		vim.notify("Could not fully close diff split: " .. tostring(close_err), vim.log.levels.WARN)
	end

	if is_valid_buffer(inline_diff_state.proposed_buf) then
		pcall(vim.api.nvim_buf_delete, inline_diff_state.proposed_buf, { force = true })
	end

	reset_inline_diff_state()
	return true
end

---Open a vertical diff split near chat for a single file.
---@param file table  File entry from edit state
function M.open_inline_diff_split(file)
	ensure_inline_diff_state()
	local ok_close = M.close_inline_diff_split({
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
	local anchor_win = find_anchor_window()
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

	vim.api.nvim_set_current_win(actual_win)

	for _, buf in ipairs({ actual_buf, proposed_buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.keymap.set("n", "q", function()
				M.close_inline_diff_split({
					check_unsaved = true,
					unsaved_message = "Save or discard inline diff changes before closing the diff split.",
				})
			end, { buffer = buf, noremap = true, silent = true })
		end
	end
end

return M
