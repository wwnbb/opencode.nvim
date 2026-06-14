local M = {}

local pending_helper = require("opencode.session.pending")
local status_helper = require("opencode.session.status")
local session_util = require("opencode.util.session")

local METHODS = {}
local PRIVATE = setmetatable({}, { __mode = "k" })

local function private(view)
	return PRIVATE[view] or {}
end

local function copy(value)
	if type(value) == "table" then
		return vim.deepcopy(value)
	end
	return value
end

local function normalize_record(record)
	record = type(record) == "table" and vim.deepcopy(record) or {}
	if record.message_count == nil and record.messageCount ~= nil then
		record.message_count = record.messageCount
	end
	if record.messageCount == nil and record.message_count ~= nil then
		record.messageCount = record.message_count
	end
	if record.updated_at == nil and record.updatedAt ~= nil then
		record.updated_at = record.updatedAt
	end
	return record
end

local function title_for(record)
	local title = session_util.displayTitle(record.title or record.name)
	if title and title ~= "" then
		return title
	end
	return record.name or record.title or record.id
end

---@return string|nil
function METHODS:title()
	return title_for(private(self).record or {})
end

---@return boolean
function METHODS:is_busy()
	return status_helper.is_busy(private(self).status)
end

---@return boolean
function METHODS:is_idle()
	return status_helper.is_idle(private(self).status)
end

---@return boolean
function METHODS:is_error()
	return status_helper.is_error(private(self).status)
end

---@return boolean
function METHODS:is_waiting()
	return pending_helper.has_pending(private(self).pending)
end

---@return number
function METHODS:pending_total()
	return pending_helper.total(private(self).pending)
end

---@return number
function METHODS:message_count()
	local data = private(self)
	local cached_messages = data.cached_messages or {}
	local record = data.record or {}
	local cache_count = tonumber(cached_messages.count)
	if cached_messages.loaded ~= false and cache_count ~= nil then
		return cache_count
	end
	return tonumber(record.message_count or record.messageCount) or cache_count or 0
end

---@return string
function METHODS:status_type()
	return status_helper.status_type(private(self).status)
end

---@return string
function METHODS:status_label()
	return status_helper.status_label(private(self).status)
end

---@return boolean
function METHODS:is_current_session()
	return private(self).is_current == true
end

---@return boolean
function METHODS:is_current_root()
	local data = private(self)
	local record = data.record or {}
	return data.current_root_id ~= nil and data.current_root_id ~= "" and record.id == data.current_root_id
end

---@return table
function METHODS:to_record()
	local record = vim.deepcopy(private(self).record or {})
	local title = title_for(record)
	record.title = record.title or title
	record.name = record.name or title or record.id
	record.message_count = self:message_count()
	record.messageCount = record.message_count
	return record
end

local scalar_fields = {
	id = true,
	name = true,
	updated_at = true,
	updatedAt = true,
}

local view_mt = {
	__index = function(self, key)
		local data = private(self)
		local method = METHODS[key]
		if method then
			return method
		end
		if key == "record" then
			return vim.deepcopy(data.record or {})
		end
		if key == "status" then
			return vim.deepcopy(data.status or { type = "idle" })
		end
		if key == "pending" then
			return vim.deepcopy(data.pending or pending_helper.zero_counts())
		end
		if key == "cached_messages" then
			return vim.deepcopy(data.cached_messages or { count = 0, loaded = false })
		end
		if key == "messageCount" then
			return METHODS.message_count(self)
		end
		if scalar_fields[key] then
			return copy((data.record or {})[key])
		end
		return nil
	end,
	__newindex = function(_, key)
		error("SessionView is read-only: cannot assign " .. tostring(key), 2)
	end,
	__metatable = "SessionView",
}

---@param record table|nil
---@param ctx? table
---@return table
function M.from_record(record, ctx)
	ctx = type(ctx) == "table" and ctx or {}
	local normalized = normalize_record(record)
	local status = ctx.status ~= nil and ctx.status or normalized.status
	local pending = ctx.pending ~= nil and ctx.pending or normalized.pending
	local cached_messages = ctx.cached_messages or ctx.message_cache or normalized.cached_messages or { count = 0, loaded = false }

	local view = setmetatable({}, view_mt)
	PRIVATE[view] = {
		record = normalized,
		status = status_helper.normalize_session_status(status),
		pending = pending_helper.normalize_counts(pending),
		cached_messages = type(cached_messages) == "table" and vim.deepcopy(cached_messages) or { count = 0, loaded = false },
		is_current = ctx.is_current == true or normalized.is_current == true,
		is_runtime = ctx.is_runtime == true or normalized.is_runtime == true,
		current_root_id = ctx.current_root_id or normalized.current_root_id,
	}
	return view
end

return M
