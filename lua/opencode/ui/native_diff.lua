-- opencode.nvim - Native Neovim Diff Module
-- Provides native vim diff experience for reviewing tool-proposed changes.
-- Proposed content on LEFT (readonly), actual file on RIGHT (editable).
-- User applies hunks with `do`/`dp`/`]c`/`[c` and confirms with keybindings.

local M = {}

local diff_pair = require("opencode.ui.diff_pair")
local codediff = require("opencode.ui.codediff")
local pending = require("opencode.session.pending")
local keymaps = require("opencode.util.keymap")
local views = require("opencode.ui.chat.state")
local diff_mappings = {}
local view_generation = 0

-- Fresh session state. close() replaces the whole table; close_diff_windows()
-- resets only the per-file fields because file navigation reuses the session.
local function new_state()
	return {
		active = false,
		files = {}, -- Array of {filePath, before, after, type, relativePath, diff, edit_file_index?}
		current_file_index = 1,
		-- Per-file fields
		original_buf = nil, -- Buffer for the actual file (RIGHT side, editable)
		proposed_buf = nil, -- Scratch buffer with proposed content (LEFT side, readonly)
		original_win = nil,
		proposed_win = nil,
		tab_page = nil, -- Tab page for the diff view (keeps chat untouched)
		original_is_scratch = false, -- Missing add-file target opened without touching disk
		close_autocmd = nil, -- TabClosed autocmd closing the session with its tab
		provider = nil, -- "native" or "codediff" for the file on screen
		provider_cleanup = nil, -- Backend teardown (codediff temp file)
		-- Session fields
		previous_winid = nil, -- To restore focus on close
		on_close = nil, -- Caller hook run after focus restore: on_close({ restored = boolean })
		-- Back-reference to the chat edit widget (set when launched from dt)
		edit_id = nil, -- ID of the originating v2 review
		edit_file_index = nil, -- which file index in the edit widget was opened
		review = nil, -- Edit state record the session was opened for
		token = nil, -- Pending-session token guarding review actions
		view = nil, -- Owning chat view, if any
		owner_generation = nil, -- Owner view generation at open
	}
end

local state = new_state()

local logger_ok, logger = pcall(require, "opencode.logger")
if not logger_ok then
	logger = { debug = function() end, info = function() end, warn = function() end }
end

local function focus_diff_window(winid)
	local candidates = { winid, state.original_win, state.proposed_win }
	for i = 1, 3 do
		local target = candidates[i]
		if target and vim.api.nvim_win_is_valid(target) then
			vim.api.nvim_set_current_win(target)
			return
		end
	end
end

local function rpc_review()
	if state.view and not views.valid(state.view, state.owner_generation) then return nil end
	local edit = state.edit_id and require("opencode.edit.state").get_edit(state.edit_id)
	return edit and edit == state.review and pending.is_current(state.token) and edit.transport == "review_rpc" and edit or nil
end

local function edit_note()
	if not state.edit_id then
		vim.notify("No edit note target available", vim.log.levels.WARN)
		return
	end

	local edit_state = require("opencode.edit.state")
	local edit_id = state.edit_id
	local estate = rpc_review()
	if not estate or estate.status ~= "pending" or estate.submitting then
		return
	end

	local input = require("opencode.ui.input")
	local token = pending.token(estate.session_id)
	local generation = view_generation
	local current = vim.api.nvim_get_current_win()
	local function finish(text)
		if generation ~= view_generation or not rpc_review() or not pending.is_current(token)
			or state.edit_id ~= edit_id or edit_state.get_edit(edit_id) ~= estate then return end
		if not edit_state.set_message(edit_id, text or "") then return end
		local ok_edits, chat_edits = pcall(require, "opencode.ui.chat.edits")
		if ok_edits and chat_edits.rerender_edit then
			views.module(state.view, chat_edits).rerender_edit(edit_id)
		end
		focus_diff_window(current)
	end

	input.show({
		view = state.view,
		winid = current,
		text = estate.message or "",
		persist_pending = false,
		add_history = false,
		on_send = finish,
		on_cancel = finish,
	})
end

local function delete_scratch_original_buffer()
	if state.original_is_scratch and state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
		pcall(vim.api.nvim_buf_delete, state.original_buf, { force = true })
	end
end

--- Close just the diff windows without resetting the full state (for file transitions)
local function close_diff_windows()
	if state.close_autocmd then
		pcall(vim.api.nvim_del_autocmd, state.close_autocmd)
		state.close_autocmd = nil
	end
	for _, mapping in ipairs(diff_mappings) do keymaps.restore(mapping) end
	diff_mappings = {}
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
	if state.provider_cleanup then state.provider_cleanup() end

	state.provider = nil
	state.provider_cleanup = nil
	state.original_buf = nil
	state.proposed_buf = nil
	state.original_win = nil
	state.proposed_win = nil
	state.tab_page = nil
	state.original_is_scratch = false
end

--- Close the diff view and clean up
function M.close()
	if not state.active then
		return
	end
	view_generation = view_generation + 1
	local generation = view_generation

	close_diff_windows()
	-- Window Neovim picked after the diff tab closed
	local landed = vim.api.nvim_get_current_win()

	-- Capture what the deferred restore needs, then start from a fresh state
	local prev_win, on_close = state.previous_winid, state.on_close
	local owner, owner_generation = state.view, state.owner_generation
	state = new_state()

	-- Restore focus to the previous window; any further focus policy belongs
	-- to the caller's on_close hook.
	vim.schedule(function()
		if generation ~= view_generation then return end
		if owner and not views.valid(owner, owner_generation) then return end
		-- Typeahead (e.g. `qi`) can move focus before this runs; restoring now
		-- would steal it, and on_close could refocus again, so leave both out.
		if vim.api.nvim_get_current_win() ~= landed then return end
		local restored = false
		if prev_win and vim.api.nvim_win_is_valid(prev_win) then
			vim.api.nvim_set_current_win(prev_win)
			restored = vim.api.nvim_get_current_win() == prev_win
		end
		if on_close then
			local ok, err = pcall(on_close, { restored = restored })
			if not ok then logger.warn("native_diff: on_close failed", { error = err }) end
		end
	end)
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
	views.module(state.view, require("opencode.ui.chat.edits")).refresh_edit(state.edit_id)
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
	local generation = view_generation
	local bufs = {}
	if state.original_buf and vim.api.nvim_buf_is_valid(state.original_buf) then
		table.insert(bufs, state.original_buf)
	end
	if state.proposed_buf and vim.api.nvim_buf_is_valid(state.proposed_buf) then
		table.insert(bufs, state.proposed_buf)
	end

	for _, buf in ipairs(bufs) do
		local bind, apply = keymaps.mapper("native_diff", buf)
		local function map(action, callback)
			bind("n", action, function()
				if generation == view_generation and (action == "close" or action == "help" or rpc_review()) then callback() end
			end)
		end

		-- <C-y>: Apply all remaining proposed hunks at once (diffget from proposed)
		map("apply_all", function()
			-- Focus the original (right) window and get all changes from proposed
			if state.provider == "codediff" then
				-- codediff draws its own diff, so there is no Vim diff mode to diffget from
				if vim.api.nvim_buf_is_valid(state.proposed_buf) and vim.api.nvim_buf_is_valid(state.original_buf) then
					local lines = vim.api.nvim_buf_get_lines(state.proposed_buf, 0, -1, false)
					vim.api.nvim_buf_set_lines(state.original_buf, 0, -1, false, lines)
				end
			elseif state.original_win and vim.api.nvim_win_is_valid(state.original_win) then
				vim.api.nvim_set_current_win(state.original_win)
				-- Apply all remaining changes using :%diffget
				local ok, err = pcall(function()
					vim.cmd("%diffget")
				end)
				if not ok then
					logger.debug("native_diff: diffget error (may be no more diffs)", { error = err })
				end
			end
		end)

		map("confirm", M._confirm_current)
		map("reject", M._reject_current)
		map("reject_all", M._reject_all)

		-- File navigation only; does not resolve, reject, or send the edit.
		map("next_file", function()
			navigate_file(1)
		end)
		map("prev_file", function()
			navigate_file(-1)
		end)

		map("note", function()
			edit_note()
		end)

		-- q: Close diff view
		map("close", function()
			M.close()
		end)

		-- ?: Show help
		map("help", function()
			local help = {
				"Native Diff Keymaps:",
				"",
				"  do       - Obtain hunk from proposed (LEFT) into actual (RIGHT)",
				"  dp       - Put hunk from actual (RIGHT) to proposed (LEFT)",
				"  ]c       - Jump to next change",
				"  [c       - Jump to previous change",
				keymaps.label("native_diff", "apply_all") .. " - Apply ALL remaining proposed hunks at once",
				keymaps.label("native_diff", "confirm") .. " - Confirm current file and continue",
				keymaps.label("native_diff", "reject") .. " - Reject current file and restore the original content",
				keymaps.label("native_diff", "reject_all") .. " - Reject all files and close",
				keymaps.label("native_diff", "next_file") .. " - Go to next file",
				keymaps.label("native_diff", "prev_file") .. " - Go to previous file",
				keymaps.label("native_diff", "note") .. " - Add or edit note",
				keymaps.label("native_diff", "close") .. " - Close diff view",
				keymaps.label("native_diff", "help") .. " - Show this help",
				"",
				"Tip: use " .. keymaps.label("native_diff", "apply_all") .. " to apply all proposed changes, then " .. keymaps.label("native_diff", "confirm") .. " to confirm.",
			}
			vim.notify(table.concat(help, "\n"), vim.log.levels.INFO)
		end)
		vim.list_extend(diff_mappings, apply())
	end
end

--- Show a specific file for diff review
---@param index number 1-based file index
function M._show_file(index)
	if not rpc_review() then return end
	local file = state.files[index]
	if not file then
		logger.warn("native_diff: invalid file index", { index = index, total = #state.files })
		return
	end
	view_generation = view_generation + 1
	local generation = view_generation

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
		local prompt = "Delete file: " .. filepath .. "?"
		require("opencode.ui.menu").open({
			items = { "Yes, delete", "No, keep" },
			title = "Delete File",
			message = prompt,
			width = vim.fn.strdisplaywidth(prompt) + 12,
			sort = false,
			on_select = function(choice)
				if generation ~= view_generation or state.current_file_index ~= index then return end
				if rpc_file_action(choice == "Yes, delete" and "accept" or "reject") then M._advance_or_finish() end
			end,
		})
		return
	end

	-- Open the actual file in a new tab (keeps the chat buffer untouched). A
	-- missing add target gets a named scratch buffer so opening review does not
	-- touch the filesystem; confirmation creates it via :write.
	local missing_add = file_type == "add" and before == "" and vim.uv.fs_stat(filepath) == nil
	local external
	if codediff.enabled() and codediff.supports(filepath) then
		local err
		external, err = codediff.open(filepath, after)
		if not external then
			logger.warn("native_diff: codediff failed, using native diff", { error = err })
		end
	end
	if external then
		state.provider, state.provider_cleanup = "codediff", external.cleanup
		state.tab_page = external.tab_page
		state.original_win, state.original_buf = external.original_win, external.original_buf
		state.proposed_win, state.proposed_buf = external.proposed_win, external.proposed_buf
		state.original_is_scratch = false
	elseif missing_add then
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
	if not external then
		state.provider = "native"
		state.original_win = vim.api.nvim_get_current_win()
		state.tab_page = vim.api.nvim_get_current_tabpage()
	end
	state.close_autocmd = vim.api.nvim_create_autocmd("TabClosed", {
		callback = function()
			if generation == view_generation and state.tab_page and not vim.api.nvim_tabpage_is_valid(state.tab_page) then
				M.close()
			end
		end,
	})

	-- Proposed content in a readonly split LEFT; focus stays on the actual
	-- file (RIGHT, editable) at its first change.
	local relative = file.relativePath or vim.fn.fnamemodify(filepath, ":t")
	if external then
		-- codediff installs its pane mappings from a scheduled render; queue
		-- ours behind it so review keys win on shared lhs such as q.
		vim.schedule(function()
			if generation == view_generation then setup_keymaps() end
		end)
	else
		state.proposed_win, state.proposed_buf = diff_pair.open(state.original_win, state.original_buf, {
			after = after,
			filepath = filepath,
			relative = relative,
		})
		setup_keymaps()
	end

	-- Show status notification
	local total = #state.files
	local status_msg = relative .. " | " .. keymaps.label("native_diff", "apply_all") .. "=apply all  "
		.. keymaps.label("native_diff", "note") .. "=note  do=get hunk  " .. keymaps.label("native_diff", "help") .. "=help"
	if total > 1 then
		status_msg = string.format("[%d/%d] %s | %s / %s=file nav", index, total, status_msg,
			keymaps.label("native_diff", "next_file"), keymaps.label("native_diff", "prev_file"))
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
	views.module(state.view, require("opencode.ui.chat.edits")).refresh_edit(state.edit_id)
	M.close()
	vim.notify("All changes rejected", vim.log.levels.INFO)
end

--- Advance to next file or finish if all files reviewed
function M._advance_or_finish()
	close_diff_windows()
	view_generation = view_generation + 1
	local generation = view_generation

	if state.current_file_index < #state.files then
		-- More files to review
		state.current_file_index = state.current_file_index + 1
		vim.schedule(function()
			if generation ~= view_generation or not rpc_review() then return end
			M._show_file(state.current_file_index)
		end)
	else
		vim.schedule(function()
			if generation ~= view_generation or not rpc_review() then return end
			M.close()
			vim.notify("All files reviewed and applied", vim.log.levels.INFO)
		end)
	end
end

---Show the native diff view for a v2 review.
---@param files table Array of {filePath, before, after, type, relativePath, diff}
---@param opts? table { view?, edit_id, file_index?, start_index?, on_close?: fun(ctx: { restored: boolean }) }
---@return boolean shown
function M.show(files, opts)
	opts = opts or {}
	if opts.view and not views.valid(opts.view) then return false end
	local edit = opts.edit_id and require("opencode.edit.state").get_edit(opts.edit_id)
	if not edit or edit.transport ~= "review_rpc" then return false end
	if edit.apply_mode == "server" then
		vim.notify("Local diff requires server.shared_filesystem=true and access to the server files. Use = for the inline proposal.", vim.log.levels.WARN)
		return false
	end

	if state.active then
		M.close()
	end

	-- Validate files
	if not files or #files == 0 then
		logger.warn("native_diff: no files to show")
		vim.notify("No files to review in this diff request", vim.log.levels.WARN)
		return false
	end

	-- Save current window for restoration
	state.previous_winid = vim.api.nvim_get_current_win()
	state.on_close = opts.on_close

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
	state.review, state.token = edit, pending.token(edit.session_id)
	local owner = opts.view or views.current()
	state.view = opts.view or (views.session(owner).id == edit.session_id and owner or nil)
	state.owner_generation = state.view and state.view.generation

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
