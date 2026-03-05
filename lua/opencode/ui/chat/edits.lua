-- Edit widget lifecycle, handlers, and diff utilities for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

local edit_widget = require("opencode.ui.edit_widget")
local edit_state = require("opencode.edit.state")

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

---Open a vertical diff split near chat for a single file.
---@param file table  File entry from edit state
function M.open_inline_diff_split(file)
	local filepath = file.filepath
	local after_content = file.after or ""

	vim.cmd("leftabove vsplit " .. vim.fn.fnameescape(filepath))
	local actual_win = vim.api.nvim_get_current_win()
	local actual_buf = vim.api.nvim_get_current_buf()

	vim.cmd("vsplit")
	local proposed_win = vim.api.nvim_get_current_win()
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

	vim.api.nvim_set_current_win(actual_win)

	for _, buf in ipairs({ actual_buf, proposed_buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.keymap.set("n", "q", function()
				if vim.api.nvim_buf_is_valid(proposed_buf) then
					vim.api.nvim_buf_delete(proposed_buf, { force = true })
				end
				if vim.api.nvim_win_is_valid(actual_win) then
					vim.api.nvim_win_call(actual_win, function()
						vim.cmd("diffoff")
					end)
				end
			end, { buffer = buf, noremap = true, silent = true })
		end
	end
end

return M
