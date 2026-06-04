-- opencode.nvim - Danger mode permission auto-approval

local M = {}

local replied_permissions = {}

---@return table|nil
local function events()
	local ok, mod = pcall(require, "opencode.events")
	if ok then
		return mod
	end
	return nil
end

---@return table|nil
local function logger()
	local ok, mod = pcall(require, "opencode.logger")
	if ok then
		return mod
	end
	return nil
end

---@param permission_id string
---@param opts table
local function emit_approved(permission_id, opts)
	local bus = events()
	if not bus or type(bus.emit) ~= "function" then
		return
	end

	bus.emit("permission_approved", {
		permission_id = permission_id,
		reply = "once",
		auto = true,
		danger_mode = true,
	})
	bus.emit("interaction_changed", {
		kind = opts.kind or "permission",
		action = "approved",
		id = permission_id,
		session_id = opts.session_id,
		auto = true,
		danger_mode = true,
	})
end

---@param permission_id string
---@param opts table
local function mark_local_state(permission_id, opts)
	local perm_ok, perm_state = pcall(require, "opencode.permission.state")
	if perm_ok and perm_state.has_permission and perm_state.has_permission(permission_id) then
		perm_state.mark_approved(permission_id, "once")
	end

	local edit_ok, edit_state = pcall(require, "opencode.edit.state")
	if edit_ok and edit_state.get_edit and edit_state.get_edit(permission_id) then
		edit_state.mark_sent(permission_id)
	end

	emit_approved(permission_id, opts)
end

---@param permission_id string
---@param opts? table
---@return boolean handled Whether the permission is handled by danger mode
---@return boolean queued Whether a new approval request was queued
function M.approve(permission_id, opts)
	opts = opts or {}
	if type(permission_id) ~= "string" or permission_id == "" then
		return false, false
	end
	if replied_permissions[permission_id] then
		return true, false
	end

	local client_ok, client = pcall(require, "opencode.client")
	if not client_ok or type(client.respond_permission) ~= "function" then
		vim.notify("OpenCode danger mode failed to load client: " .. tostring(client), vim.log.levels.ERROR)
		return false, false
	end

	replied_permissions[permission_id] = true
	client.respond_permission(permission_id, "once", { message = opts.message }, function(err)
		vim.schedule(function()
			local log = logger()
			if err then
				replied_permissions[permission_id] = nil
				if log then
					log.warn("Danger mode failed to auto-approve permission", {
						permission_id = permission_id,
						error = err,
					})
				end
				vim.notify("OpenCode danger mode failed to approve permission: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end

			if log then
				log.info("Danger mode auto-approved permission", {
					permission_id = permission_id,
					permission_type = opts.permission_type,
					session_id = opts.session_id,
				})
			end

			mark_local_state(permission_id, opts)
		end)
	end)

	return true, true
end

---@return number count Number of pending permission replies queued
function M.approve_pending()
	local count = 0

	local perm_ok, perm_state = pcall(require, "opencode.permission.state")
	if perm_ok and type(perm_state.get_all_active) == "function" then
		for _, pstate in ipairs(perm_state.get_all_active()) do
			local _, queued = M.approve(pstate.permission_id, {
				permission_type = pstate.permission_type,
				session_id = pstate.session_id,
				kind = "permission",
			})
			if queued then
				count = count + 1
			end
		end
	end

	local edit_ok, edit_state = pcall(require, "opencode.edit.state")
	if edit_ok and type(edit_state.get_all_active) == "function" then
		for _, estate in ipairs(edit_state.get_all_active()) do
			local accepted, accept_err = pcall(edit_state.accept_all, estate.permission_id)
			if not accepted then
				vim.notify(
					"OpenCode danger mode failed to accept edit: " .. tostring(accept_err),
					vim.log.levels.ERROR
				)
			else
				local _, queued = M.approve(estate.permission_id, {
					permission_type = "edit",
					session_id = estate.session_id,
					kind = "edit",
				})
				if queued then
					count = count + 1
				end
			end
		end
	end

	return count
end

function M.clear()
	replied_permissions = {}
end

return M
