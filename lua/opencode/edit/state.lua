-- opencode.nvim - Edit state management module
-- Tracks active edit permission requests (fugitive-style file review widget)

local M = {}

-- Active edits storage: { [permission_id] = edit_state }
local active_edits = {}

-- Edit state structure:
-- {
--   permission_id = string,
--   session_id = string,
--   message_id = string|nil,
--   files = [{
--     index, filepath, relative_path,
--     before, after, change_id,
--     status = "pending"|"accepted"|"rejected"|"resolved",
--     stats = {added, removed},
--     diff_lines = {...},  -- cached unified diff lines for = toggle
--   }],
--   selected_file = 1,        -- cursor position (1-based)
--   expanded_files = {},       -- set of file indices with inline diff visible
--   status = "pending"|"sent", -- overall status
--   timestamp = number,
--   data = table,              -- original event data for reference
--   metadata = table,
-- }

--- Parse a unified diff string into an array of lines
---@param diff_str string|nil
---@return table lines
local function parse_diff_lines(diff_str)
	if not diff_str or diff_str == "" then
		return {}
	end
	return vim.split(diff_str, "\n", { plain = true })
end

--- Add a new edit to track
---@param permission_id string
---@param session_id string
---@param files_data table Array of file data from metadata.files
---@param opts table { data, metadata, message_id }
function M.add_edit(permission_id, session_id, files_data, opts)
	opts = opts or {}
	local changes = require("opencode.artifact.changes")

	local files = {}
	for i, fd in ipairs(files_data) do
		local filepath = fd.filePath or fd.filepath or fd.path or ""
		local relative_path = fd.relativePath or fd.relative_path or vim.fn.fnamemodify(filepath, ":.")
		local before = fd.before or ""
		local after = fd.after or ""
		local additions = fd.additions or 0
		local deletions = fd.deletions or 0

		-- Create change record for accept/reject file writing
		local change_id = changes.add_change(filepath, before, after, {
			metadata = {
				source = "edit_widget",
				permission_id = permission_id,
				file_index = i,
			},
		})

		table.insert(files, {
			index = i,
			filepath = filepath,
			relative_path = relative_path,
			before = before,
			after = after,
			change_id = change_id,
			status = "pending",
			stats = { added = additions, removed = deletions },
			diff_lines = parse_diff_lines(fd.diff),
			file_type = fd.type or "update",
		})
	end

	local estate = {
		permission_id = permission_id,
		session_id = session_id,
		message_id = opts.message_id,
		files = files,
		selected_file = 1,
		expanded_files = {},
		status = "pending",
		timestamp = os.time(),
		data = opts.data or {},
		metadata = opts.metadata or {},
	}

	active_edits[permission_id] = estate

	local events = require("opencode.events")
	events.emit("edit_pending", {
		permission_id = permission_id,
		file_count = #files,
	})
end

--- Get an edit state by permission ID
---@param permission_id string
---@return table|nil
function M.get_edit(permission_id)
	return active_edits[permission_id]
end

--- Get all edits (regardless of status)
---@return table Array of edit states sorted by timestamp
function M.get_all()
	local result = {}
	for _, estate in pairs(active_edits) do
		table.insert(result, estate)
	end
	table.sort(result, function(a, b) return a.timestamp < b.timestamp end)
	return result
end

--- Get all active (pending) edits
---@return table Array of edit states
function M.get_all_active()
	local result = {}
	for _, estate in pairs(active_edits) do
		if estate.status == "pending" then
			table.insert(result, estate)
		end
	end
	return result
end

--- Get all edits for a specific message ID (for inline rendering)
---@param message_id string
---@return table Array of edit states
function M.get_edits_for_message(message_id)
	local result = {}
	for _, estate in pairs(active_edits) do
		if estate.message_id == message_id then
			table.insert(result, estate)
		end
	end
	table.sort(result, function(a, b) return a.timestamp < b.timestamp end)
	return result
end

--- Get all edits without a message ID (orphan edits)
---@return table Array of edit states
function M.get_orphan_edits()
	local result = {}
	for _, estate in pairs(active_edits) do
		if not estate.message_id then
			table.insert(result, estate)
		end
	end
	table.sort(result, function(a, b) return a.timestamp < b.timestamp end)
	return result
end

--- Move selection up/down through file list
---@param permission_id string
---@param direction "up"|"down"
---@return boolean
function M.move_selection(permission_id, direction)
	local estate = active_edits[permission_id]
	if not estate or estate.status ~= "pending" then
		return false
	end

	local count = #estate.files
	if count == 0 then
		return false
	end

	local current = estate.selected_file
	if direction == "up" then
		estate.selected_file = current > 1 and current - 1 or count
	else
		estate.selected_file = current < count and current + 1 or 1
	end

	return true
end

--- Jump to file N (1-based)
---@param permission_id string
---@param index number
---@return boolean
function M.move_selection_to(permission_id, index)
	local estate = active_edits[permission_id]
	if not estate or estate.status ~= "pending" then
		return false
	end

	if index < 1 or index > #estate.files then
		return false
	end

	estate.selected_file = index
	return true
end

--- Get currently selected file entry
---@param permission_id string
---@return table|nil
function M.get_selected_file(permission_id)
	local estate = active_edits[permission_id]
	if not estate then
		return nil
	end
	return estate.files[estate.selected_file]
end

--- Accept a file (write to disk via changes module)
---@param permission_id string
---@param file_index number
---@return boolean, string|nil
function M.accept_file(permission_id, file_index)
	local estate = active_edits[permission_id]
	if not estate then
		return false, "Edit not found"
	end

	local file = estate.files[file_index]
	if not file then
		return false, "File not found"
	end

	if file.status ~= "pending" then
		return false, "File already resolved"
	end

	local changes = require("opencode.artifact.changes")
	local ok, err = changes.accept(file.change_id, { force = true })
	if not ok then
		return false, err
	end

	file.status = "accepted"
	return true
end

--- Reject a file (mark as rejected, file stays unchanged on disk)
---@param permission_id string
---@param file_index number
---@return boolean, string|nil
function M.reject_file(permission_id, file_index)
	local estate = active_edits[permission_id]
	if not estate then
		return false, "Edit not found"
	end

	local file = estate.files[file_index]
	if not file then
		return false, "File not found"
	end

	if file.status ~= "pending" then
		return false, "File already resolved"
	end

	local changes = require("opencode.artifact.changes")
	changes.reject(file.change_id)

	file.status = "rejected"
	return true
end

--- Accept all pending files
---@param permission_id string
---@return boolean
function M.accept_all(permission_id)
	local estate = active_edits[permission_id]
	if not estate then
		return false
	end

	for _, file in ipairs(estate.files) do
		if file.status == "pending" then
			local changes = require("opencode.artifact.changes")
			changes.accept(file.change_id, { force = true })
			file.status = "accepted"
		end
	end

	return true
end

--- Reject all pending files
---@param permission_id string
---@return boolean
function M.reject_all(permission_id)
	local estate = active_edits[permission_id]
	if not estate then
		return false
	end

	for _, file in ipairs(estate.files) do
		if file.status == "pending" then
			local changes = require("opencode.artifact.changes")
			changes.reject(file.change_id)
			file.status = "rejected"
		end
	end

	return true
end

--- Resolve a file manually (mark as resolved without touching disk)
---@param permission_id string
---@param file_index number
---@return boolean, string|nil
function M.resolve_file(permission_id, file_index)
	local estate = active_edits[permission_id]
	if not estate then
		return false, "Edit not found"
	end

	local file = estate.files[file_index]
	if not file then
		return false, "File not found"
	end

	if file.status ~= "pending" then
		return false, "File already resolved"
	end

	local changes = require("opencode.artifact.changes")
	changes.resolve_manually(file.change_id)

	file.status = "resolved"
	return true
end

--- Resolve all pending files manually
---@param permission_id string
---@return boolean
function M.resolve_all(permission_id)
	local estate = active_edits[permission_id]
	if not estate then
		return false
	end

	for _, file in ipairs(estate.files) do
		if file.status == "pending" then
			local changes = require("opencode.artifact.changes")
			changes.resolve_manually(file.change_id)
			file.status = "resolved"
		end
	end

	return true
end

--- Toggle inline diff visibility for a file
---@param permission_id string
---@param file_index number
---@return boolean
function M.toggle_inline_diff(permission_id, file_index)
	local estate = active_edits[permission_id]
	if not estate then
		return false
	end

	if not estate.files[file_index] then
		return false
	end

	if estate.expanded_files[file_index] then
		estate.expanded_files[file_index] = nil
	else
		estate.expanded_files[file_index] = true
	end

	return true
end

--- Check if all files are resolved (accepted or rejected)
---@param permission_id string
---@return boolean
function M.are_all_resolved(permission_id)
	local estate = active_edits[permission_id]
	if not estate then
		return false
	end

	for _, file in ipairs(estate.files) do
		if file.status == "pending" then
			return false
		end
	end

	return true
end

--- Get the resolution summary
---@param permission_id string
---@return string "all_accepted"|"all_rejected"|"all_resolved"|"mixed"|"pending"
function M.get_resolution(permission_id)
	local estate = active_edits[permission_id]
	if not estate then
		return "pending"
	end

	local accepted = 0
	local rejected = 0
	local resolved = 0
	for _, file in ipairs(estate.files) do
		if file.status == "accepted" then
			accepted = accepted + 1
		elseif file.status == "rejected" then
			rejected = rejected + 1
		elseif file.status == "resolved" then
			resolved = resolved + 1
		else
			return "pending"
		end
	end

	if accepted == #estate.files then
		return "all_accepted"
	elseif rejected == #estate.files then
		return "all_rejected"
	elseif resolved == #estate.files then
		return "all_resolved"
	else
		return "mixed"
	end
end

--- Mark edit as sent (reply sent to server)
---@param permission_id string
function M.mark_sent(permission_id)
	local estate = active_edits[permission_id]
	if estate then
		estate.status = "sent"
		estate.resolved_at = os.time()
	end
end

--- Clear all edits (on session change)
function M.clear_all()
	local events = require("opencode.events")
	for permission_id, _ in pairs(active_edits) do
		events.emit("edit_removed", { permission_id = permission_id })
	end
	active_edits = {}
end

return M
