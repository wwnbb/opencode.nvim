-- Action boundary for active-session and global-status mutations.
-- Compatibility events are emitted here instead of from the store itself.

local M = {}

local state = require("opencode.state")

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

---@param id string|nil
---@param name string|nil
---@param opts? table { reason?: string, preserve_cache?: boolean }
---@return table previous
function M.set_active(id, name, opts)
	opts = opts or {}
	local previous = state.set_session(id, name)
	local current = state.get_session()

	emit("session_change", {
		id = current.id,
		name = current.name,
		previous_id = previous.id,
		previous_name = previous.name,
		reason = opts.reason,
		preserve_cache = opts.preserve_cache == true,
	})

	return previous
end

---@param status string
---@param opts? table { reason?: string, session_id?: string }
---@return string previous
function M.set_status(status, opts)
	opts = opts or {}
	local previous = state.set_status(status)

	emit("status_change", {
		status = status,
		previous = previous,
		reason = opts.reason,
		session_id = opts.session_id,
	})

	return previous
end

return M
