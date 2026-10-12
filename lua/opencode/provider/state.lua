local M = {}

-- Pending provider marks survive transient cleanup; integration attempts do not.
local pending = {}
local identity_getter

local function get_identity()
	if identity_getter then
		return identity_getter()
	end
	local state = require("opencode.state")
	local info = state.get_server_info()
	local host = info and info.host
	local port = info and info.port
	if host == nil and port == nil then
		return nil
	end
	return tostring(host or "") .. ":" .. tostring(port or "")
end

local function entry_is_pending(entry, now)
	return entry ~= nil and (entry.stamp == nil or now == nil or now == entry.stamp)
		and (entry.token == nil or require("opencode.session.pending").is_current(entry.token))
end

---@param fn function|nil
function M.set_identity_getter(fn)
	identity_getter = fn
end

---@param provider_id string|nil
---@param token table|nil Connection token for an in-flight credential operation.
function M.mark(provider_id, token)
	if provider_id == nil then
		return
	end
	local entry = { stamp = get_identity(), token = token }
	pending[provider_id] = entry
	return entry
end

---@param provider_id string|nil
---@return boolean
function M.is_pending(provider_id)
	if provider_id == nil then
		return false
	end
	return entry_is_pending(pending[provider_id], get_identity())
end

---@param provider_id string|nil
---@param expected table|nil Only release the marker owned by this operation.
function M.remember(provider_id, expected)
	if provider_id == nil or (expected and pending[provider_id] ~= expected) then
		return
	end
	pending[provider_id] = nil
end

function M.clear_all()
	pending = {}
end

---@param set table|nil
---@return table|nil
function M.prune_connected(set)
	if type(set) ~= "table" then
		return set
	end

	local now = get_identity()
	for provider_id in pairs(set) do
		if entry_is_pending(pending[provider_id], now) then set[provider_id] = nil end
	end
	return set
end

-- Live integration attempts hold routing context only, never keys or authorization codes.
local attempts, serial = {}, 0
function M.begin_attempt(integration_id, kind, directory, listener)
	serial = serial + 1
	local record = { id = serial, integration_id = integration_id, kind = kind, directory = directory,
		stamp = get_identity(), token = require("opencode.session.pending").token(), status = "starting", listener = listener }
	attempts[serial] = record
	return record
end

function M.attempt_current(record)
	return attempts[record.id] == record and record.stamp == get_identity()
		and require("opencode.session.pending").is_current(record.token)
end

function M.update_attempt(record, patch)
	if not M.attempt_current(record) then return false end
	for key, value in pairs(patch) do record[key] = value end
	if record.listener then record.listener(M.attempt_view(record)) end
	return true
end

function M.attempt_view(record)
	local result = {}
	for _, key in ipairs({ "id", "integration_id", "kind", "directory", "status", "attempt_id", "url", "instructions", "mode", "expires", "error", "message" }) do
		result[key] = record[key]
	end
	return result
end

function M.get_attempt(id) return attempts[id] end
function M.stop_attempt(record)
	if record.timer then record.timer:stop(); record.timer:close(); record.timer = nil end
end
function M.release_attempt(record)
	M.stop_attempt(record)
	record.listener = nil
	attempts[record.id] = nil
end
function M.clear_attempts()
	local previous = attempts
	attempts = {}
	for _, record in pairs(previous) do
		M.stop_attempt(record)
		record.status, record.error = "cancelled", "Server connection changed"
		local listener = record.listener
		record.listener = nil
		if listener then listener(M.attempt_view(record)) end
	end
end

return M
