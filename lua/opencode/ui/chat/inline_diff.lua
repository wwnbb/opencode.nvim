local cs = require("opencode.ui.chat.state")
local active
return cs.factory("inline_diff", function(view)
-- Inline diff window manager: marks, anchor choice, survivor normalisation and
-- buffer keymaps for one proposed/actual split. Edit review semantics stay in
-- ui/chat/edits.lua and arrive here as callbacks.

local M = {}

local state = view

local diff_pair = require("opencode.ui.diff_pair")
-- Read only: review RPC splits keep the actual window when dismissed.
local edit_state = require("opencode.edit.state")
local keymaps = require("opencode.util.keymap")
local inline_diff_mappings = {}
-- Review callbacks for the open split: confirm/reject(edit_id, file_index).
local callbacks = {}

local INLINE_DIFF_WIN_VAR = "opencode_inline_diff_split"

---@class OpenCodeInlineDiffState
---@field active boolean
---@field actual_win integer|nil
---@field actual_buf integer|nil
---@field proposed_win integer|nil
---@field proposed_buf integer|nil
---@field edit_id string|nil
---@field file_index integer|nil
local inline_diff_state = {
	active = false,
	actual_win = nil,
	actual_buf = nil,
	proposed_win = nil,
	proposed_buf = nil,
	edit_id = nil,
	file_index = nil,
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
	if active == M then active = nil end
	callbacks = {}
	for _, mapping in ipairs(inline_diff_mappings) do keymaps.restore(mapping) end
	inline_diff_mappings = {}
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
	pcall(vim.api.nvim_win_set_var, winid, INLINE_DIFF_WIN_VAR, view == cs.state and true or view.id)
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
	return ok and (marked == view.id or (marked == true and view == cs.state))
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
	local function key(action) return keymaps.label("inline_diff", action) end
	local help = {
		"Diff Split Keymaps:",
		"",
		"  do       - Obtain hunk from proposed (LEFT) into actual (RIGHT)",
		"  dp       - Put hunk from actual (RIGHT) to proposed (LEFT)",
		"  ]c       - Jump to next change",
		"  [c       - Jump to previous change",
		"  " .. key("apply_all") .. " - Apply ALL remaining proposed hunks at once",
		"  " .. key("confirm") .. " - Save file as-is and resolve it in the edit widget",
		"  " .. key("reject") .. " - Reject current file and restore the original content",
		"  " .. key("close") .. " - Close the diff split",
		"  " .. key("help") .. " - Show this help",
		"",
		"Tip: use " .. key("apply_all") .. " to apply all proposed changes, then " .. key("confirm") .. " to confirm.",
	}
	vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
end

---@param action "confirm"|"reject"
local function review_action(action)
	local handler = callbacks[action]
	if handler then handler(inline_diff_state.edit_id, inline_diff_state.file_index) end
end

---Check whether a window belongs to this view's inline diff split.
---@param winid number|nil
---@return boolean
function M.is_window(winid)
	return is_inline_diff_window_marked(winid)
end

---@return number|nil bufnr Actual-file buffer of the open split.
function M.actual_buf()
	return inline_diff_state.actual_buf
end

---Close the active OpenCode inline diff split (if any).
---@param opts? table { check_unsaved?: boolean, unsaved_message?: string, silent?: boolean, preserve_actual?: boolean }
---@return boolean ok Whether dismissal was allowed (false for unsaved changes).
---@return string|nil err Refusal or first cleanup error; may accompany true.
---@return number|nil reusable_win
---@return number|nil reusable_buf
function M.close(opts)
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
		actual_win = find_actual_from_marked_windows(valid_marked)
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
		local estate = inline_diff_state.edit_id and edit_state.get_edit(inline_diff_state.edit_id)
		for _, winid in ipairs(ordered_wins) do
			if winid == actual_win and (opts.preserve_actual or estate and estate.transport == "review_rpc") then
				-- Keep manual file edits when dismissing a review or switching layouts.
				local norm_err
				reusable_win, reusable_buf, norm_err = normalize_surviving_inline_diff_window(winid)
				close_err = close_err or norm_err
			elseif is_valid_window(winid) then
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
							close_err = err or norm_err
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
---@param review_callbacks? { confirm?: fun(edit_id: string|nil, file_index: number|nil), reject?: fun(edit_id: string|nil, file_index: number|nil) }
function M.open(file, opts, review_callbacks)
	opts = opts or {}
	if file.apply_mode == "server" then
		vim.notify("Local diff requires server.shared_filesystem=true and access to the server files. Use "
			.. keymaps.label("chat", "toggle_diff", (state.config or {}).keymaps) .. " for the inline proposal.", vim.log.levels.WARN)
		return
	end
	-- Neovim shares one diff set across every diff window in a tab.
	if active and active ~= M then
		local closed = active.close({ check_unsaved = true,
			unsaved_message = "Save or discard inline diff changes before opening another diff split." })
		if not closed then return end
	end
	ensure_inline_diff_state()
	local ok_close, _, reusable_win = M.close({
		check_unsaved = true,
		unsaved_message = "Save or discard inline diff changes before opening another diff split.",
	})
	if not ok_close then
		return
	end
	if is_valid_window(state.winid) then vim.api.nvim_set_current_win(state.winid) end

	if state.visible and state.config and state.config.layout == "float" then
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		if chat_ok and type(chat.close) == "function" then
			cs.module(view, chat).close()
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

	-- Mark the proposed window as soon as it exists, before buffer setup
	local proposed_win, proposed_buf = diff_pair.open(actual_win, actual_buf, {
		after = after_content,
		filepath = filepath,
		relative = file.relative_path or require("opencode.util.text").normalize_path(filepath),
		on_split = mark_inline_diff_window,
	})

	inline_diff_state.active = true
	active = M
	callbacks = review_callbacks or {}
	inline_diff_state.actual_win = actual_win
	inline_diff_state.actual_buf = actual_buf
	inline_diff_state.proposed_win = proposed_win
	inline_diff_state.proposed_buf = proposed_buf
	inline_diff_state.edit_id = opts.edit_id
	inline_diff_state.file_index = opts.file_index

	for _, buf in ipairs({ actual_buf, proposed_buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			local keymap_opts = { noremap = true, silent = true }
			local map, apply = keymaps.mapper("inline_diff", buf)

			map("n", "confirm", function() review_action("confirm") end, keymap_opts)
			map("n", "reject", function() review_action("reject") end, keymap_opts)
			map("n", "apply_all", apply_inline_diff_hunks, keymap_opts)
			map("n", "help", show_inline_diff_help, keymap_opts)
			map("n", "close", function()
				M.close({
					check_unsaved = true,
					unsaved_message = "Save or discard inline diff changes before closing the diff split.",
				})
			end, keymap_opts)
			vim.list_extend(inline_diff_mappings, apply())
		end
	end
end

return M

end)
