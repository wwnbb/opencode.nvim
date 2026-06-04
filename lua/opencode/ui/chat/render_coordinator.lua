-- Single chat render coordination point.
-- Other modules request renders here instead of emitting chat_render directly.

local M = {}

local events_ref = nil
local pending = false
local pending_data = nil

---@param data table|nil
local function merge_pending(data)
	data = data or {}
	pending_data = pending_data or {}
	for key, value in pairs(data) do
		if key == "force" then
			pending_data.force = pending_data.force == true or value == true
		elseif pending_data[key] == nil then
			pending_data[key] = value
		end
	end
end

local function events()
	if events_ref then
		return events_ref
	end
	local ok, mod = pcall(require, "opencode.events")
	if ok then
		events_ref = mod
		return events_ref
	end
	return nil
end

function M.flush()
	if not pending then
		return
	end
	pending = false
	local data = pending_data or {}
	pending_data = nil

	local bus = events()
	if bus and type(bus.emit) == "function" then
		bus.emit("chat_render", data)
	end
end

---@param data? table
function M.request(data)
	merge_pending(data)
	if pending then
		return
	end

	pending = true
	vim.schedule(function()
		M.flush()
	end)
end

---@param events table
function M.setup(events)
	events_ref = events

	events.on("sync_changed", function(data)
		if type(data) == "table" and data.kind == "part" and data.action == "updated" then
			events.emit("chat_stream_part_updated", data)
			return
		end
		M.request(data)
	end)

	events.on("interaction_changed", function(data)
		M.request(data)
	end)

	events.on("todo_update", function(data)
		M.request(data)
	end)

	events.on("status_change", function(data)
		M.request(data)
	end)

	events.on("session_change", function(data)
		M.request(data)
	end)

	events.on("session_status_change", function(data)
		M.request(data)
	end)

	events.on("session_pending_change", function(data)
		M.request(data)
	end)

	events.on("sessions_changed", function(data)
		M.request(data)
	end)

end

return M
