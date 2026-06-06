-- opencode.nvim - Permission state management module
-- Tracks active non-edit permission requests, selections, and responses

local M = {}

-- Active permissions storage: { [permission_id] = permission_state }
local active_permissions = {}

-- Permission state structure:
-- {
--   permission_id = string,      -- "per_xxx"
--   session_id = string,
--   message_id = string|nil,     -- messageID that triggered this permission (for inline rendering)
--   call_id = string|nil,        -- tool callID for rendering beside the matching tool line
--   tool_name = string|nil,      -- tool that triggered this permission
--   permission_type = string,    -- "bash", "read", "glob", "grep", etc.
--   metadata = table,
--   patterns = table,
--   always = table,
--   tool_input = table,          -- resolved tool input (command, path, pattern, etc.)
--   message = string,            -- optional user note sent with the response
--   selected_option = number,    -- 1=Allow once, 2=Allow always, 3=Reject
--   status = string,             -- "pending" | "approved" | "rejected"
--   reply = string|nil,          -- "once" | "always" | "reject"
--   timestamp = number,
-- }

local OPTION_COUNT = 3

-- Add a new permission to track
---@param permission_id string
---@param session_id string
---@param permission_type string
---@param opts table { metadata, patterns, always, tool_input, message_id, call_id, tool_name, timestamp }
function M.add_permission(permission_id, session_id, permission_type, opts)
	opts = opts or {}
	local pstate = {
		permission_id = permission_id,
		session_id = session_id,
		message_id = opts.message_id, -- messageID that triggered this permission
		call_id = opts.call_id,
		tool_name = opts.tool_name,
		permission_type = permission_type,
		metadata = opts.metadata or {},
		patterns = opts.patterns or {},
		always = opts.always or {},
		tool_input = opts.tool_input or {},
		message = "",
		selected_option = 1,
		status = "pending",
		reply = nil,
		timestamp = opts.timestamp or os.time(),
	}

	active_permissions[permission_id] = pstate

	return pstate
end

-- Get a permission state by ID
---@param permission_id string
---@return table|nil
function M.get_permission(permission_id)
	return active_permissions[permission_id]
end

-- Get all permissions (regardless of status)
---@return table Array of permission states sorted by timestamp
function M.get_all()
	local result = {}
	for _, pstate in pairs(active_permissions) do
		table.insert(result, pstate)
	end
	table.sort(result, function(a, b) return a.timestamp < b.timestamp end)
	return result
end

-- Get all active (pending) permissions
---@return table Array of permission states
function M.get_all_active()
	local result = {}
	for _, pstate in pairs(active_permissions) do
		if pstate.status == "pending" then
			table.insert(result, pstate)
		end
	end
	return result
end

-- Get all permissions for a specific messageID (for inline rendering)
---@param message_id string
---@return table Array of permission states associated with this message
function M.get_permissions_for_message(message_id)
	local result = {}
	for _, pstate in pairs(active_permissions) do
		if pstate.message_id == message_id then
			table.insert(result, pstate)
		end
	end
	-- Sort by timestamp to maintain order
	table.sort(result, function(a, b) return a.timestamp < b.timestamp end)
	return result
end

-- Get all permissions without a messageID (orphan permissions, rendered at end)
---@return table Array of permission states without associated messages
function M.get_orphan_permissions()
	local result = {}
	for _, pstate in pairs(active_permissions) do
		if not pstate.message_id then
			table.insert(result, pstate)
		end
	end
	-- Sort by timestamp to maintain order
	table.sort(result, function(a, b) return a.timestamp < b.timestamp end)
	return result
end

-- Select an option (1-3)
---@param permission_id string
---@param option_index number 1=Allow once, 2=Allow always, 3=Reject
---@return boolean
function M.select_option(permission_id, option_index)
	local pstate = active_permissions[permission_id]
	if not pstate or pstate.status ~= "pending" then
		return false
	end

	if option_index < 1 or option_index > OPTION_COUNT then
		return false
	end

	pstate.selected_option = option_index

	return true
end

-- Set message for a permission request
---@param permission_id string
---@param text string
---@return boolean
function M.set_message(permission_id, text)
	local pstate = active_permissions[permission_id]
	if not pstate then
		return false
	end

	pstate.message = vim.trim(text or "")
	return true
end

-- Merge resolved tool input into an existing permission.
---@param permission_id string
---@param tool_input table
---@return boolean
function M.merge_tool_input(permission_id, tool_input)
	local pstate = active_permissions[permission_id]
	if not pstate or type(tool_input) ~= "table" then
		return false
	end

	pstate.tool_input = vim.tbl_deep_extend(
		"force",
		{},
		type(pstate.tool_input) == "table" and pstate.tool_input or {},
		tool_input
	)
	return true
end

-- Set the tool name that triggered a permission request.
---@param permission_id string
---@param tool_name string
---@return boolean
function M.set_tool_name(permission_id, tool_name)
	local pstate = active_permissions[permission_id]
	if not pstate or type(tool_name) ~= "string" or tool_name == "" then
		return false
	end

	local trimmed = vim.trim(tool_name)
	if trimmed == "" then
		return false
	end

	pstate.tool_name = trimmed
	return true
end

-- Move selection up/down
---@param permission_id string
---@param direction "up" | "down"
---@return boolean
function M.move_selection(permission_id, direction)
	local pstate = active_permissions[permission_id]
	if not pstate or pstate.status ~= "pending" then
		return false
	end

	local current = pstate.selected_option
	local new_index
	if direction == "up" then
		new_index = current > 1 and current - 1 or OPTION_COUNT
	else
		new_index = current < OPTION_COUNT and current + 1 or 1
	end

	pstate.selected_option = new_index

	return true
end

-- Mark permission as approved
---@param permission_id string
---@param reply string "once" | "always"
---@return boolean
function M.mark_approved(permission_id, reply)
	local pstate = active_permissions[permission_id]
	if not pstate then
		return false
	end

	pstate.status = "approved"
	pstate.reply = reply
	pstate.resolved_at = os.time()

	return true
end

-- Mark permission as rejected
---@param permission_id string
---@return boolean
function M.mark_rejected(permission_id)
	local pstate = active_permissions[permission_id]
	if not pstate then
		return false
	end

	pstate.status = "rejected"
	pstate.reply = "reject"
	pstate.resolved_at = os.time()

	return true
end

-- Check if a permission ID exists
---@param permission_id string
---@return boolean
function M.has_permission(permission_id)
	return active_permissions[permission_id] ~= nil
end

-- Remove a permission from tracking
---@param permission_id string
---@return boolean
function M.remove_permission(permission_id)
	if active_permissions[permission_id] then
		active_permissions[permission_id] = nil
		return true
	end
	return false
end

-- Clear permissions belonging to a specific session only
---@param session_id string
function M.clear_session(session_id)
	local removed = {}
	for permission_id, pstate in pairs(active_permissions) do
		if pstate.session_id == session_id then
			table.insert(removed, permission_id)
			active_permissions[permission_id] = nil
		end
	end
	return removed
end

-- Clear all permissions (e.g., on session change)
function M.clear_all()
	local removed = {}
	for permission_id, _ in pairs(active_permissions) do
		table.insert(removed, permission_id)
	end
	active_permissions = {}
	return removed
end

---@param predicate fun(pstate: table, permission_id: string): boolean|nil
---@return table removed
function M.clear_pending_matching(predicate)
	if type(predicate) ~= "function" then
		return {}
	end

	local removed = {}
	local removed_ids = {}
	for permission_id, pstate in pairs(active_permissions) do
		if pstate and pstate.status == "pending" and predicate(pstate, permission_id) then
			removed[#removed + 1] = vim.deepcopy(pstate)
			removed_ids[#removed_ids + 1] = permission_id
		end
	end

	for _, permission_id in ipairs(removed_ids) do
		active_permissions[permission_id] = nil
	end

	table.sort(removed, function(a, b)
		return (a and a.timestamp or 0) < (b and b.timestamp or 0)
	end)

	return removed
end

-- Clear pending permissions for a specific session.
---@param session_id string|nil
---@return table removed
function M.clear_pending_for_session(session_id)
	if not session_id or session_id == "" then
		return {}
	end

	return M.clear_pending_matching(function(pstate)
		return pstate.session_id == session_id
	end)
end

return M
