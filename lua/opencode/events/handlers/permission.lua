local M = {}

local util = require("opencode.events.util")
local request = require("opencode.events.handlers.permission_flow.request")
local edit_flow = require("opencode.events.handlers.permission_flow.edit")
local non_edit_flow = require("opencode.events.handlers.permission_flow.non_edit")
local lifecycle = require("opencode.events.handlers.permission_flow.lifecycle")
local artifacts = require("opencode.events.handlers.permission_flow.artifacts")

-- Debounce table for tool_update-driven permission recovery.
local pending_tool_permission_sync = {}
local PERMISSION_SYNC_RETRY_DELAYS_MS = { 120, 300, 700 }

---@param fn function
---@return function
local function scheduled(fn)
	return function(data)
		vim.schedule(function()
			fn(data)
		end)
	end
end

---@param events table
---@param data table|nil
local function handle_permission(events, data)
	local logger = require("opencode.logger")
	logger.debug("Permission event received", { data = data })

	local permission_request, err = request.decode(data)
	if not permission_request then
		logger.debug("Permission event ignored", {
			reason = err,
			data = data,
		})
		return
	end

	local current_session = require("opencode.state").get_session()
	if permission_request.kind == "edit" then
		edit_flow.handle(events, permission_request, current_session, logger)
	else
		non_edit_flow.handle(events, permission_request, current_session, logger)
	end
end

-- Recovery: when the permission SSE event is dropped (directory mismatch
-- or transient disconnect), recover the pending permission from the
-- server's GET /permission endpoint.

---Resolve the project directory for a session by looking up the full
---session record in state. Returns the normalized directory string or
---nil when the session is unknown or has no directory field. Delegates
---to state.get_session_directory (single source of truth).
---@param session_id string|nil
---@return string|nil
local function resolve_session_directory(session_id)
	if not session_id or session_id == "" then
		return nil
	end
	local ok_state, state = pcall(require, "opencode.state")
	if not ok_state or type(state.get_session_directory) ~= "function" then
		return nil
	end
	return state.get_session_directory(session_id)
end

---@param data table|nil
---@return boolean
local function is_running_tool(data)
	if type(data) ~= "table" then
		return false
	end
	local status = data.status
	return status == "running" or status == "pending" or status == "started"
end

---@param message_id string|nil
---@param call_id string|nil
---@return boolean
local function has_permission_for_tool(message_id, call_id)
	if type(call_id) ~= "string" or call_id == "" then
		return false
	end

	local perm_ok, permission_state = pcall(require, "opencode.permission.state")
	if perm_ok and permission_state.get_all then
		for _, pstate in ipairs(permission_state.get_all()) do
			if pstate.call_id == call_id
				and (not message_id or not pstate.message_id or pstate.message_id == message_id)
			then
				return true
			end
		end
	end

	local edit_ok, edit_state = pcall(require, "opencode.edit.state")
	if edit_ok and edit_state.get_all then
		for _, estate in ipairs(edit_state.get_all()) do
			if estate.call_id == call_id
				and (not message_id or not estate.message_id or estate.message_id == message_id)
			then
				return true
			end
		end
	end

	return false
end

---@param data table
---@return string
local function tool_sync_key(data)
	return table.concat({
		data.session_id or "",
		data.message_id or "",
		data.call_id or "",
	}, "\0")
end

---@param response any
---@return table[]
local function normalize_permission_list(response)
	if type(response) ~= "table" then
		return {}
	end
	if response[1] ~= nil then
		return response
	end
	if type(response.permissions) == "table" then
		return response.permissions
	end
	if type(response.data) == "table" then
		return response.data
	end
	return {}
end

---@param perm_data table
---@param tool_data table
---@return boolean
local function permission_matches_tool(perm_data, tool_data)
	local perm_message_id = util.resolve_event_message_id(perm_data)
	local perm_call_id = util.resolve_event_call_id(perm_data)
	local tool_message_id = tool_data.message_id
	local tool_call_id = tool_data.call_id

	local tool_has_call_id = type(tool_call_id) == "string" and tool_call_id ~= ""
	local perm_has_call_id = type(perm_call_id) == "string" and perm_call_id ~= ""

	-- Require call_id match when the tool has one.
	if tool_has_call_id then
		if perm_call_id == tool_call_id then
			return not tool_message_id or not perm_message_id or perm_message_id == tool_message_id
		end
		return false
	end

	-- Only use message_id-only match when call_id is absent on BOTH sides.
	if not perm_has_call_id
		and type(tool_message_id) == "string"
		and tool_message_id ~= ""
		and perm_message_id == tool_message_id
	then
		return true
	end

	return false
end

---@param events table
---@param data table
---@param attempt number|nil
local function sync_permission_from_tool(events, data, attempt)
	attempt = attempt or 1
	if not is_running_tool(data) then
		return
	end
	if has_permission_for_tool(data.message_id, data.call_id) then
		return
	end

	local key = tool_sync_key(data)
	if pending_tool_permission_sync[key] then
		return
	end
	pending_tool_permission_sync[key] = true

	local ok_client, client = pcall(require, "opencode.client")
	if not ok_client or type(client.list_permissions) ~= "function" then
		pending_tool_permission_sync[key] = nil
		return
	end

	local dir = resolve_session_directory(data.session_id)

	client.list_permissions({ directory = dir }, function(err, response)
		pending_tool_permission_sync[key] = nil
		local logger = require("opencode.logger")
		if err then
			logger.debug("Pending permission sync failed", {
				message_id = data.message_id,
				call_id = data.call_id,
				error = err.message or err.error or tostring(err),
			})
			return
		end

		for _, perm_data in ipairs(normalize_permission_list(response)) do
			if permission_matches_tool(perm_data, data) then
				handle_permission(events, perm_data)
				return
			end
		end

		local delay = PERMISSION_SYNC_RETRY_DELAYS_MS[attempt]
		if delay and not has_permission_for_tool(data.message_id, data.call_id) then
			vim.defer_fn(function()
				sync_permission_from_tool(events, data, attempt + 1)
			end, delay)
		end
	end)
end

--- Fetch all pending permissions from the server and register any that
--- aren't already tracked locally. Used on session switch and SSE
--- reconnect to recover from dropped events.
---@param events table
local function reconcile_pending_permissions(events)
	local ok_client, client = pcall(require, "opencode.client")
	if not ok_client or type(client.list_permissions) ~= "function" then
		return
	end

	local dir
	local ok_state, state = pcall(require, "opencode.state")
	if ok_state and type(state.get_session) == "function" then
		local active = state.get_session()
		if active and active.id then
			dir = resolve_session_directory(active.id)
		end
	end

	client.list_permissions({ directory = dir }, function(err, response)
		vim.schedule(function()
			local logger = require("opencode.logger")
			if err then
				logger.debug("Permission reconciliation failed", {
					error = err.message or err.error or tostring(err),
				})
				return
			end

			local count = 0
			for _, perm_data in ipairs(normalize_permission_list(response)) do
				handle_permission(events, perm_data)
				count = count + 1
			end
			if count > 0 then
				logger.info("Reconciled pending permissions", { count = count })
			end
		end)
	end)
end

function M.setup(events)
	events.on("tool_update", scheduled(function(data)
		local logger = require("opencode.logger")
		artifacts.handle_tool_update(data, logger)
		sync_permission_from_tool(events, data)
	end))

	events.on("permission", scheduled(function(data)
		handle_permission(events, data)
	end))

	events.on("edit", scheduled(artifacts.handle_edit))
	events.on("session_diff", scheduled(artifacts.handle_session_diff))

	events.on("session_change", function(data)
		lifecycle.handle_session_change(events, data)
	end)

	events.on("session.selected", function()
		vim.schedule(function()
			reconcile_pending_permissions(events)
		end)
	end)

	events.on("connected", function()
		vim.schedule(function()
			reconcile_pending_permissions(events)
		end)
	end)

	events.on("permission_replied", scheduled(function(data)
		lifecycle.handle_permission_replied(events, data, require("opencode.logger"))
	end))
end

return M
