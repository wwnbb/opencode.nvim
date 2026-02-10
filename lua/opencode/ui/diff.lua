-- opencode.nvim - Diff viewer UI module
-- Three-panel diff interface for reviewing changes

local M = {}

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local event = require("nui.utils.autocmd").event
local diff_hl_ns = vim.api.nvim_create_namespace("opencode_diff_hl")

-- State
local state = {
	bufnr = nil,
	winid = nil,
	layout = nil,
	visible = false,
	change_id = nil,
	file_list_bufnr = nil,
	diff_bufnr = nil,
	current_hunk = 1,
	config = nil,
	previous_winid = nil,  -- Store previous window to restore focus
}

-- Default configuration
local defaults = {
	layout = "vertical", -- "vertical" | "horizontal"
	file_list_width = 30,
	diff_height = 20,
	border = "rounded",
	keymaps = {
		close = "q",
		next_hunk = "]c",
		prev_hunk = "[c",
		accept_hunk = "a",
		reject_hunk = "x",
		accept_all = "<C-a>",
		reject_all = "<C-x>",
		goto_file = "gf",
		toggle_file_list = "<C-f>",
	},
}

-- Diff highlighting
local function setup_diff_highlights(bufnr)
	local ns_id = vim.api.nvim_create_namespace("opencode_diff")
	
	-- Clear existing
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
	
	-- Define highlight groups
	vim.cmd([[
		highlight default DiffAdd guibg=#2d4a3e guifg=#a8f0c6
		highlight default DiffDelete guibg=#4a2d3a guifg=#f0a8b8
		highlight default DiffChange guibg=#4a3d2d guifg=#f0d8a8
		highlight default DiffLineAdded guibg=#2d4a3e
		highlight default DiffLineRemoved guibg=#4a2d3a
	]])
end

-- Render diff hunks
local function render_hunk(hunk, bufnr, start_line)
	local lines = {}
	local highlights = {}
	
	-- Hunk header
	table.insert(lines, string.format("@@ -%d,%d +%d,%d @@", 
		hunk.start_line, #hunk.original_lines,
		hunk.start_line, #hunk.modified_lines))
	table.insert(highlights, { line = start_line, col_start = 0, col_end = -1, hl_group = "Title" })
	
	-- Original lines (removed)
	for i, line in ipairs(hunk.original_lines) do
		if line ~= "" then
			table.insert(lines, "-" .. line)
			table.insert(highlights, { 
				line = start_line + #lines - 1, 
				col_start = 0, 
				col_end = -1, 
				hl_group = "DiffDelete" 
			})
		end
	end
	
	-- Modified lines (added)
	for i, line in ipairs(hunk.modified_lines) do
		if line ~= "" then
			table.insert(lines, "+" .. line)
			table.insert(highlights, { 
				line = start_line + #lines - 1, 
				col_start = 0, 
				col_end = -1, 
				hl_group = "DiffAdd" 
			})
		end
	end
	
	-- Empty line separator
	table.insert(lines, "")
	
	return lines, highlights
end

-- Render full diff
local function render_diff(change)
	if not change or not state.diff_bufnr then
		return
	end
	
	local lines = {}
	local highlights = {}
	
	-- Header
	table.insert(lines, string.format(" Diff: %s", change.filename))
	table.insert(lines, string.format(" Status: %s | +%d/-%d",
		change.status, change.stats.added, change.stats.removed))

	-- Show multi-file progress if applicable
	local events = require("opencode.events")
	if events._pending_permission and events._pending_permission.change_ids then
		local pending = events._pending_permission
		local current_idx = pending.current_index or 1
		local total = #pending.change_ids
		if total > 1 then
			table.insert(lines, string.format(" File %d of %d in this edit request", current_idx, total))
		end
	end

	table.insert(lines, string.rep("─", 60))
	table.insert(lines, "")
	
	-- Instructions
	table.insert(lines, " Keymaps: a=accept hunk, x=reject hunk, ]c/[c=next/prev, q=close")
	table.insert(lines, "")
	
	-- Hunks
	for i, hunk in ipairs(change.hunks) do
		if i == state.current_hunk then
			table.insert(lines, string.format(">>> Hunk %d/%d (current) <<<", i, #change.hunks))
		else
			table.insert(lines, string.format("    Hunk %d/%d", i, #change.hunks))
		end
		
		local hunk_lines, hunk_highlights = render_hunk(hunk, state.diff_bufnr, #lines)
		for _, line in ipairs(hunk_lines) do
			table.insert(lines, line)
		end
		for _, hl in ipairs(hunk_highlights) do
			hl.line = hl.line + (#lines - #hunk_lines)
			table.insert(highlights, hl)
		end
	end
	
	-- Set content
	vim.bo[state.diff_bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.diff_bufnr, 0, -1, false, lines)
	
	-- Apply highlights
	for _, hl in ipairs(highlights) do
		local end_col = hl.col_end or -1
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(state.diff_bufnr, hl.line, hl.line + 1, false)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(state.diff_bufnr, diff_hl_ns, hl.line, hl.col_start, { end_col = end_col, hl_group = hl.hl_group })
	end
	
	vim.bo[state.diff_bufnr].modifiable = false
	vim.bo[state.diff_bufnr].filetype = "diff"
end

-- Render file list
local function render_file_list(changes)
	if not state.file_list_bufnr then
		return
	end
	
	local lines = {}
	local highlights = {}
	
	table.insert(lines, " Files:")
	table.insert(highlights, { line = 0, col_start = 0, col_end = -1, hl_group = "Title" })
	table.insert(lines, "")
	
	for i, change in ipairs(changes) do
		local icon = "○"
		local hl = "Normal"
		
		if change.status == "accepted" or change.status == "applied" then
			icon = "✓"
			hl = "DiffAdd"
		elseif change.status == "rejected" then
			icon = "✗"
			hl = "DiffDelete"
		elseif change.status == "failed" then
			icon = "!"
			hl = "Error"
		elseif change.id == state.change_id then
			icon = ">"
			hl = "Search"
		end
		
		local line = string.format(" %s %s", icon, change.filename)
		table.insert(lines, line)
		table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = 2, hl_group = hl })
	end
	
	vim.bo[state.file_list_bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.file_list_bufnr, 0, -1, false, lines)
	
	for _, hl in ipairs(highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(state.file_list_bufnr, hl.line, hl.line + 1, false)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(state.file_list_bufnr, diff_hl_ns, hl.line, hl.col_start, { end_col = end_col, hl_group = hl.hl_group })
	end
	
	vim.bo[state.file_list_bufnr].modifiable = false
end

-- Setup keymaps for diff buffer
local function setup_keymaps(bufnr)
	local cfg = state.config
	local opts = { buffer = bufnr, noremap = true, silent = true }
	local changes = require("opencode.artifact.changes")
	
	-- Close
	vim.keymap.set("n", cfg.keymaps.close, function()
		M.close()
	end, opts)
	
	-- Navigate hunks
	vim.keymap.set("n", cfg.keymaps.next_hunk, function()
		local change = changes.get(state.change_id)
		if change and state.current_hunk < #change.hunks then
			state.current_hunk = state.current_hunk + 1
			render_diff(change)
		end
	end, opts)
	
	vim.keymap.set("n", cfg.keymaps.prev_hunk, function()
		if state.current_hunk > 1 then
			state.current_hunk = state.current_hunk - 1
			local change = changes.get(state.change_id)
			render_diff(change)
		end
	end, opts)
	
	-- Accept/reject hunks
	vim.keymap.set("n", cfg.keymaps.accept_hunk, function()
		changes.accept_hunk(state.change_id, state.current_hunk)
		vim.notify("Hunk accepted (press <C-a> to apply all changes to file)", vim.log.levels.INFO)
		local change = changes.get(state.change_id)
		render_diff(change)
	end, opts)
	
	vim.keymap.set("n", cfg.keymaps.reject_hunk, function()
		changes.reject_hunk(state.change_id, state.current_hunk)
		vim.notify("Hunk rejected", vim.log.levels.INFO)
		local change = changes.get(state.change_id)
		render_diff(change)
	end, opts)
	
	-- Accept/reject all
	vim.keymap.set("n", cfg.keymaps.accept_all, function()
		-- Get the change to find the permission_id from metadata
		local change = changes.get(state.change_id)
		local permission_id = nil
		if change and change.metadata and change.metadata.permission_id then
			permission_id = change.metadata.permission_id
		end

		-- Also check events._pending_permission as fallback
		local events = require("opencode.events")
		if not permission_id and events._pending_permission and events._pending_permission.id then
			permission_id = events._pending_permission.id
		end

		-- Debug output
		vim.notify(string.format("[DEBUG] Accept triggered: change_id=%s, permission_id=%s",
			tostring(state.change_id), tostring(permission_id)), vim.log.levels.INFO)

		local ok, err = changes.accept(state.change_id)
		vim.notify(string.format("[DEBUG] Accept result: ok=%s, err=%s",
			tostring(ok), tostring(err)), vim.log.levels.INFO)
		if ok then
			-- Check if there are more files in this permission request
			local pending = events._pending_permission
			if pending and pending.change_ids and #pending.change_ids > 1 then
				-- Find current index and move to next
				local current_idx = pending.current_index or 1
				local next_idx = current_idx + 1

				if chat_ok then
					chat.add_message("system", string.format("[DEBUG] Multi-file: %d/%d, next_idx=%d",
						current_idx, #pending.change_ids, next_idx),
						{ id = "debug_multi_" .. os.time() })
				end

				if next_idx <= #pending.change_ids then
					-- More files to approve - show next diff
					pending.current_index = next_idx
					local next_change_id = pending.change_ids[next_idx]

					if chat_ok then
						chat.add_message("system", "[DEBUG] Showing next file: " .. tostring(next_change_id),
							{ id = "debug_next_file_" .. os.time() })
					end

					vim.notify(string.format("File %d/%d accepted. Showing next file...", current_idx, #pending.change_ids), vim.log.levels.INFO)

					-- Close current and show next
					M.close()
					vim.schedule(function()
						M.show(next_change_id)
					end)
					return
				end
			end

			-- All files approved (or single file) - send permission reply to server
			if permission_id then
				local client = require("opencode.client")
				if chat_ok then
					chat.add_message("system", "[DEBUG] All files approved, sending permission reply: " .. permission_id,
						{ id = "debug_reply_" .. os.time() })
				end
				client.respond_permission(permission_id, "once", {}, function(reply_err, result)
					vim.schedule(function()
						if reply_err then
							vim.notify("Failed to send approval to server: " .. vim.inspect(reply_err), vim.log.levels.WARN)
							if chat_ok then
								chat.add_message("system", "[DEBUG] Reply error: " .. vim.inspect(reply_err),
									{ id = "debug_reply_err_" .. os.time() })
							end
						else
							vim.notify("All changes accepted and approved", vim.log.levels.INFO)
							if chat_ok then
								chat.add_message("system", "[DEBUG] Reply success: " .. vim.inspect(result),
									{ id = "debug_reply_ok_" .. os.time() })
							end
						end
					end)
				end)
				-- Clear the pending permission
				events._pending_permission = nil
			else
				vim.notify("Changes accepted (no permission to confirm)", vim.log.levels.INFO)
			end
			M.close()
		else
			vim.notify("Failed to accept: " .. tostring(err), vim.log.levels.ERROR)
		end
	end, opts)

	vim.keymap.set("n", cfg.keymaps.reject_all, function()
		-- Get the change to find the permission_id from metadata
		local change = changes.get(state.change_id)
		local permission_id = nil
		if change and change.metadata and change.metadata.permission_id then
			permission_id = change.metadata.permission_id
		end

		-- Also check events._pending_permission as fallback
		local events = require("opencode.events")
		if not permission_id and events._pending_permission and events._pending_permission.id then
			permission_id = events._pending_permission.id
		end

		changes.reject(state.change_id)

		-- Send permission rejection to server (rejects all files in the permission)
		if permission_id then
			local client = require("opencode.client")
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok then
				chat.add_message("system", "[DEBUG] Rejecting permission: " .. permission_id,
					{ id = "debug_reject_" .. os.time() })
			end
			client.respond_permission(permission_id, "reject", {}, function(reply_err, _)
				vim.schedule(function()
					if reply_err then
						vim.notify("Failed to send rejection to server: " .. vim.inspect(reply_err), vim.log.levels.WARN)
					else
						vim.notify("Changes rejected", vim.log.levels.INFO)
					end
				end)
			end)
			-- Clear the pending permission (rejects all files at once)
			events._pending_permission = nil
		else
			vim.notify("Changes rejected (no permission to confirm)", vim.log.levels.INFO)
		end
		M.close()
	end, opts)
	
	-- Go to file
	vim.keymap.set("n", cfg.keymaps.goto_file, function()
		local change = changes.get(state.change_id)
		if change then
			M.close()
			vim.cmd("edit " .. vim.fn.fnameescape(change.filepath))
		end
	end, opts)
	
	-- Show help
	vim.keymap.set("n", "?", function()
		local help_text = {
			"Diff Viewer Keymaps:",
			"",
			"  a        - Accept current hunk",
			"  x        - Reject current hunk",
			"  <C-a>    - Accept ALL changes and write file",
			"  <C-x>    - Reject ALL changes",
			"  ]c       - Next hunk",
			"  [c       - Previous hunk",
			"  gf       - Go to file in editor",
			"  q        - Close diff viewer",
			"  ?        - Show this help",
			"",
			"Note: After accepting hunks with 'a', you must",
			"      press <C-a> to actually write the file.",
		}
		vim.notify(table.concat(help_text, "\n"), vim.log.levels.INFO)
	end, opts)
end

-- Show diff viewer
function M.show(change_id, opts)
	opts = opts or {}

	-- Save current window to restore focus later
	state.previous_winid = vim.api.nvim_get_current_win()

	if state.visible then
		M.close()
	end

	local changes = require("opencode.artifact.changes")
	local change = changes.get(change_id)
	if not change then
		vim.notify("Change not found: " .. tostring(change_id), vim.log.levels.ERROR)
		return
	end
	
	state.change_id = change_id
	state.current_hunk = 1
	state.config = vim.tbl_deep_extend("force", defaults, opts.config or {})
	
	-- Get dimensions
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	
	if state.config.layout == "vertical" then
		-- Side-by-side layout
		local total_width = math.min(100, ui.width - 4)
		local file_list_width = state.config.file_list_width
		local diff_width = total_width - file_list_width - 2
		local height = math.min(30, ui.height - 4)
		local row = math.floor((ui.height - height) / 2)
		local col = math.floor((ui.width - total_width) / 2)
		
		-- Create file list popup
		state.file_list_bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[state.file_list_bufnr].buftype = "nofile"
		vim.bo[state.file_list_bufnr].bufhidden = "wipe"
		vim.bo[state.file_list_bufnr].filetype = "opencode_diff_files"
		
		local file_list_popup = Popup({
			enter = false,
			focusable = true,
			border = {
				style = state.config.border,
				text = { top = " Files ", top_align = "center" },
			},
			position = { row = row, col = col },
			size = { width = file_list_width, height = height },
			bufnr = state.file_list_bufnr,
		})
		
		-- Create diff popup
		state.diff_bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[state.diff_bufnr].buftype = "nofile"
		vim.bo[state.diff_bufnr].bufhidden = "wipe"
		vim.bo[state.diff_bufnr].filetype = "diff"
		
		local diff_popup = Popup({
			enter = true,
			focusable = true,
			border = {
				style = state.config.border,
				text = {
					top = " Diff ",
					top_align = "center",
					bottom = " a=accept hunk, <C-a>=apply file, x=reject, ?=help ",
					bottom_align = "center",
				},
			},
			position = { row = row, col = col + file_list_width + 2 },
			size = { width = diff_width, height = height },
			bufnr = state.diff_bufnr,
		})
		
		-- Create layout
		state.layout = Layout(
			{ relative = "editor", position = { row = row, col = col }, size = { width = total_width, height = height } },
			Layout.Box({
				Layout.Box(file_list_popup, { size = { width = file_list_width } }),
				Layout.Box(diff_popup, { size = "50%" }),
			}, { dir = "row" })
		)
		
		state.layout:mount()
		state.winid = diff_popup.winid
		
		-- Render content
		render_file_list(changes.get_all())
		render_diff(change)
		setup_diff_highlights(state.diff_bufnr)
		setup_keymaps(state.diff_bufnr)
		
		-- Show initial help hint
		vim.notify("Diff viewer: a=accept hunk, <C-a>=apply file, ?=help", vim.log.levels.INFO)
	else
		-- Horizontal layout (stacked)
		local width = math.min(80, ui.width - 4)
		local file_list_height = math.min(10, math.max(5, #changes.get_all() + 2))
		local diff_height = state.config.diff_height
		local total_height = file_list_height + diff_height + 4
		local row = math.floor((ui.height - total_height) / 2)
		local col = math.floor((ui.width - width) / 2)
		
		-- Create popups
		state.file_list_bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[state.file_list_bufnr].buftype = "nofile"
		vim.bo[state.file_list_bufnr].filetype = "opencode_diff_files"
		
		state.diff_bufnr = vim.api.nvim_create_buf(false, true)
		vim.bo[state.diff_bufnr].buftype = "nofile"
		vim.bo[state.diff_bufnr].filetype = "diff"
		
		local file_list_popup = Popup({
			enter = false,
			focusable = false,
			border = { style = state.config.border, text = { top = " Files " } },
			position = { row = row, col = col },
			size = { width = width, height = file_list_height },
			bufnr = state.file_list_bufnr,
		})
		
		local diff_popup = Popup({
			enter = true,
			focusable = true,
			border = {
				style = state.config.border,
				text = {
					top = " Diff ",
					bottom = " a=accept hunk, <C-a>=apply file, x=reject, ?=help ",
					bottom_align = "center",
				},
			},
			position = { row = row + file_list_height + 2, col = col },
			size = { width = width, height = diff_height },
			bufnr = state.diff_bufnr,
		})
		
		state.layout = Layout(
			{ relative = "editor", position = { row = row, col = col }, size = { width = width, height = total_height } },
			Layout.Box({
				Layout.Box(file_list_popup, { size = file_list_height }),
				Layout.Box(diff_popup, { size = "50%" }),
			}, { dir = "col" })
		)
		
		state.layout:mount()
		state.winid = diff_popup.winid
		
		render_file_list(changes.get_all())
		render_diff(change)
		setup_diff_highlights(state.diff_bufnr)
		setup_keymaps(state.diff_bufnr)
		
		-- Show initial help hint
		vim.notify("Diff viewer: a=accept hunk, <C-a>=apply file, ?=help", vim.log.levels.INFO)
	end
	
	state.visible = true
	
	-- Auto-update when changes change
	vim.api.nvim_create_autocmd("User", {
		pattern = "OpenCodeChangesUpdated",
		callback = function()
			if state.visible then
				render_diff(changes.get(state.change_id))
				render_file_list(changes.get_all())
			end
		end,
	})
end

-- Close diff viewer
function M.close()
	if not state.visible then
		return
	end

	if state.layout then
		state.layout:unmount()
	end

	state.visible = false
	state.winid = nil
	state.layout = nil
	state.file_list_bufnr = nil
	state.diff_bufnr = nil
	state.change_id = nil

	-- Restore focus to previous window (chat) and open input
	vim.schedule(function()
		if state.previous_winid and vim.api.nvim_win_is_valid(state.previous_winid) then
			vim.api.nvim_set_current_win(state.previous_winid)
		end
		state.previous_winid = nil

		-- Open the input popup so user can continue chatting
		local chat_ok, chat = pcall(require, "opencode.ui.chat")
		if chat_ok and chat.focus_input then
			chat.focus_input()
		end
	end)
end

-- Check if visible
function M.is_visible()
	return state.visible
end

-- Update current change
function M.update_change(change_id)
	if state.visible and state.change_id == change_id then
		local changes = require("opencode.artifact.changes")
		render_diff(changes.get(change_id))
		render_file_list(changes.get_all())
	end
end

-- Setup configuration
function M.setup(opts)
	if opts then
		defaults = vim.tbl_deep_extend("force", defaults, opts)
	end
end

return M
