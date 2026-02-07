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
--   permission_type = string,    -- "bash", "read", "glob", "grep", etc.
--   metadata = table,
--   patterns = table,
--   always = table,
--   tool_input = table,          -- resolved tool input (command, path, pattern, etc.)
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
---@param opts table { metadata, patterns, always, tool_input, message_id }
function M.add_permission(permission_id, session_id, permission_type, opts)
	opts = opts or {}
	local pstate = {
		permission_id = permission_id,
		session_id = session_id,
		message_id = opts.message_id, -- messageID that triggered this permission
		permission_type = permission_type,
		metadata = opts.metadata or {},
		patterns = opts.patterns or {},
		always = opts.always or {},
		tool_input = opts.tool_input or {},
		selected_option = 1,
		status = "pending",
		reply = nil,
		timestamp = os.time(),
	}

	active_permissions[permission_id] = pstate

	local events = require("opencode.events")
	events.emit("permission_pending", {
		permission_id = permission_id,
		permission_type = permission_type,
	})
end

-- Get a permission state by ID
---@param permission_id string
---@return table|nil
function M.get_permission(permission_id)
	return active_permissions[permission_id]
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

	local events = require("opencode.events")
	events.emit("permission_selection_changed", {
		permission_id = permission_id,
		selected = option_index,
	})

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

	local events = require("opencode.events")
	events.emit("permission_selection_changed", {
		permission_id = permission_id,
		selected = new_index,
	})

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

	local events = require("opencode.events")
	events.emit("permission_approved", {
		permission_id = permission_id,
		reply = reply,
	})

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

	local events = require("opencode.events")
	events.emit("permission_rejected", {
		permission_id = permission_id,
	})

	return true
end

-- Check if a permission ID exists
---@param permission_id string
---@return boolean
function M.has_permission(permission_id)
	return active_permissions[permission_id] ~= nil
end

-- Clear all permissions (e.g., on session change)
function M.clear_all()
	local events = require("opencode.events")
	for permission_id, _ in pairs(active_permissions) do
		events.emit("permission_removed", { permission_id = permission_id })
	end
	active_permissions = {}
end

return M
