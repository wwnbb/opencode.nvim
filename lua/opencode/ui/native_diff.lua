-- opencode.nvim - Native Neovim Diff Module
-- Provides native vim diff experience for reviewing tool-proposed changes.
-- Proposed content on LEFT (readonly), actual file on RIGHT (editable).
-- User applies hunks with `do`/`dp`/`]c`/`[c` and confirms with keybindings.

local M = {}

local state = {
	active = false,
	permission_id = nil,
	files = {},      -- Array of {filePath, before, after, type, relativePath, diff}
	current_file_index = 1,
	original_buf = nil, -- Buffer for the actual file (RIGHT side, editable)
	proposed_buf = nil, -- Scratch buffer with proposed content (LEFT side, readonly)
	original_win = nil,
	proposed_win = nil,
	tab_page = nil,     -- Tab page for the diff view (keeps chat untouched)
	previous_winid = nil, -- To restore focus on close
	file_snapshots = {}, -- {[index] = original_content} for undo on reject
	-- Back-reference to the chat edit widget (set when launched from dt)
	edit_id = nil,      -- permission_id of the originating edit
	edit_file_index = nil, -- which file index in the edit widget was opened
}

local logger_ok, logger = pcall(require, "opencode.logger")
if not logger_ok then
	logger = { debug = function() end, info = function() end, warn = function() end }
end

local function get_note()
	if not state.edit_id then
		return ""
	end

	local ok, edit_state = pcall(require, "opencode.edit.state")
	if not ok then
		return ""
	end

	local estate = edit_state.get_edit(state.edit_id)
	return estate and vim.trim(estate.message or "") or ""
end

local function focus_diff_window(winid)
	local target = winid
	if not target or not vim.api.nvim_win_is_valid(target) then
		target = state.original_win
	end
	if (not target or not vim.api.nvim_win_is_valid(target)) and state.proposed_win and vim.api.nvim_win_is_valid(state.proposed_win) then
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

--- Write content to a file
---@param filepath string
---@param content string
local function write_file(filepath, content)
	local dir = vim.fn.fnamemodify(filepath, ":h")
	vim.fn.mkdir(dir, "p")
	local f = io.open(filepath, "w")
	if f then
		f:write(content)
		f:close()
	end
end

--- Read content from a file
---@param filepath string
---@return string
local function read_file(filepath)
	local f = io.open(filepath, "r")
	if not f then
		return ""
	end
	local content = f:read("*all")
	f:close()
	return content
end

--- Send permission reply to server
---@param reply string "once" | "reject"
local function send_reply(reply)
	if not state.permission_id then
		logger.warn("native_diff: No permission_id to reply to")
		return
	end

	local client = require("opencode.client")
	local message = get_note()
	client.respond_permission(state.permission_id, reply, { message = message ~= "" and message or nil }, function(err, result)
		vim.schedule(function()
			if err then
				vim.notify("Failed to send reply to server: " .. vim.inspect(err), vim.log.levels.WARN)
				logger.warn("native_diff: reply error", { error = err })
			else
				logger.info("native_diff: reply sent", { reply = reply, result = result })
			end
		end)
	end)
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

	-- Capture previous_winid BEFORE resetting state (state reset nils it)
	local prev_win = state.previous_winid

	-- Reset state
	state.active = false
	state.permission_id = nil
	state.files = {}
	state.current_file_index = 1
	state.original_buf = nil
	state.proposed_buf = nil
	state.original_win = nil
	state.proposed_win = nil
	state.tab_page = nil
	state.file_snapshots = {}
	state.previous_winid = nil
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

	state.original_buf = nil
	state.proposed_buf = nil
	state.original_win = nil
	state.proposed_win = nil
	state.tab_page = nil
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

		-- <C-a>: Confirm current file (save as-is, auto-classify, advance)
		-- Does NOT overwrite manual edits — file is classified by comparing disk state to before/after.
		vim.keymap.set("n", "<C-a>", function()
			M._confirm_current()
		end, opts)

		-- <C-s>: Alias for <C-a> — explicit "save my manual edits and mark as resolved"
		vim.keymap.set("n", "<C-s>", function()
			M._confirm_current()
		end, opts)

		-- <C-x>: Reject current file (revert to original + advance)
		vim.keymap.set("n", "<C-x>", function()
			M._reject_current()
		end, opts)

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

		-- <C-n>: Confirm current + next file (multi-file shortcut)
		vim.keymap.set("n", "<C-n>", function()
			M._confirm_current()
		end, opts)

		vim.keymap.set("n", "m", function()
			edit_note()
		end, opts)

		-- <C-p>: Go to previous file
		vim.keymap.set("n", "<C-p>", function()
			if state.current_file_index > 1 then
				-- Save current file state before going back
				if state.original_win and vim.api.nvim_win_is_valid(state.original_win) then
					vim.api.nvim_win_call(state.original_win, function()
						vim.cmd("silent! write")
					end)
				end
				close_diff_windows()
				state.current_file_index = state.current_file_index - 1
				M._show_file(state.current_file_index)
			else
				vim.notify("Already at the first file", vim.log.levels.INFO)
			end
		end, opts)

		-- q: Reject all and close
		vim.keymap.set("n", "q", function()
			M._reject_all()
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
				"  <C-a>    - Save file as-is and advance (auto-classifies: accepted/resolved)",
				"  <C-s>    - Same as <C-a> (save manual edits and mark as resolved)",
				"  <C-x>    - Reject current file (revert to original and advance)",
				"  <C-n>    - Same as <C-a> (confirm + next)",
				"  <C-p>    - Go to previous file",
				"  m        - Add or edit note",
				"  q        - Reject ALL files and close",
				"  ?        - Show this help",
				"",
				"Tip: use <C-y> to apply all proposed changes, then <C-a> to confirm.",
				"     Or edit manually and press <C-s> / <C-a> to keep your edits.",
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

	-- Store snapshot of original content for undo on reject
	state.file_snapshots[index] = before

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
			if choice == "Yes, delete" then
				-- Delete the file
				local ok, err = pcall(os.remove, filepath)
				if not ok then
					logger.warn("native_diff: failed to delete file", { filepath = filepath, error = err })
				end
			end
			-- Advance to next or finish
			M._advance_or_finish()
		end)
		return
	end

	-- For add type: write the file first so we can open it
	if file_type == "add" and before == "" then
		-- Ensure parent directory exists and create the file with empty content
		-- (the proposed content will be shown on the left for the user to apply)
		write_file(filepath, "")
	end

	-- Open the actual file in a new tab (keeps the chat buffer untouched)
	vim.cmd("tabnew " .. vim.fn.fnameescape(filepath))
	state.original_buf = vim.api.nvim_get_current_buf()
	state.original_win = vim.api.nvim_get_current_win()
	state.tab_page = vim.api.nvim_get_current_tabpage()

	-- For 'add' type with empty file: set the buffer content to empty
	-- For 'update' type: the file already has the 'before' content on disk

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
			"[%d/%d] %s | <C-a>=confirm  <C-x>=reject  m=note  do=get hunk  ?=help",
			index,
			total,
			relative
		)
	else
		status_msg = string.format(
			"%s | <C-a>=confirm  <C-x>=reject  m=note  do=get hunk  ?=help",
			relative
		)
	end
	vim.notify(status_msg, vim.log.levels.INFO)
end

--- Sync the chat edit widget status after a confirm/reject/resolve action.
--- "resolve" reads the current disk state and auto-classifies
--- (accepted if matches 'after', rejected if matches 'before', resolved otherwise).
--- This is used by <C-a> / <C-s> so manual edits are never overwritten.
---@param action "resolve"|"reject"
local function sync_edit_action(action)
	if not state.edit_id or not state.edit_file_index then
		return
	end
	local edit_id = state.edit_id
	local file_index = state.edit_file_index

	vim.schedule(function()
		local ok_es, edit_state = pcall(require, "opencode.edit.state")
		if not ok_es then
			return
		end

		local estate = edit_state.get_edit(edit_id)
		if not estate or estate.status ~= "pending" then
			return
		end

		local file = estate.files[file_index]
		if not file or file.status ~= "pending" then
			return
		end

		if action == "resolve" then
			-- Auto-classify: reads disk, compares to before/after, sets status accordingly.
			-- This preserves whatever the user saved manually.
			edit_state.resolve_file(edit_id, file_index)
		else -- "reject"
			edit_state.reject_file(edit_id, file_index)
		end

		-- Trigger rerender or finalization in the chat
		local ok_edits, chat_edits = pcall(require, "opencode.ui.chat.edits")
		if ok_edits then
			if edit_state.are_all_resolved(edit_id) then
				chat_edits.finalize_edit(edit_id)
			else
				chat_edits.rerender_edit(edit_id)
			end
		end
	end)
end

--- Confirm current file: save current buffer state and advance.
--- Uses "resolve" so the file is auto-classified based on its current disk content
--- (accepted if all hunks applied, rejected if reverted, resolved if partially edited).
--- Manual edits are NEVER overwritten.
function M._confirm_current()
	-- Save the file buffer as-is (preserves any manual edits)
	if state.original_win and vim.api.nvim_win_is_valid(state.original_win) then
		vim.api.nvim_win_call(state.original_win, function()
			vim.cmd("silent! write")
		end)
	end
	sync_edit_action("resolve")
	M._advance_or_finish()
end

--- Reject current file: revert to original snapshot and advance
function M._reject_current()
	local index = state.current_file_index
	local file = state.files[index]
	local snapshot = state.file_snapshots[index]

	if file and snapshot ~= nil then
		local filepath = file.filePath or file.filepath or file.path
		local file_type = file.type or "update"

		if file_type == "add" and snapshot == "" then
			-- For new files that were rejected, remove the file
			pcall(os.remove, filepath)
		else
			-- Revert to original content
			write_file(filepath, snapshot)
		end

		-- Reload the buffer if it's still open
		if state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
			vim.api.nvim_buf_call(state.original_buf, function()
				vim.cmd("silent! edit!")
			end)
		end
	end

	sync_edit_action("reject")
	M._advance_or_finish()
end

--- Reject all files and close
function M._reject_all()
	-- Revert all files to their snapshots
	for i, file in ipairs(state.files) do
		local snapshot = state.file_snapshots[i]
		if file and snapshot ~= nil then
			local filepath = file.filePath or file.filepath or file.path
			local file_type = file.type or "update"

			if file_type == "add" and snapshot == "" then
				pcall(os.remove, filepath)
			elseif file_type ~= "delete" then
				write_file(filepath, snapshot)
			end
		end
	end

	-- Send rejection reply
	if state.edit_id then
		local ok_state, edit_state = pcall(require, "opencode.edit.state")
		if ok_state then
			edit_state.reject_all(state.edit_id)
		end
		local ok_edits, chat_edits = pcall(require, "opencode.ui.chat.edits")
		if ok_edits and chat_edits.finalize_edit then
			chat_edits.finalize_edit(state.edit_id)
		end
	else
		send_reply("reject")
	end

	-- Close the diff view
	close_diff_windows()
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
		-- All files reviewed — send approval reply and close
		if not state.edit_id then
			send_reply("once")
		end

		vim.schedule(function()
			M.close()
			vim.notify("All files reviewed and applied", vim.log.levels.INFO)
		end)
	end
end

--- Show the native diff view for a permission request
---@param permission_id string The permission request ID
---@param files table Array of {filePath, before, after, type, relativePath, diff}
---@param opts? table Options
function M.show(permission_id, files, opts)
	opts = opts or {}

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
	state.permission_id = permission_id
	state.files = files
	state.current_file_index = 1
	state.file_snapshots = {}
	state.edit_id = opts.edit_id or nil
	state.edit_file_index = opts.file_index or nil

	-- Stop spinner if active
	local spinner_ok, spinner = pcall(require, "opencode.ui.spinner")
	if spinner_ok and spinner.is_active then
		local is_active = pcall(spinner.is_active)
		if is_active then
			pcall(spinner.stop)
		end
	end

	logger.info("native_diff: starting review", {
		permission_id = permission_id,
		file_count = #files,
	})

	-- Show the first file
	M._show_file(1)
end

--- Check if the native diff view is active
---@return boolean
function M.is_active()
	return state.active
end

return M
