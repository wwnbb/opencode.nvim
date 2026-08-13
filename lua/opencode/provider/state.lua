-- Transient provider auth state. This is intentionally not wired into
-- cleanup.clear_transient or state.reset.

local M = {}

local pending = {}
local identity_getter

local function real_identity()
	local state = require("opencode.state")
	local info = state.get_server_info()
	local host = info and info.host
	local port = info and info.port
	if host == nil and port == nil then
		return nil
	end
	return tostring(host or "") .. ":" .. tostring(port or "")
end

local function get_identity()
	if identity_getter then
		return identity_getter()
	end
	return real_identity()
end

local function entry_is_pending(entry, now)
	return entry ~= nil and (entry.stamp == nil or now == nil or now == entry.stamp)
end

---@param fn function|nil
function M.set_identity_getter(fn)
	identity_getter = fn
end

---@param provider_id string|nil
function M.mark(provider_id)
	if provider_id == nil then
		return
	end
	pending[provider_id] = { stamp = get_identity() }
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
function M.remember(provider_id)
	if provider_id == nil then
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
	for provider_id, _ in pairs(set) do
		if entry_is_pending(pending[provider_id], now) then
			set[provider_id] = nil
		end
	end
	return set
end

return M
