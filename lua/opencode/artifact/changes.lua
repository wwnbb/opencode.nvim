-- opencode.nvim - Pending file change tracker

local M = {}

local state = {
	changes = {},
	active_change_id = nil,
	next_id = 1,
}

local DEFAULTS = {
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

local defaults = vim.deepcopy(DEFAULTS)

---@enum OpenCodeChangeStatus
M.STATUS = {
	PENDING = "pending",
	ACCEPTED = "accepted",
	REJECTED = "rejected",
	RESOLVED = "resolved",
	APPLIED = "applied",
	FAILED = "failed",
	CONFLICT = "conflict",
}

---@param fn function
local function schedule(fn)
	if vim.in_fast_event and vim.in_fast_event() then
		vim.schedule(fn)
		return
	end
	fn()
end

---@param event_type string
---@param change_id string
---@param data? table
local function emit_change_event(event_type, change_id, data)
	schedule(function()
		pcall(vim.api.nvim_exec_autocmds, "User", {
			pattern = "OpenCodeChanges" .. event_type,
			data = vim.tbl_extend("force", { change_id = change_id }, data or {}),
		})
	end)
end

---@return string
local function generate_id()
	local id = string.format("change_%d_%d", os.time(), state.next_id)
	state.next_id = state.next_id + 1
	return id
end

---@return integer
local function get_max_changes()
	local max_changes = tonumber(defaults.max_changes) or DEFAULTS.max_changes
	return math.max(1, math.floor(max_changes))
end

---@param filepath string
---@return boolean
local function needs_confirmation(filepath)
	if type(filepath) ~= "string" then
		return false
	end

	for _, pattern in ipairs(defaults.file_patterns_to_confirm or {}) do
		if filepath:match(pattern) then
			return true
		end
	end
	return false
end

---@param filepath string
---@return string|nil content
---@return string|nil err
local function read_file(filepath)
	local file, err = io.open(filepath, "r")
	if not file then
		return nil, err
	end

	local content = file:read("*all") or ""
	file:close()
	return content, nil
end

---@param filepath string
---@param content string
---@return boolean ok
---@return string|nil err
local function write_file(filepath, content)
	if type(filepath) ~= "string" or filepath == "" then
		return false, "Invalid file path"
	end

	local dir = vim.fn.fnamemodify(filepath, ":h")
	if dir and dir ~= "" then
		vim.fn.mkdir(dir, "p")
	end

	local file, open_err = io.open(filepath, "w")
	if not file then
		return false, open_err or ("Cannot open file for writing: " .. filepath)
	end

	local ok, write_err = pcall(function()
		file:write(content or "")
	end)
	local close_ok, close_err = file:close()
	if not ok then
		return false, tostring(write_err)
	end
	if not close_ok then
		return false, tostring(close_err)
	end
	return true, nil
end

---@param filepath string
---@param change_id string
---@return string|nil backup_path
local function backup_file(filepath, change_id)
	if not defaults.auto_backup or type(filepath) ~= "string" or filepath == "" then
		return nil
	end
	if vim.fn.filereadable(filepath) ~= 1 then
		return nil
	end

	local content = read_file(filepath)
	if content == nil then
		return nil
	end

	vim.fn.mkdir(defaults.backup_dir, "p")
	local filename = vim.fn.fnamemodify(filepath, ":t")
	local backup_path = string.format("%s/%s_%s.bak", defaults.backup_dir, filename, change_id)
	local ok = write_file(backup_path, content)
	if not ok then
		return nil
	end
	return backup_path
end

---@param filepath string
local function reload_buffer(filepath)
	schedule(function()
		local bufnr = vim.fn.bufnr(filepath)
		if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		pcall(vim.api.nvim_buf_call, bufnr, function()
			vim.cmd("checktime")
		end)
	end)
end

---@param original_lines string[]
---@param modified_lines string[]
---@return table
local function calc_stats(original_lines, modified_lines)
	local added = 0
	local removed = 0
	local modified = 0
	local max_lines = math.max(#original_lines, #modified_lines)

	for i = 1, max_lines do
		local original = original_lines[i]
		local changed = modified_lines[i]
		if original == nil and changed ~= nil then
			added = added + 1
		elseif original ~= nil and changed == nil then
			removed = removed + 1
		elseif original ~= changed then
			modified = modified + 1
		end
	end

	return { added = added, removed = removed, modified = modified }
end

---@param id string
---@return table|nil change
---@return integer|nil index
local function find_change(id)
	if not id then
		return nil, nil
	end

	for index, change in ipairs(state.changes) do
		if change.id == id then
			return change, index
		end
	end
	return nil, nil
end

---@param id string
---@param status string
---@param opts? table
---@return boolean
function M.update_status(id, status, opts)
	opts = opts or {}
	local change = find_change(id)
	if not change then
		return false
	end

	change.status = status
	change.status_message = opts.message
	if opts.hunk_index and change.hunks and change.hunks[opts.hunk_index] then
		change.hunks[opts.hunk_index].status = status
	end
	return true
end

---@param original_lines string[]
---@param modified_lines string[]
---@return table[]
function M.calculate_hunks(original_lines, modified_lines)
	local hunks = {}
	local i = 1
	local original_len = #original_lines
	local modified_len = #modified_lines

	while i <= original_len or i <= modified_len do
		local original = original_lines[i]
		local changed = modified_lines[i]
		if original ~= changed then
			local hunk = {
				start_line = i,
				original_lines = {},
				modified_lines = {},
				status = M.STATUS.PENDING,
			}

			while i <= original_len or i <= modified_len do
				local current_original = original_lines[i]
				local current_changed = modified_lines[i]
				if current_original == current_changed and #hunk.original_lines > 0 then
					break
				end

				table.insert(hunk.original_lines, current_original or "")
				table.insert(hunk.modified_lines, current_changed or "")
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

---@param filepath string
---@param original_content string|nil
---@param modified_content string|nil
---@param opts? table
---@return string|nil change_id
function M.add_change(filepath, original_content, modified_content, opts)
	opts = opts or {}
	if type(filepath) ~= "string" or filepath == "" then
		return nil
	end

	local max_changes = get_max_changes()
	while #state.changes >= max_changes do
		table.remove(state.changes, 1)
	end

	local change_id = generate_id()
	local original = original_content or ""
	local modified = modified_content or ""
	local original_lines = vim.split(original, "\n", { plain = true })
	local modified_lines = vim.split(modified, "\n", { plain = true })
	local change = {
		id = change_id,
		filepath = filepath,
		filename = vim.fn.fnamemodify(filepath, ":t"),
		original_content = original,
		modified_content = modified,
		original_lines = original_lines,
		modified_lines = modified_lines,
		backup_path = backup_file(filepath, change_id),
		stats = calc_stats(original_lines, modified_lines),
		hunks = M.calculate_hunks(original_lines, modified_lines),
		status = M.STATUS.PENDING,
		timestamp = os.time(),
		requires_confirm = needs_confirmation(filepath),
		metadata = opts.metadata or {},
	}

	table.insert(state.changes, change)
	state.active_change_id = change_id
	emit_change_event("Added", change_id, { status = change.status, filepath = filepath })
	return change_id
end

---@return table[]
function M.get_all()
	return vim.deepcopy(state.changes)
end

---@return table[]
function M.get_pending()
	local pending = {}
	for _, change in ipairs(state.changes) do
		if change.status == M.STATUS.PENDING then
			table.insert(pending, vim.deepcopy(change))
		end
	end
	return pending
end

---@param id string
---@return table|nil
function M.get(id)
	local change = find_change(id)
	return change and vim.deepcopy(change) or nil
end

---@return table|nil
function M.get_active()
	return M.get(state.active_change_id)
end

---@param id string
---@param opts? table
---@return boolean ok
---@return string|nil err
function M.accept(id, opts)
	opts = opts or {}
	local change = find_change(id)
	if not change then
		return false, "Change not found"
	end
	if change.status ~= M.STATUS.PENDING then
		return false, "Change already resolved"
	end
	if change.requires_confirm and defaults.confirm_destructive and not opts.force then
		return false, "Confirmation required"
	end

	local ok, err = write_file(change.filepath, change.modified_content)
	if not ok then
		M.update_status(id, M.STATUS.FAILED, { message = err })
		emit_change_event("Failed", id, { status = M.STATUS.FAILED, error = err })
		return false, err
	end

	M.update_status(id, M.STATUS.APPLIED)
	reload_buffer(change.filepath)
	emit_change_event("Accepted", id, { status = M.STATUS.APPLIED, filepath = change.filepath })
	return true, nil
end

---@param id string
---@return boolean ok
---@return string|nil err
function M.reject(id)
	local change = find_change(id)
	if not change then
		return false, "Change not found"
	end
	if change.status ~= M.STATUS.PENDING then
		return false, "Change already resolved"
	end

	local ok, err = write_file(change.filepath, change.original_content)
	if not ok then
		M.update_status(id, M.STATUS.FAILED, { message = err })
		emit_change_event("Failed", id, { status = M.STATUS.FAILED, error = err })
		return false, err
	end

	M.update_status(id, M.STATUS.REJECTED)
	reload_buffer(change.filepath)
	emit_change_event("Rejected", id, { status = M.STATUS.REJECTED, filepath = change.filepath })
	return true, nil
end

M.reject_change = M.reject

---@param id string
---@return boolean ok
---@return string|nil err
function M.resolve_manually(id)
	local change = find_change(id)
	if not change then
		return false, "Change not found"
	end
	if change.status ~= M.STATUS.PENDING then
		return false, "Change already resolved"
	end

	M.update_status(id, M.STATUS.RESOLVED)
	emit_change_event("Resolved", id, { status = M.STATUS.RESOLVED, filepath = change.filepath })
	return true, nil
end

---@param id string
---@return boolean
function M.remove(id)
	local _, index = find_change(id)
	if not index then
		return false
	end

	table.remove(state.changes, index)
	if state.active_change_id == id then
		state.active_change_id = nil
	end
	emit_change_event("Removed", id, {})
	return true
end

---@return boolean
function M.clear()
	state.changes = {}
	state.active_change_id = nil
	emit_change_event("Cleared", "", {})
	return true
end

---@param opts? table
function M.setup(opts)
	opts = opts or {}
	local merged = vim.tbl_deep_extend("force", {}, DEFAULTS, opts)
	for key in pairs(defaults) do
		defaults[key] = nil
	end
	for key, value in pairs(merged) do
		defaults[key] = value
	end
end

return M
