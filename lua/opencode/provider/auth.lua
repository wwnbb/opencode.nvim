-- Integration attempt orchestration. UI observes snapshots; this module owns IO.
local M = {}
local owner = require("opencode.provider.state")
local pending = require("opencode.session.pending")
local function client() return require("opencode.client") end
local function refresh(directory)
	require("opencode.events").emit("catalog_invalidated", { type = "integration.updated", location = { directory = directory } })
end
local function options(record)
	return { directory = record.directory, attempt_id = record.attempt_id }
end
local function live(record)
	if owner.attempt_current(record) then return true end
	owner.release_attempt(record)
	return false
end
local function finish(record, status, message)
	if not live(record) then return end
	owner.stop_attempt(record)
	owner.update_attempt(record, { status = status, error = message })
	if status == "complete" then refresh(record.directory) end
end

local poll
local function schedule(record)
	if not live(record) then return end
	owner.stop_attempt(record)
	record.timer = vim.defer_fn(function() record.timer = nil; poll(record) end, 1500)
end
poll = function(record)
	if not live(record) or record.status == "cancelling" then return end
	if (vim.uv.now() - record.started) > 600000 or os.time() * 1000 >= record.expires then
		finish(record, "expired", "Authorization attempt expired")
		-- 2.0.11 may retain a pending auto callback beyond expires. Stop it explicitly.
		client().integration(record.kind .. "_cancel", record.integration_id, nil, options(record), function(err)
			if err and live(record) then owner.update_attempt(record, { error = "Expired; server cancellation was not confirmed" }) end
		end)
		return
	end
	client().integration(record.kind .. "_status", record.integration_id, nil, options(record), function(err, result)
		if not live(record) or record.status == "cancelling" or record.status == "submitting" then return end
		if err then finish(record, "failed", "Could not verify authorization status; reconnect to check the account"); return end
		if result.status == "pending" then
			owner.update_attempt(record, { status = record.mode == "code" and not record.code_submitted and "awaiting_user" or "polling" })
			schedule(record)
		else
			finish(record, result.status, result.status == "failed" and "Authorization failed" or nil)
		end
	end)
end

function M.start(integration_id, method, answer, opts, listener)
	opts = opts or {}
	local record = owner.begin_attempt(integration_id, method.type, opts.directory, listener)
	record.started = vim.uv.now()
	local body = { methodID = method.id, label = opts.label }
	if method.type == "oauth" then body.answer = answer end
	client().integration(method.type .. "_start", integration_id, body, options(record), function(err, result)
		if not live(record) then return end
		if err then finish(record, "failed", err.message); return end
		record.attempt_id, record.expires = result.attemptID, result.time.expires
		if record.cancel_requested then M.cancel(record.id); return end
		owner.update_attempt(record, { url = result.url, instructions = result.instructions, mode = result.mode,
			status = result.mode == "code" and "awaiting_user" or "polling" })
		schedule(record)
	end)
	return record.id
end

function M.complete(id, code)
	local record = owner.get_attempt(id)
	if not record or not live(record) or record.status ~= "awaiting_user" then return end
	owner.stop_attempt(record)
	owner.update_attempt(record, { status = "submitting" })
	client().integration("oauth_complete", record.integration_id, { code = code }, options(record), function(err)
		if not live(record) or record.status == "cancelling" then return end
		if err then finish(record, "failed", "Could not confirm authorization code; reconnect to check the account"); return end
		record.code_submitted = true
		owner.update_attempt(record, { status = "polling" })
		schedule(record)
	end)
end

function M.cancel(id)
	local record = owner.get_attempt(id)
	if not record or not live(record) then return end
	owner.stop_attempt(record)
	if record.status == "complete" then owner.release_attempt(record); return end
	if not record.attempt_id then record.cancel_requested = true; return end
	if record.status == "cancelling" then return end
	owner.update_attempt(record, { status = "cancelling" })
	client().integration(record.kind .. "_cancel", record.integration_id, nil, options(record), function(err)
		if not live(record) then return end
		finish(record, "cancelled", err and "Cancellation was not confirmed by the server" or nil)
		owner.release_attempt(record)
	end)
end

function M.connect_key(integration_id, key, answer, opts, callback)
	local token = pending.token()
	client().integration("key", integration_id, { key = key, answer = answer, label = opts.label }, opts, function(err)
		if not pending.is_current(token) then callback({ message = "Server connection changed" }); return end
		if err then callback(err); return end
		client().integration("get", integration_id, nil, opts, function(get_err, integration)
			if not pending.is_current(token) then callback({ message = "Server connection changed" }); return end
			refresh(opts.directory)
			callback(get_err, integration)
		end)
	end)
end

function M.credential(operation, integration_id, credential_id, body, opts, callback)
	local key = integration_id .. "\0" .. credential_id
	if owner.is_pending(key) then return end
	owner.mark(key)
	local token = pending.token()
	client().credential(operation, credential_id, body, function(err)
		owner.remember(key)
		if not pending.is_current(token) then callback({ message = "Server connection changed" }); return end
		if err then callback(err); return end
		client().integration("get", integration_id, nil, opts, function(get_err, integration)
			if not pending.is_current(token) then callback({ message = "Server connection changed" }); return end
			refresh(opts.directory)
			callback(get_err, integration)
		end)
	end)
end

return M
