-- opencode.nvim - Edit tracking module
-- Track pending file edits from AI suggestions

local M = {}

-- State
local state = {
	changes = {},
	active_change_id = nil,
	next_id = 1,
}

-- Default configuration
local defaults = {
	auto_backup = true,
	backup_dir = vim.fn.stdpath("cache") .. "/opencode/backups",
	max_changes = 100,
	confirm_destructive = true,
	file_patterns_to_confirm = {
		"%.env",
		"%.env%.",
		"config",
		"%.conf",
		"%.toml$",
		"%.yaml$",
		"%.yml$",
		"%.json$",
		"package%.json",
		"Cargo%.toml",
		"go%.mod",
	},
}

-- Change statuses
M.STATUS = {
	PENDING = "pending",
	ACCEPTED = "accepted",
	REJECTED = "rejected",
	RESOLVED = "resolved",
	APPLIED = "applied",
	FAILED = "failed",
	CONFLICT = "conflict",
}

-- Emit change update event
local function emit_change_event(event_type, change_id, data)
	vim.schedule(function()
		vim.api.nvim_exec_autocmds("User", {
			pattern = "OpenCodeChanges" .. event_type,
			data = vim.tbl_extend("force", {
				change_id = change_id,
			}, data or {}),
		})
	end)
end

-- Generate unique change ID
local function generate_id()
	local id = string.format("change_%d_%d", os.time(), state.next_id)
	state.next_id = state.next_id + 1
	return id
end

-- Check if file should trigger confirmation
local function needs_confirmation(filepath)
	for _, pattern in ipairs(defaults.file_patterns_to_confirm) do
		if filepath:match(pattern) then
			return true
		end
	end
	return false
end

-- Create backup of file
local function backup_file(filepath)
	if not defaults.auto_backup then
		return nil
	end

	vim.fn.mkdir(defaults.backup_dir, "p")

	local backup_name = string.format("%s_%s.bak",
		vim.fn.fnamemodify(filepath, ":t"),
		os.time()
	)
	local backup_path = defaults.backup_dir .. "/" .. backup_name

	-- Read original file
	local file = io.open(filepath, "r")
	if not file then
		return nil
	end

	local content = file:read("*all")
	file:close()

	-- Write backup
	local backup = io.open(backup_path, "w")
	if backup then
		backup:write(content)
		backup:close()
		return backup_path
	end

	return nil
end

-- Calculate diff stats
local function calc_stats(original_lines, modified_lines)
	local added = 0
	local removed = 0
	local modified = 0

	local max_lines = math.max(#original_lines, #modified_lines)
	local i = 1

	while i <= max_lines do
		local orig = original_lines[i] or ""
		local mod = modified_lines[i] or ""

		if orig == "" and mod ~= "" then
			added = added + 1
		elseif orig ~= "" and mod == "" then
			removed = removed + 1
		elseif orig ~= mod then
			modified = modified + 1
		end

		i = i + 1
	end

	return { added = added, removed = removed, modified = modified }
end

-- Add a new change
function M.add_change(filepath, original_content, modified_content, opts)
	opts = opts or {}

	-- Check max changes
	if #state.changes >= defaults.max_changes then
		table.remove(state.changes, 1)
	end

	-- Backup original
	local backup_path = backup_file(filepath)

	-- Parse content into lines
	local original_lines = vim.split(original_content, "\n", { plain = true })
	local modified_lines = vim.split(modified_content, "\n", { plain = true })

	-- Calculate diff hunks
	local hunks = M.calculate_hunks(original_lines, modified_lines)

	-- Create change record
	local change = {
		id = generate_id(),
		filepath = filepath,
		filename = vim.fn.fnamemodify(filepath, ":t"),
		original_content = original_content,
		modified_content = modified_content,
		original_lines = original_lines,
		modified_lines = modified_lines,
		backup_path = backup_path,
		stats = calc_stats(original_lines, modified_lines),
		hunks = hunks,
		status = M.STATUS.PENDING,
		timestamp = os.time(),
		requires_confirm = needs_confirmation(filepath),
		metadata = opts.metadata or {},
	}

	table.insert(state.changes, change)
	state.active_change_id = change.id

	return change.id
end

-- Calculate diff hunks using simple algorithm
function M.calculate_hunks(original_lines, modified_lines)
	local hunks = {}
	local i = 1
	local orig_len = #original_lines
	local mod_len = #modified_lines

	while i <= orig_len or i <= mod_len do
		local orig = original_lines[i]
		local mod = modified_lines[i]

		-- Found a difference
		if orig ~= mod then
			local hunk = {
				start_line = i,
				original_lines = {},
				modified_lines = {},
				status = M.STATUS.PENDING,
			}

			-- Collect changed lines
			while i <= orig_len or i <= mod_len do
				local o = original_lines[i] or ""
				local m = modified_lines[i] or ""

				-- Check if we're back in sync
				if o == m and #hunk.original_lines > 0 then
					-- Look ahead to confirm it's not a temporary match
					local look_ahead = 3
					local still_synced = true
					for j = 1, look_ahead do
						if original_lines[i + j] ~= modified_lines[i + j] then
							still_synced = false
							break
						end
					end

					if still_synced then
						break
					end
				end

				table.insert(hunk.original_lines, o)
				table.insert(hunk.modified_lines, m)
				i = i + 1
			end

			hunk.end_line = i - 1
			hunk.line_count = #hunk.original_lines
			table.insert(hunks, hunk)
		else
			i = i + 1
		end
	end

	return hunks
end

-- Get all changes
function M.get_all()
	return vim.deepcopy(state.changes)
end

-- Get change by ID
function M.get(id)
	for _, change in ipairs(state.changes) do
		if change.id == id then
			return vim.deepcopy(change)
		end
	end
	return nil
end

-- Get active change
function M.get_active()
	return M.get(state.active_change_id)
end

-- Update change status
function M.update_status(id, status, opts)
	opts = opts or {}

	for _, change in ipairs(state.changes) do
		if change.id == id then
			change.status = status
			if opts.message then
				change.status_message = opts.message
			end
			if opts.hunk_index and change.hunks[opts.hunk_index] then
				change.hunks[opts.hunk_index].status = status
			end
			return true
		end
	end
	return false
end

-- Accept a change
function M.accept(id, opts)
	opts = opts or {}

	local change = M.get(id)
	if not change then
		return false, "Change not found"
	end

	if change.status == M.STATUS.APPLIED then
		return false, "Change already applied"
	end

	-- Confirm if required
	if change.requires_confirm and defaults.confirm_destructive and not opts.force then
		return false, "Confirmation required"
	end

	-- Debug logging
	vim.schedule(function()
		vim.notify(string.format("[DEBUG] Writing file: %s (content length: %d)", 
			change.filepath, #change.modified_content), vim.log.levels.INFO)
	end)

	-- Apply change
	local ok, err = pcall(function()
		local file = io.open(change.filepath, "w")
		if not file then
			error("Cannot open file for writing: " .. change.filepath)
		end
		file:write(change.modified_content)
		file:close()
		vim.schedule(function()
			vim.notify("[DEBUG] File written successfully", vim.log.levels.INFO)
		end)
	end)

	if not ok then
		M.update_status(id, M.STATUS.FAILED, { message = err })
		vim.schedule(function()
			vim.notify("[DEBUG] Failed to write file: " .. tostring(err), vim.log.levels.ERROR)
		end)
		return false, err
	end

	-- Reload buffer if file is open
	vim.schedule(function()
		local bufnr = vim.fn.bufnr(change.filepath)
		if bufnr ~= -1 then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("checktime")
			end)
			vim.notify("[DEBUG] Buffer reloaded for: " .. change.filepath, vim.log.levels.INFO)
		end
	end)

	M.update_status(id, M.STATUS.APPLIED)
	emit_change_event("Accepted", id, { status = M.STATUS.APPLIED })
	return true
end

-- Accept specific hunk
function M.accept_hunk(change_id, hunk_index)
	local change = M.get(change_id)
	if not change then
		return false, "Change not found"
	end

	if not change.hunks[hunk_index] then
		return false, "Hunk not found"
	end

	-- For now, mark as accepted but don't apply partially
	-- Full implementation would require applying specific line ranges
	change.hunks[hunk_index].status = M.STATUS.ACCEPTED
	M.update_status(change_id, M.STATUS.PENDING)

	return true
end

-- Reject a change (revert file to original content)
function M.reject(id)
	local change = M.get(id)
	if not change then
		return false, "Change not found"
	end

	-- Revert file to original content
	local ok, err = pcall(function()
		local file = io.open(change.filepath, "w")
		if not file then
			error("Cannot open file for writing: " .. change.filepath)
		end
		file:write(change.original_content)
		file:close()
	end)

	if not ok then
		M.update_status(id, M.STATUS.FAILED, { message = err })
		return false, err
	end

	-- Reload buffer if file is open
	vim.schedule(function()
		local bufnr = vim.fn.bufnr(change.filepath)
		if bufnr ~= -1 then
			vim.api.nvim_buf_call(bufnr, function()
				vim.cmd("checktime")
			end)
		end
	end)

	M.update_status(id, M.STATUS.REJECTED)
	emit_change_event("Rejected", id, { status = M.STATUS.REJECTED })
	return true
end

-- Resolve a change manually (mark as resolved without touching the file)
function M.resolve_manually(id)
	local ok = M.update_status(id, M.STATUS.RESOLVED)
	if ok then
		emit_change_event("Resolved", id, { status = M.STATUS.RESOLVED })
	end
	return ok
end

-- Reject specific hunk
function M.reject_hunk(change_id, hunk_index)
	local change = M.get(change_id)
	if not change or not change.hunks[hunk_index] then
		return false
	end

	change.hunks[hunk_index].status = M.STATUS.REJECTED
	return true
end

-- Clear all changes
function M.clear()
	state.changes = {}
	state.active_change_id = nil
	return true
end

-- Remove a specific change
function M.remove(id)
	for i, change in ipairs(state.changes) do
		if change.id == id then
			table.remove(state.changes, i)
			if state.active_change_id == id then
				state.active_change_id = nil
			end
			return true
		end
	end
	return false
end

-- Get stats summary
function M.get_stats()
	local stats = {
		total = #state.changes,
		pending = 0,
		accepted = 0,
		rejected = 0,
		applied = 0,
		failed = 0,
		files = {},
	}

	for _, change in ipairs(state.changes) do
		stats[change.status] = (stats[change.status] or 0) + 1
		table.insert(stats.files, {
			filepath = change.filepath,
			filename = change.filename,
			status = change.status,
			added = change.stats.added,
			removed = change.stats.removed,
		})
	end

	return stats
end

-- Format change for display
function M.format_change(change, opts)
	opts = opts or {}
	local lines = {}
	local highlights = {}

	if not change then
		return lines, highlights
	end

	-- Header line
	local status_icon = "○"
	if change.status == M.STATUS.ACCEPTED or change.status == M.STATUS.APPLIED then
		status_icon = "✓"
	elseif change.status == M.STATUS.REJECTED then
		status_icon = "✗"
	elseif change.status == M.STATUS.FAILED then
		status_icon = "!"
	end

	table.insert(lines, string.format("%s %s (+%d/-%d)",
		status_icon,
		change.filename,
		change.stats.added,
		change.stats.removed
	))

	-- Status highlight
	local hl_group = "Normal"
	if change.status == M.STATUS.ACCEPTED or change.status == M.STATUS.APPLIED then
		hl_group = "DiffAdd"
	elseif change.status == M.STATUS.REJECTED then
		hl_group = "DiffDelete"
	elseif change.status == M.STATUS.FAILED then
		hl_group = "Error"
	elseif change.status == M.STATUS.PENDING then
		hl_group = "Search"
	end

	table.insert(highlights, {
		line = #lines - 1,
		col_start = 0,
		col_end = 1,
		hl_group = hl_group,
	})

	table.insert(highlights, {
		line = #lines - 1,
		col_start = 2,
		col_end = 2 + #change.filename,
		hl_group = "Function",
	})

	-- Hunks (if expanded)
	if opts.show_hunks then
		for i, hunk in ipairs(change.hunks) do
			table.insert(lines, string.format("  Hunk %d: lines %d-%d", i, hunk.start_line, hunk.end_line))
			local hunk_hl = "Comment"
			if hunk.status == M.STATUS.ACCEPTED then
				hunk_hl = "DiffAdd"
			elseif hunk.status == M.STATUS.REJECTED then
				hunk_hl = "DiffDelete"
			end
			table.insert(highlights, {
				line = #lines - 1,
				col_start = 0,
				col_end = -1,
				hl_group = hunk_hl,
			})
		end
	end

	return lines, highlights
end

-- Restore from backup
function M.restore_backup(change_id)
	local change = M.get(change_id)
	if not change or not change.backup_path then
		return false, "No backup available"
	end

	local backup = io.open(change.backup_path, "r")
	if not backup then
		return false, "Backup file not found"
	end

	local content = backup:read("*all")
	backup:close()

	local file = io.open(change.filepath, "w")
	if not file then
		return false, "Cannot open file for writing"
	end

	file:write(content)
	file:close()

	return true
end

-- Setup function
function M.setup(opts)
	if opts then
		if opts.auto_backup ~= nil then
			defaults.auto_backup = opts.auto_backup
		end
		if opts.backup_dir then
			defaults.backup_dir = opts.backup_dir
		end
		if opts.max_changes then
			defaults.max_changes = opts.max_changes
		end
		if opts.confirm_destructive ~= nil then
			defaults.confirm_destructive = opts.confirm_destructive
		end
		if opts.file_patterns_to_confirm then
			defaults.file_patterns_to_confirm = opts.file_patterns_to_confirm
		end
	end
end

return M
