-- opencode.nvim - Native Neovim Diff Module
-- Provides native vim diff experience for reviewing tool-proposed changes.
-- Proposed content on LEFT (readonly), actual file on RIGHT (editable).
-- User applies hunks with `do`/`dp`/`]c`/`[c` and confirms with keybindings.

local M = {}

local syntax = require("opencode.ui.syntax")

local state = {
	active = false,
	files = {}, -- Array of {filePath, before, after, type, relativePath, diff, edit_file_index?}
	current_file_index = 1,
	original_buf = nil, -- Buffer for the actual file (RIGHT side, editable)
	proposed_buf = nil, -- Scratch buffer with proposed content (LEFT side, readonly)
	original_win = nil,
	proposed_win = nil,
	tab_page = nil, -- Tab page for the diff view (keeps chat untouched)
	previous_winid = nil, -- To restore focus on close
	original_is_scratch = false, -- Missing add-file target opened without touching disk
	-- Back-reference to the chat edit widget (set when launched from dt)
	edit_id = nil, -- ID of the originating v2 review
	edit_file_index = nil, -- which file index in the edit widget was opened
}

local logger_ok, logger = pcall(require, "opencode.logger")
if not logger_ok then
	logger = { debug = function() end, info = function() end, warn = function() end }
end

local function focus_diff_window(winid)
	local target = winid
	if not target or not vim.api.nvim_win_is_valid(target) then
		target = state.original_win
	end
	if
		(not target or not vim.api.nvim_win_is_valid(target))
		and state.proposed_win
		and vim.api.nvim_win_is_valid(state.proposed_win)
	then
		target = state.proposed_win
	end
	if target and vim.api.nvim_win_is_valid(target) then
		vim.api.nvim_set_current_win(target)
	end
end

local function edit_note()
	if not state.edit_id then
		vim.notify("No edit note target available", vim.log.levels.WARN)
		return
	end

	local ok, edit_state = pcall(require, "opencode.edit.state")
	if not ok then
		return
	end

	local estate = edit_state.get_edit(state.edit_id)
	if not estate or estate.status ~= "pending" then
		return
	end

	local input = require("opencode.ui.input")
	local current = vim.api.nvim_get_current_win()
	local function finish(text)
		edit_state.set_message(state.edit_id, text or "")
		local ok_edits, chat_edits = pcall(require, "opencode.ui.chat.edits")
		if ok_edits and chat_edits.rerender_edit then
			chat_edits.rerender_edit(state.edit_id)
		end
		focus_diff_window(current)
	end

	input.show({
		winid = current,
		text = estate.message or "",
		persist_pending = false,
		add_history = false,
		on_send = finish,
		on_cancel = finish,
	})
end

--- Get the filetype from a file path for syntax highlighting
---@param filepath string
---@return string
local function get_filetype(filepath)
	local ext = vim.fn.fnamemodify(filepath, ":e")
	if ext == "" then
		return ""
	end
	-- Use vim's built-in filetype detection
	local ft = vim.filetype.match({ filename = filepath })
	return ft or ext
end

local function delete_scratch_original_buffer()
	if state.original_is_scratch and state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
		pcall(vim.api.nvim_buf_delete, state.original_buf, { force = true })
	end
end

--- Close the diff view and clean up
function M.close()
	if not state.active then
		return
	end

	-- Close the diff tab (which closes both windows and the scratch buffer)
	if state.tab_page and vim.api.nvim_tabpage_is_valid(state.tab_page) then
		local tabnr = vim.api.nvim_tabpage_get_number(state.tab_page)
		pcall(vim.cmd, tabnr .. "tabclose")
	end

	-- Clean up proposed scratch buffer if it survived the tab close
	if state.proposed_buf and vim.api.nvim_buf_is_valid(state.proposed_buf) then
		vim.api.nvim_buf_delete(state.proposed_buf, { force = true })
	end
	delete_scratch_original_buffer()

	-- Capture previous_winid BEFORE resetting state (state reset nils it)
	local prev_win = state.previous_winid

	-- Reset state
	state.active = false
	state.files = {}
	state.current_file_index = 1
	state.original_buf = nil
	state.proposed_buf = nil
	state.original_win = nil
	state.proposed_win = nil
	state.tab_page = nil
	state.previous_winid = nil
	state.original_is_scratch = false
	state.edit_id = nil
	state.edit_file_index = nil

	-- Restore focus to previous window
	vim.schedule(function()
		if prev_win and vim.api.nvim_win_is_valid(prev_win) then
			vim.api.nvim_set_current_win(prev_win)
		end

		-- Re-open input only if the chat is still visible (it may have been
		-- closed by WinEnter/TabEnter while the diff tab was active)
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		if chat_ok and chat.focus_input and chat.is_visible and chat.is_visible() then
			chat.focus_input()
		end
	end)
end

--- Close just the diff windows without resetting the full state (for file transitions)
local function close_diff_windows()
	-- Close the diff tab (which closes both windows)
	if state.tab_page and vim.api.nvim_tabpage_is_valid(state.tab_page) then
		local tabnr = vim.api.nvim_tabpage_get_number(state.tab_page)
		pcall(vim.cmd, tabnr .. "tabclose")
	end

	-- Clean up proposed scratch buffer if it survived
	if state.proposed_buf and vim.api.nvim_buf_is_valid(state.proposed_buf) then
		vim.api.nvim_buf_delete(state.proposed_buf, { force = true })
	end
	delete_scratch_original_buffer()

	state.original_buf = nil
	state.proposed_buf = nil
	state.original_win = nil
	state.proposed_win = nil
	state.tab_page = nil
	state.original_is_scratch = false
end

local function rpc_review()
	local edit = state.edit_id and require("opencode.edit.state").get_edit(state.edit_id)
	return edit and edit.transport == "review_rpc" and edit or nil
end

local function rpc_file_action(action)
	local edit = rpc_review()
	if not edit then return false end
	local file = state.files[state.current_file_index]
	local index = file and file.edit_file_index or state.edit_file_index
	local edits = require("opencode.edit.state")
	local ok, err = edits[action .. "_file"](state.edit_id, index)
	if not ok then
		vim.notify("Review action failed: " .. (err or "unknown error"), vim.log.levels.WARN)
		return false
	end
	require("opencode.ui.chat.edits").refresh_edit(state.edit_id)
	return true
end

local function navigate_file(delta)
	local next_index = state.current_file_index + delta
	if next_index < 1 then
		vim.notify("Already at the first file", vim.log.levels.INFO)
		return
	end
	if next_index > #state.files then
		vim.notify("Already at the last file", vim.log.levels.INFO)
		return
	end

	if state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) and vim.bo[state.original_buf].modified then
		vim.notify("Confirm or save your manual changes before switching review files.", vim.log.levels.WARN)
		return
	end
	close_diff_windows()
	state.current_file_index = next_index
	M._show_file(state.current_file_index)
end

--- Set up keymaps on both buffers
local function setup_keymaps()
	local bufs = {}
	if state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
		table.insert(bufs, state.original_buf)
	end
	if state.proposed_buf and vim.api.nvim_buf_is_valid(state.proposed_buf) then
		table.insert(bufs, state.proposed_buf)
	end

	for _, buf in ipairs(bufs) do
		local opts = { buffer = buf, noremap = true, silent = true }

		-- <C-y>: Apply all remaining proposed hunks at once (diffget from proposed)
		vim.keymap.set("n", "<C-y>", function()
			-- Focus the original (right) window and get all changes from proposed
			if state.original_win and vim.api.nvim_win_is_valid(state.original_win) then
				vim.api.nvim_set_current_win(state.original_win)
				-- Apply all remaining changes using :%diffget
				local ok, err = pcall(function()
					vim.cmd("%diffget")
				end)
				if not ok then
					logger.debug("native_diff: diffget error (may be no more diffs)", { error = err })
				end
			end
		end, opts)

		vim.keymap.set("n", "<C-a>", M._confirm_current, opts)
		vim.keymap.set("n", "<C-x>", M._reject_current, opts)
		vim.keymap.set("n", "<C-S-x>", M._reject_all, opts)

		-- File navigation only; does not resolve, reject, or send the edit.
		vim.keymap.set("n", "<leader>on", function()
			navigate_file(1)
		end, opts)
		vim.keymap.set("n", "<leader>op", function()
			navigate_file(-1)
		end, opts)

		vim.keymap.set("n", "m", function()
			edit_note()
		end, opts)

		-- q: Close diff view
		vim.keymap.set("n", "q", function()
			M.close()
		end, opts)

		-- ?: Show help
		vim.keymap.set("n", "?", function()
			local help = {
				"Native Diff Keymaps:",
				"",
				"  do       - Obtain hunk from proposed (LEFT) into actual (RIGHT)",
				"  dp       - Put hunk from actual (RIGHT) to proposed (LEFT)",
				"  ]c       - Jump to next change",
				"  [c       - Jump to previous change",
				"  <C-y>    - Apply ALL remaining proposed hunks at once",
				"  <C-a>    - Confirm current file and continue",
				"  <C-x>    - Reject current file and restore the original content",
				"  <C-S-x>  - Reject all files and close",
				"  <leader>on - Go to next file",
				"  <leader>op - Go to previous file",
				"  m        - Add or edit note",
				"  q        - Close diff view",
				"  ?        - Show this help",
				"",
				"Tip: use <C-y> to apply all proposed changes in the current file, then <C-a> to confirm.",
			}
			vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
		end, opts)
	end
end

--- Show a specific file for diff review
---@param index number 1-based file index
function M._show_file(index)
	local file = state.files[index]
	if not file then
		logger.warn("native_diff: invalid file index", { index = index, total = #state.files })
		return
	end

	local filepath = file.filePath or file.filepath or file.path
	local before = file.before or ""
	local after = file.after or ""
	local file_type = file.type or "update"

	logger.debug("native_diff: showing file", {
		index = index,
		total = #state.files,
		filepath = filepath,
		type = file_type,
	})

	-- Handle delete type with confirmation dialog
	if file_type == "delete" then
		vim.ui.select({ "Yes, delete", "No, keep" }, {
			prompt = "Delete file: " .. filepath .. "?",
		}, function(choice)
			if not choice then return end
			if rpc_file_action(choice == "Yes, delete" and "accept" or "reject") then M._advance_or_finish() end
		end)
		return
	end

	-- Open the actual file in a new tab (keeps the chat buffer untouched). A
	-- missing add target gets a named scratch buffer so opening review does not
	-- touch the filesystem; confirmation creates it via :write.
	local missing_add = file_type == "add" and before == "" and vim.uv.fs_stat(filepath) == nil
	if missing_add then
		vim.cmd("tabnew")
		state.original_buf = vim.api.nvim_get_current_buf()
		state.original_is_scratch = true
		vim.bo[state.original_buf].bufhidden = "wipe"
		vim.bo[state.original_buf].swapfile = false
		vim.bo[state.original_buf].buflisted = false
		vim.api.nvim_buf_set_name(state.original_buf, filepath)
	else
		vim.cmd("tabnew " .. vim.fn.fnameescape(filepath))
		state.original_buf = vim.api.nvim_get_current_buf()
		state.original_is_scratch = false
	end
	state.original_win = vim.api.nvim_get_current_win()
	state.tab_page = vim.api.nvim_get_current_tabpage()

	-- Create vertical split LEFT for proposed content
	vim.cmd("leftabove vsplit")
	state.proposed_win = vim.api.nvim_get_current_win()

	-- Create scratch buffer for proposed (after) content
	state.proposed_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(state.proposed_win, state.proposed_buf)

	-- Set proposed content
	local proposed_lines = vim.split(after, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(state.proposed_buf, 0, -1, false, proposed_lines)

	-- Configure proposed buffer as readonly scratch
	vim.bo[state.proposed_buf].buftype = "nofile"
	vim.bo[state.proposed_buf].bufhidden = "wipe"
	vim.bo[state.proposed_buf].swapfile = false
	vim.bo[state.proposed_buf].modifiable = false

	-- Set filetype for syntax highlighting
	local ft = get_filetype(filepath)
	if ft and ft ~= "" then
		vim.bo[state.proposed_buf].filetype = ft
		syntax.start_buffer(state.proposed_buf, ft, { scope = "diffs" })
		syntax.start_buffer(state.original_buf, ft, { scope = "diffs" })
	end

	-- Name the scratch buffer for clarity
	local relative = file.relativePath or vim.fn.fnamemodify(filepath, ":t")
	pcall(vim.api.nvim_buf_set_name, state.proposed_buf, "[proposed] " .. relative)

	-- Enable diff on both windows
	vim.api.nvim_win_call(state.proposed_win, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_win_call(state.original_win, function()
		vim.cmd("diffthis")
	end)

	-- Focus the right window (the actual file, editable)
	vim.api.nvim_set_current_win(state.original_win)

	-- Set up keymaps
	setup_keymaps()

	-- Jump to first change
	pcall(function()
		vim.cmd("normal! ]c")
	end)

	-- Show status notification
	local total = #state.files
	local status_msg
	if total > 1 then
		status_msg = string.format(
			"[%d/%d] %s | <leader>on/<leader>op=file nav  <C-y>=apply all  m=note  do=get hunk  ?=help",
			index,
			total,
			relative
		)
	else
		status_msg = string.format("%s | <C-y>=apply all  m=note  do=get hunk  ?=help", relative)
	end
	vim.notify(status_msg, vim.log.levels.INFO)
end

---Confirm current file using the review RPC state.
function M._confirm_current()
	if rpc_file_action("resolve") then M._advance_or_finish() end
end

---Reject current file through the review RPC state.
function M._reject_current()
	if rpc_file_action("reject") then M._advance_or_finish() end
end

--- Reject all files and close
function M._reject_all()
	if not rpc_review() then return end
	local ok, err = require("opencode.edit.state").reject_all(state.edit_id)
	if not ok then vim.notify("Review rejection failed: " .. (err or "unknown error"), vim.log.levels.WARN); return end
	require("opencode.ui.chat.edits").refresh_edit(state.edit_id)
	M.close()
	vim.notify("All changes rejected", vim.log.levels.INFO)
end

--- Advance to next file or finish if all files reviewed
function M._advance_or_finish()
	close_diff_windows()

	if state.current_file_index < #state.files then
		-- More files to review
		state.current_file_index = state.current_file_index + 1
		vim.schedule(function()
			M._show_file(state.current_file_index)
		end)
	else
		vim.schedule(function()
			M.close()
			vim.notify("All files reviewed and applied", vim.log.levels.INFO)
		end)
	end
end

---Show the native diff view for a v2 review.
---@param files table Array of {filePath, before, after, type, relativePath, diff}
---@param opts? table Options
function M.show(files, opts)
	opts = opts or {}
	local edit = opts.edit_id and require("opencode.edit.state").get_edit(opts.edit_id)
	if not edit or edit.transport ~= "review_rpc" then return false end
	if edit and edit.apply_mode == "server" then
		vim.notify("Local diff requires server.shared_filesystem=true and access to the server files. Use = for the inline proposal.", vim.log.levels.WARN)
		return
	end

	if state.active then
		M.close()
	end

	-- Validate files
	if not files or #files == 0 then
		logger.warn("native_diff: no files to show")
		vim.notify("No files to review in this diff request", vim.log.levels.WARN)
		return
	end

	-- Save current window for restoration
	state.previous_winid = vim.api.nvim_get_current_win()

	-- Initialize state
	state.active = true
	state.files = files
	local start_index = math.floor(tonumber(opts.start_index) or 1)
	if start_index < 1 or start_index > #files then
		start_index = 1
	end
	state.current_file_index = start_index
	state.original_is_scratch = false
	state.edit_id = opts.edit_id or nil
	state.edit_file_index = opts.file_index or nil

	logger.info("native_diff: starting review", {
		review_id = opts.edit_id,
		file_count = #files,
	})

	-- Show the requested file
	M._show_file(state.current_file_index)
	return true
end

--- Check if the native diff view is active
---@return boolean
function M.is_active()
	return state.active
end

return M
