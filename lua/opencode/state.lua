local M = {}

local pending_helper = require("opencode.session.attention")
local session_status = require("opencode.session.status")
local session_util = require("opencode.util.session")

local state = {
	-- Connection lifecycle
	connection = "idle", -- "idle" | "starting" | "connecting" | "connected" | "error"

	-- Server info
	server = {
		pid = nil,
		managed = false,
		host = "localhost",
		url = nil,
		port = nil,
		version = nil,
	},

	-- Current session
	session = {
		id = nil,
		name = nil,
		message_count = 0,
	},

	-- Session index/cache for parallel root sessions.
	sessions = {
		runtime_order = {},
		closed_order = {},
		recent_order = {},
		by_id = {},
		status = {},
		status_revision = {},
		pending = {},
		message_cache = {},
	},

	-- Streaming/thinking status
	status = "idle", -- "idle" | "streaming" | "thinking" | "paused" | "error"

	-- Danger mode: auto-approve permission requests while enabled.
	danger_mode = false,

	-- Configuration reference
	config = nil,
}

local listeners = {}
local revision = 0

local function emit_change(key, old_val, new_val)
	revision = revision + 1
	local cbs = key ~= "*" and vim.list_slice(listeners[key] or {}) or {}
	local wildcards = vim.list_slice(listeners["*"] or {})
	for _, cb in ipairs(cbs) do
		local ok, err = pcall(cb, new_val, old_val, key)
		if not ok then
			vim.notify("State listener error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end

	for _, cb in ipairs(wildcards) do
		local ok, err = pcall(cb, key, new_val, old_val)
		if not ok then
			vim.notify("State wildcard listener error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

-- Monotonic across reset; derived selectors do not need listener ownership.
function M.get_revision()
	return revision
end

---@param key string
---@param value any
---@param path? string
---@return any old_value
local function set(key, value, path)
	local old_val
	local target = path and state[path] or state

	if target then
		old_val = target[key]
		target[key] = value
	end

	if old_val ~= value then
		emit_change(path and (path .. "." .. key) or key, old_val, value)
	end

	return old_val
end

local function get(key, path)
	local target = path and state[path] or state
	return target and target[key] or nil
end

---@param id string
local function touch_runtime_session(id)
	if not id or id == "" then
		return
	end

	-- Keep runtime tabs in insertion order; activation only changes tab styling.
	local next_order = {}
	local seen = {}
	for _, existing in ipairs(state.sessions.runtime_order or {}) do
		if existing ~= "" and not seen[existing] then
			table.insert(next_order, existing)
			seen[existing] = true
		end
	end
	if not seen[id] then
		table.insert(next_order, id)
	end

	local old = state.sessions.runtime_order
	state.sessions.runtime_order = next_order
	for i = #state.sessions.closed_order, 1, -1 do
		if state.sessions.closed_order[i] == id then table.remove(state.sessions.closed_order, i) end
	end
	emit_change("sessions.runtime_order", old, state.sessions.runtime_order)
end

-- Default cap for recent history when the caller passes no configured limit.
local RECENT_LIMIT = 30
-- Closed tabs that can be reopened.
local CLOSED_LIMIT = 30
-- Per-session runtime data mirrored from the server and pending interactions.
local RUNTIME_FIELDS = { "status", "pending", "message_cache" }

---Clear a session's runtime data now; the returned function announces the
---removals after the caller's own change events.
---@param session_id string
---@return fun()
local function drop_runtime_data(session_id)
	local old = {}
	for _, field in ipairs(RUNTIME_FIELDS) do
		old[field] = state.sessions[field][session_id]
		state.sessions[field][session_id] = nil
	end
	return function()
		for _, field in ipairs(RUNTIME_FIELDS) do
			emit_change("sessions." .. field .. "." .. session_id, old[field], nil)
		end
	end
end

---@param order string[]|nil
---@param id string
---@return string[]
local function remove_order_id(order, id)
	local next_order = {}
	for _, existing in ipairs(order or {}) do
		if existing ~= id then
			table.insert(next_order, existing)
		end
	end
	return next_order
end

---@param session table
---@return table|nil
local function upsert_session_record(session)
	if type(session) ~= "table" or not session.id or session.id == "" then
		return nil
	end

	local id = session.id
	local old = state.sessions.by_id[id]
	local record = old and vim.deepcopy(old) or { id = id }

	for key, value in pairs(session) do
		if (key == "revert" or key == "parentID") and value == vim.NIL then record[key] = nil end
		if value ~= nil and value ~= vim.NIL then
			if key == "time" and type(value) == "table" then
				record.time = vim.tbl_extend("force", record.time or {}, value)
				for _, watermark in ipairs({ "idle", "viewed" }) do
					local previous = old and old.time and old.time[watermark]
					if type(previous) == "number" and type(record.time[watermark]) == "number" then
						record.time[watermark] = math.max(previous, record.time[watermark])
					end
				end
			else record[key] = value end
		end
	end

	local title = session_util.displayTitle(record.title or record.name)
	local message_count = session.message_count
	if message_count == nil or message_count == vim.NIL then message_count = record.message_count end

	local updated_at = session.updated_at
	if updated_at == nil and type(session.time) == "table" then
		updated_at = session.time.updated or session.time.created
	end

	record.title = title or record.title or record.name or id
	record.name = session_util.displayTitle(record.name or record.title) or record.title or id
	record.message_count = tonumber(message_count) or 0
	record.updated_at = updated_at or record.updated_at or os.time() * 1000

	state.sessions.by_id[id] = record
	emit_change("sessions.by_id." .. id, old, record)
	return record
end

-- Connection state

function M.set_connection(status)
	local valid = { idle = true, starting = true, connecting = true, connected = true, error = true }
	if not valid[status] then
		error("Invalid connection state: " .. tostring(status))
	end
	return set("connection", status)
end

function M.get_connection()
	return get("connection")
end

function M.is_connected()
	return state.connection == "connected"
end

-- Server info

function M.set_server_pid(pid)
	return set("pid", pid, "server")
end

function M.get_server_pid()
	return get("pid", "server")
end

function M.set_server_managed(managed)
	return set("managed", managed, "server")
end

function M.is_server_managed()
	return get("managed", "server") == true
end

function M.set_server_info(info)
	local old_host = state.server.host
	local old_port = state.server.port
	local old_url = state.server.url

	if info.host then
		set("host", info.host, "server")
	end
	if info.port ~= nil then
		set("port", info.port, "server")
	end
	if info.url ~= nil then
		set("url", info.url, "server")
	end
	if info.version then
		set("version", info.version, "server")
	end

	return { host = old_host, port = old_port, url = old_url }
end

function M.get_server_info()
	return vim.deepcopy(state.server)
end

function M.clear_server_endpoint()
	set("url", nil, "server")
	set("port", nil, "server")
	set("version", nil, "server")
end

-- Session

---@param id string|nil
---@param name string|nil
---@param opts? { runtime?: boolean }
function M.set_session(id, name, opts)
	opts = opts or {}
	local old_id = state.session.id
	local old_name = state.session.name
	local display_name = session_util.displayTitle(name) or id

	set("id", id, "session")
	set("name", display_name, "session")

	if id then
		local existing_record = state.sessions.by_id[id]
		local record = upsert_session_record({
			id = id,
			title = name,
			name = display_name,
			message_count = existing_record and existing_record.message_count or 0,
		})
		if opts.runtime ~= false then
			touch_runtime_session(id)
		end
		if record and record.message_count then
			set("message_count", record.message_count, "session")
		end
	else
		set("message_count", 0, "session")
	end

	return { id = old_id, name = old_name }
end

function M.get_session()
	return vim.deepcopy(state.session)
end

---@param session table
---@param opts? table { touch?: boolean }
---@return table|nil
function M.upsert_session(session, opts)
	opts = opts or {}
	local record = upsert_session_record(session)
	if record and opts.touch ~= false then
		touch_runtime_session(record.id)
	end
	return record and vim.deepcopy(record) or nil
end

---@param sessions table[]|nil
---@param limit? number
function M.set_recent_sessions(sessions, limit)
	local next_order = {}
	local seen = {}
	limit = tonumber(limit) or RECENT_LIMIT

	for _, session in ipairs(sessions or {}) do
		if type(session) == "table" and session.id and not seen[session.id] then
			upsert_session_record(session)
			table.insert(next_order, session.id)
			seen[session.id] = true
			if limit > 0 and #next_order >= limit then
				break
			end
		end
	end

	if state.session.id and M.is_runtime_session(state.session.id) and not seen[state.session.id] then
		upsert_session_record({
			id = state.session.id,
			title = state.session.name,
			name = state.session.name,
			message_count = state.session.message_count,
		})
		table.insert(next_order, 1, state.session.id)
	end

	local old = state.sessions.recent_order
	state.sessions.recent_order = next_order
	emit_change("sessions.recent_order", old, state.sessions.recent_order)
end

---@param session_id string|nil
---@return boolean
function M.is_runtime_session(session_id)
	if not session_id or session_id == "" then
		return false
	end
	for _, id in ipairs(state.sessions.runtime_order or {}) do
		if id == session_id then
			return true
		end
	end
	return false
end

---@param session_id string
---@return table|nil
function M.get_session_record(session_id)
	local record = state.sessions.by_id[session_id]
	return record and vim.deepcopy(record) or nil
end

-- Enumerate known native metadata without copying message caches or config.
function M.get_session_ids()
	return vim.tbl_keys(state.sessions.by_id)
end

-- Ancestry reads do not need copies of the rest of the session metadata.
function M.get_session_parent_id(session_id)
	local record = state.sessions.by_id[session_id]
	local parent = record and record.parentID
	return type(parent) == "string" and parent ~= "" and parent or nil
end

function M.get_session_fork_source_id(session_id)
	local record = state.sessions.by_id[session_id]
	local source = record and type(record.fork) == "table" and record.fork.sessionID
	return type(source) == "string" and source ~= "" and source or nil
end

function M.get_runtime_session_order()
	return vim.list_slice(state.sessions.runtime_order)
end

function M.get_closed_session_order()
	return vim.list_slice(state.sessions.closed_order)
end

function M.set_runtime_session_order(ids)
	local order, seen = {}, {}
	for _, id in ipairs(ids or {}) do
		if type(id) == "string" and id ~= "" and not seen[id] and state.sessions.by_id[id] then
			order[#order + 1], seen[id] = id, true
		end
	end
	local old = state.sessions.runtime_order
	state.sessions.runtime_order = order
	emit_change("sessions.runtime_order", old, order)
end

-- Normalize directory paths for comparison/storage while preserving roots.
---@type fun(directory: string|nil): string|nil
M.normalize_directory = require("opencode.util.path").normalize

-- Scope requests to the session's project, which may differ from the current directory.
---@param session_id string|nil
---@return string|nil
function M.get_session_directory(session_id)
	if not session_id or session_id == "" then
		return nil
	end
	local record = state.sessions.by_id[session_id]
	if not record or type(record.directory) ~= "string" then
		return nil
	end
	return M.normalize_directory(record.directory)
end

---@param session_id string|nil
---@return table|nil removed
function M.remove_session(session_id)
	if not session_id or session_id == "" then
		return nil
	end

	local removed = state.sessions.by_id[session_id]
	local old_runtime = state.sessions.runtime_order
	local old_recent = state.sessions.recent_order

	state.sessions.runtime_order = remove_order_id(state.sessions.runtime_order, session_id)
	state.sessions.closed_order = remove_order_id(state.sessions.closed_order, session_id)
	state.sessions.recent_order = remove_order_id(state.sessions.recent_order, session_id)
	state.sessions.by_id[session_id] = nil
	local announce_runtime_data = drop_runtime_data(session_id)

	emit_change("sessions.runtime_order", old_runtime, state.sessions.runtime_order)
	emit_change("sessions.recent_order", old_recent, state.sessions.recent_order)
	emit_change("sessions.by_id." .. session_id, removed, nil)
	announce_runtime_data()

	return removed and vim.deepcopy(removed) or nil
end

---@param session_id string|nil
---@param recent_limit? number Recent-history cap from the caller's configuration
---@return table|nil closed
function M.close_runtime_session(session_id, recent_limit)
	if not session_id or session_id == "" then
		return nil
	end

	local was_runtime = M.is_runtime_session(session_id)
	local record = state.sessions.by_id[session_id]
	local old_runtime = state.sessions.runtime_order
	local old_recent = state.sessions.recent_order

	state.sessions.runtime_order = remove_order_id(state.sessions.runtime_order, session_id)
	if was_runtime then
		local closed = remove_order_id(state.sessions.closed_order, session_id)
		table.insert(closed, 1, session_id)
		while #closed > CLOSED_LIMIT do table.remove(closed) end
		state.sessions.closed_order = closed
	end
	local announce_runtime_data = drop_runtime_data(session_id)

	if record then
		local next_recent = remove_order_id(state.sessions.recent_order, session_id)
		table.insert(next_recent, 1, session_id)

		recent_limit = tonumber(recent_limit) or RECENT_LIMIT
		if recent_limit > 0 then
			while #next_recent > recent_limit do
				table.remove(next_recent)
			end
		end
		state.sessions.recent_order = next_recent
	end

	emit_change("sessions.runtime_order", old_runtime, state.sessions.runtime_order)
	if record then
		emit_change("sessions.recent_order", old_recent, state.sessions.recent_order)
	end
	announce_runtime_data()

	if record then
		return vim.deepcopy(record)
	end
	if was_runtime then
		return { id = session_id, title = session_id, name = session_id }
	end
	return nil
end

---@param session_id string
---@param status table|string
---@return table|nil previous
---@return boolean changed
function M.set_session_status(session_id, status)
	if not session_id or session_id == "" then
		return nil, false
	end
	state.sessions.status_revision[session_id] = (state.sessions.status_revision[session_id] or 0) + 1
	local old = state.sessions.status[session_id]
	local next_status = session_status.normalize_session_status(status)
	if vim.deep_equal(old, next_status) then
		return old and vim.deepcopy(old) or nil, false
	end
	state.sessions.status[session_id] = next_status
	emit_change("sessions.status." .. session_id, old, next_status)
	return old and vim.deepcopy(old) or nil, true
end

function M.get_session_status_revision(session_id)
	return state.sessions.status_revision[session_id] or 0
end

---@param session_id string|nil
---@return table
function M.get_session_status(session_id)
	if not session_id or session_id == "" then
		return { type = "idle" }
	end
	return vim.deepcopy(state.sessions.status[session_id] or { type = "idle" })
end

---@return string[]
function M.get_session_status_ids()
	local ids = vim.tbl_keys(state.sessions.status)
	table.sort(ids)
	return ids
end

---@param session_id string
---@param counts table
---@return table|nil previous
function M.set_session_pending_counts(session_id, counts)
	if not session_id or session_id == "" then
		return nil
	end
	local old = state.sessions.pending[session_id]
	local normalized = pending_helper.normalize_counts(counts)
	state.sessions.pending[session_id] = normalized
	emit_change("sessions.pending." .. session_id, old, normalized)
	return old and vim.deepcopy(old) or nil
end

---@param session_id string|nil
---@return table
function M.get_session_pending_counts(session_id)
	if not session_id or session_id == "" then
		return pending_helper.zero_counts()
	end
	return vim.deepcopy(state.sessions.pending[session_id] or pending_helper.zero_counts())
end

---@param session_id string
---@param cache table
---@return table|nil previous
function M.set_session_message_cache(session_id, cache)
	if not session_id or session_id == "" then
		return nil
	end
	local old = state.sessions.message_cache[session_id]
	local normalized = vim.tbl_deep_extend("force", old or {}, cache or {})
	normalized.updated_at = normalized.updated_at or os.time() * 1000
	state.sessions.message_cache[session_id] = normalized
	if type(normalized.count) == "number" then
		upsert_session_record({
			id = session_id,
			message_count = normalized.count,
		})
	end
	emit_change("sessions.message_cache." .. session_id, old, normalized)
	return old and vim.deepcopy(old) or nil
end

---@param session_id string|nil
---@return table
function M.get_session_message_cache(session_id)
	if not session_id or session_id == "" then
		return { count = 0, loaded = false }
	end
	return vim.deepcopy(state.sessions.message_cache[session_id] or { count = 0, loaded = false })
end

---@return table[]
-- Compatibility alias: the derived runtime-session records are built in selectors.
function M.get_active_sessions()
	return require("opencode.selectors").get_active_sessions()
end

function M.set_message_count(count)
	local old = set("message_count", count, "session")
	if state.session.id then
		M.set_session_message_cache(state.session.id, {
			count = count,
			loaded = true,
		})
	end
	return old
end

function M.get_message_count()
	return get("message_count", "session") or 0
end

-- Status

function M.set_status(status)
	local valid = { idle = true, streaming = true, thinking = true, paused = true, error = true }
	if not valid[status] then
		error("Invalid status: " .. tostring(status))
	end
	return set("status", status)
end

function M.get_status()
	return get("status")
end

function M.is_streaming()
	return state.status == "streaming"
end

function M.is_thinking()
	return state.status == "thinking"
end

function M.is_idle()
	return state.status == "idle"
end

-- Danger mode

---@param enabled boolean
---@return boolean old_enabled Previous danger mode state
function M.set_danger_mode(enabled)
	return set("danger_mode", enabled == true)
end

---@return boolean
function M.is_danger_mode_enabled()
	return state.danger_mode == true
end

---@return boolean enabled New danger mode state
function M.toggle_danger_mode()
	M.set_danger_mode(not state.danger_mode)
	return state.danger_mode
end

-- Configuration

-- Render caches compare it, so a config change invalidates them even when no
-- listener clears them.
local config_generation = 0

function M.set_config(config)
	local old = state.config
	state.config = vim.deepcopy(config)
	config_generation = config_generation + 1
	emit_change("config", old, state.config)
	return old
end

---@return integer
function M.get_config_generation()
	return config_generation
end

function M.get_config()
	return vim.deepcopy(state.config)
end

---The stored config without a copy, for hot read paths. Never mutate it.
---@return table|nil
function M.read_config()
	return state.config
end

-- Full state snapshot

function M.get_full_state()
	return vim.deepcopy(state)
end

function M.reset()
	local old = vim.deepcopy(state)

	state.connection = "idle"
	state.server = {
		pid = nil,
		managed = false,
		host = state.server.host,
		url = state.server.url,
		port = state.server.port,
		version = nil,
	}
	state.session = {
		id = nil,
		name = nil,
		message_count = 0,
	}
	state.sessions = {
		runtime_order = {},
		closed_order = {},
		recent_order = {},
		by_id = {},
		status = {},
		status_revision = {},
		pending = {},
		message_cache = {},
	}
	state.status = "idle"
	state.danger_mode = false

	emit_change("*", old, state)

	return old
end

-- Event subscription

function M.on(key, callback)
	listeners[key] = listeners[key] or {}
	table.insert(listeners[key], callback)
end

function M.off(key, callback)
	local cbs = listeners[key] or {}
	for i, cb in ipairs(cbs) do
		if cb == callback then
			table.remove(cbs, i)
			break
		end
	end
end

function M.clear_listeners()
	listeners = {}
end

-- Get status summary (for lualine, etc.)
-- Compatibility alias: the status summary is derived in selectors.
function M.get_status_summary()
	return require("opencode.selectors").get_status_summary()
end

return M
