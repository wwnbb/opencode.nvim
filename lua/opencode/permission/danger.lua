-- opencode.nvim - Danger mode permission auto-approval

local M = {}
local pending = require("opencode.session.pending")
local permissions = require("opencode.permission.state")

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
	permissions.mark_approved(permission_id, "once")

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
	local edit = require("opencode.edit.state").get_edit(permission_id)
	if edit and edit.transport == "review_rpc" then
		return true, require("opencode.review").reply(permission_id, function(err)
			if err then vim.notify("OpenCode review failed: " .. (err.message or "unknown error"), vim.log.levels.ERROR) end
		end)
	end
	local item = permissions.get_permission(permission_id)
	if item and item.status ~= "pending" then return true, false end
	local previous = replied_permissions[permission_id]
	if previous and previous.owner == item and pending.is_current(previous.token) then
		return true, false
	end

	local client_ok, client = pcall(require, "opencode.client")
	if not client_ok or type(client.respond_permission) ~= "function" then
		vim.notify("OpenCode danger mode failed to load client: " .. tostring(client), vim.log.levels.ERROR)
		return false, false
	end

	if item and not permissions.begin_submission(permission_id) then return true, false end
	local session_id = (item and item.session_id) or opts.session_id
	local attempt = { token = item and item.submission_token or pending.token(session_id), owner = item }
	replied_permissions[permission_id] = attempt
	client.respond_permission(permission_id, "once", { message = opts.message, session_id = session_id }, function(err)
		vim.schedule(function()
			if replied_permissions[permission_id] ~= attempt or not pending.is_current(attempt.token) then return end
			local current = permissions.get_permission(permission_id)
			if current ~= item or (current and (current.status ~= "pending" or current.submission_token ~= attempt.token)) then return end
			attempt.finished = true
			local log = logger()
			if err then
				replied_permissions[permission_id] = nil
				if item then permissions.restore_submission(permission_id, err) end
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
	local runtime_root = require("opencode.events.util").runtime_root_for_session

	for _, pstate in ipairs(permissions.get_all_active()) do
		if runtime_root(pstate.session_id) then
			local _, queued = M.approve(pstate.permission_id, {
				permission_type = pstate.permission_type,
				session_id = pstate.session_id,
				kind = "permission",
			})
			if queued then count = count + 1 end
		end
	end

	local edit_ok, edit_state = pcall(require, "opencode.edit.state")
	if edit_ok and type(edit_state.get_all_active) == "function" then
		for _, estate in ipairs(edit_state.get_all_active()) do
			if runtime_root(estate.session_id) then
				local call_ok, accepted, accept_err = pcall(edit_state.accept_all, estate.permission_id)
				if not call_ok or not accepted then
					vim.notify(
						"OpenCode danger mode failed to accept edit: "
							.. tostring((call_ok and accept_err) or accepted or "unknown error"),
						vim.log.levels.ERROR
					)
				else
					local _, queued = M.approve(estate.permission_id, {
						permission_type = "edit",
						session_id = estate.session_id,
						kind = "edit",
					})
					if queued then count = count + 1 end
				end
			end
		end
	end

	return count
end

function M.clear()
	-- Disabling danger mode does not cancel an already sent HTTP reply.
	for id, attempt in pairs(replied_permissions) do
		local item = permissions.get_permission(id)
		if attempt.finished or not pending.is_current(attempt.token) or item ~= attempt.owner
			or (item and item.status ~= "pending") then
			replied_permissions[id] = nil
		end
	end
end

return M
