local M = {}
local pending = require("opencode.session.pending")

local active_permissions = {}
local generation = 0

function M.get_generation() return generation end

---@param permission_id string
---@param session_id string
---@param permission_type string
---@param opts table { metadata, patterns, always, tool_input, message_id, call_id, tool_name, timestamp }
function M.add_permission(permission_id, session_id, permission_type, opts)
	opts = opts or {}
	local pstate = {
		permission_id = permission_id,
		location = opts.location,
		transport = "permission",
		session_id = session_id,
		message_id = opts.message_id,
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

---@param permission_id string
---@return table|nil
function M.get_permission(permission_id)
	return active_permissions[permission_id]
end

-- Get all permissions (regardless of status)
---@return table Array of permission states sorted by timestamp
function M.get_all()
	local result = {}
	for _, item in pairs(active_permissions) do
		table.insert(result, item)
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

---@param permission_id string
---@param option_index number 1=Allow once, 2=Allow always (or Reject without save), 3=Reject
---@return boolean
function M.select_option(permission_id, option_index)
	local pstate = active_permissions[permission_id]
	if not pstate or pstate.status ~= "pending" then
		return false
	end

	if option_index < 1 or option_index > (#pstate.always > 0 and 3 or 2) then
		return false
	end

	pstate.selected_option = option_index

	return true
end

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

-- Enrich a permission from a decoded request or tool update without replacing
-- values already supplied by the permission payload.
---@param permission_id string
---@param enrichment table { tool_name?, tool_input? }
---@return boolean changed
function M.enrich_permission(permission_id, enrichment)
	local pstate = active_permissions[permission_id]
	if not pstate or type(enrichment) ~= "table" then
		return false
	end

	local changed = false
	local tool_name = enrichment.tool_name
	if type(tool_name) == "string" then
		tool_name = vim.trim(tool_name)
		if tool_name ~= "" and (type(pstate.tool_name) ~= "string" or vim.trim(pstate.tool_name) == "") then
			pstate.tool_name = tool_name
			changed = true
		end
	end

	if type(enrichment.tool_input) == "table" then
		local current = type(pstate.tool_input) == "table" and pstate.tool_input or {}
		local merged = vim.tbl_deep_extend("force", {}, enrichment.tool_input, current)
		if not vim.deep_equal(current, merged) then
			pstate.tool_input = merged
			changed = true
		end
	end

	return changed
end

---@param permission_id string
---@param direction "up" | "down"
---@return boolean
function M.move_selection(permission_id, direction)
	local pstate = active_permissions[permission_id]
	if not pstate or pstate.status ~= "pending" then
		return false
	end

	local current = pstate.selected_option
	local option_count = #pstate.always > 0 and 3 or 2
	local new_index
	if direction == "up" then
		new_index = current > 1 and current - 1 or option_count
	else
		new_index = current < option_count and current + 1 or 1
	end

	pstate.selected_option = new_index

	return true
end

---@param permission_id string
---@param reply string "once" | "always"
---@return boolean
function M.mark_approved(permission_id, reply)
	local pstate = active_permissions[permission_id]
	if not pstate or pstate.status ~= "pending" then
		return false
	end

	pstate.submitting = false
	pstate.status = "approved"
	pstate.reply = reply
	pstate.resolved_at = os.time()

	return true
end

---@param permission_id string
---@return boolean
function M.mark_rejected(permission_id)
	local pstate = active_permissions[permission_id]
	if not pstate or pstate.status ~= "pending" then
		return false
	end

	pstate.submitting = false
	pstate.status = "rejected"
	pstate.reply = "reject"
	pstate.resolved_at = os.time()

	return true
end

---@param permission_id string
---@return boolean
function M.has_permission(permission_id)
	return active_permissions[permission_id] ~= nil
end

---@param permission_id string
---@return boolean
function M.remove_permission(permission_id)
	if active_permissions[permission_id] then
		active_permissions[permission_id] = nil
		return true
	end
	return false
end

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

function M.clear_all()
	generation = generation + 1
	local removed = {}
	for permission_id, _ in pairs(active_permissions) do
		table.insert(removed, permission_id)
	end
	active_permissions = {}
	return removed
end

function M.begin_submission(id)
	local item = active_permissions[id]
	if item and item.submission_token and not pending.is_current(item.submission_token) then M.restore_submission(id) end
	if not item or item.status ~= "pending" or item.submitting then return false end
	item.submitting, item.error = true, nil
	item.submission_token = pending.token(item.session_id)
	return true
end

function M.restore_submission(id, err)
	local item = active_permissions[id]
	if not item or item.status ~= "pending" or not item.submitting then return false end
	item.submitting, item.error = false, err
	item.submission_token = nil
	return true
end

function M.mark_unavailable(id)
	local item = active_permissions[id]
	if not item or item.status ~= "pending" then return false end
	item.status, item.submitting = "unavailable", false
	return true
end

return M
