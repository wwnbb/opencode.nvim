-- Single chat render coordination point.
-- Other modules request renders here instead of emitting chat_render directly.

local M = {}

local events_ref = nil
local pending = false
local pending_data = nil
local stream_pending = false
local stream_updates = {}
local STREAM_UPDATE_DELAY_MS = 16
local setup_events_ref = nil
local setup_listener_generation = nil

---@param events table
---@param event_type string
---@return any
local function get_listener_generation(events, event_type)
	if type(events.get_generation) == "function" then
		return events.get_generation()
	end
	if type(events.listener_count) == "function" then
		return events.listener_count(event_type)
	end
	return nil
end

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

local function stream_update_key(data)
	if type(data) ~= "table" then
		return nil
	end
	return table.concat({
		tostring(data.session_id or data.sessionID or data.sessionId or ""),
		tostring(data.message_id or data.messageID or data.messageId or ""),
		tostring(data.part_id or data.partID or data.partId or ""),
	}, "\0")
end

function M.flush_stream_updates()
	stream_pending = false
	local updates = stream_updates
	stream_updates = {}

	local bus = events()
	if not bus or type(bus.emit) ~= "function" then
		return
	end
	local count = 0
	for _, data in pairs(updates) do
		count = count + 1
		bus.emit("chat_stream_part_updated", data)
	end
end

local function merge_stream_update(existing, data)
	if type(existing) ~= "table" then
		return data
	end
	data = data or {}
	local merged = vim.tbl_extend("force", existing, data)
	if
		type(existing.delta) == "string"
		and type(data.delta) == "string"
		and existing.field == data.field
	then
		merged.delta = existing.delta .. data.delta
		merged.field = data.field
	elseif existing.delta ~= nil or data.delta ~= nil then
		merged.delta = nil
		merged.field = nil
	end
	return merged
end

---@param data? table
function M.request_stream_update(data)
	local key = stream_update_key(data)
	if key then
		stream_updates[key] = merge_stream_update(stream_updates[key], data)
	end
	if stream_pending then
		return
	end
	stream_pending = true
	vim.defer_fn(function()
		M.flush_stream_updates()
	end, STREAM_UPDATE_DELAY_MS)
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
	local generation = get_listener_generation(events, "sync_changed")
	if
		setup_events_ref == events
		and (
			(type(events.get_generation) == "function" and generation == setup_listener_generation)
			or (type(events.get_generation) ~= "function" and (type(events.listener_count) ~= "function" or generation > 0))
		)
	then
		return
	end
	setup_events_ref = events
	setup_listener_generation = generation
	events_ref = events

	events.on("sync_changed", function(data)
		if
			type(data) == "table"
			and data.kind == "part"
			and data.action == "updated"
			and type(data.delta) == "string"
		then
			M.request_stream_update(data)
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
