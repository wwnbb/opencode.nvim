-- opencode.nvim - State management module
-- Centralized state store for all plugin data

local M = {}

local session_util = require("opencode.util.session")

-- Internal state store
local state = {
	-- Connection lifecycle
	connection = "idle", -- "idle" | "starting" | "connecting" | "connected" | "error"
	
	-- Server info
	server = {
		pid = nil,
		managed = false,
		host = "localhost",
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
		recent_order = {},
		by_id = {},
		status = {},
		pending = {},
		message_cache = {},
	},
	
	-- Current model/provider/agent
	model = {
		id = nil,
		name = nil,
		provider = nil,
	},
	
	agent = {
		id = nil,
		name = nil,
	},
	
	-- Streaming/thinking status
	status = "idle", -- "idle" | "streaming" | "thinking" | "paused" | "error"

	-- Danger mode: auto-approve permission requests while enabled.
	danger_mode = false,
	
	-- Pending changes from edits
	pending_changes = {
		files = {},
		total_additions = 0,
		total_deletions = 0,
	},
	
	-- Configuration reference
	config = nil,
}

-- State change listeners
local listeners = {}

-- Emit state change event
local function emit_change(key, old_val, new_val)
	local cbs = listeners[key] or {}
	for _, cb in ipairs(cbs) do
		local ok, err = pcall(cb, new_val, old_val, key)
		if not ok then
			vim.notify("State listener error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
	
	-- Also emit to wildcard listeners
	local wildcards = listeners["*"] or {}
	for _, cb in ipairs(wildcards) do
		local ok, err = pcall(cb, key, new_val, old_val)
		if not ok then
			vim.notify("State wildcard listener error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

-- Set state value with optional event emission
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

-- Get state value
local function get(key, path)
	local target = path and state[path] or state
	return target and target[key] or nil
end

---@param title any
---@return string|nil
local function display_session_title(title)
	return session_util.displayTitle(title) or (type(title) == "string" and title ~= "" and title or nil)
end

---@param id string
---@param limit number|nil
local function touch_runtime_session(id, limit)
	if not id or id == "" then
		return
	end

	-- Keep runtime tabs in insertion order; activation only changes tab styling.
	local next_order = {}
	local seen = {}
	local found = false
	for _, existing in ipairs(state.sessions.runtime_order or {}) do
		if existing == id then
			found = true
		end
		if existing ~= "" and not seen[existing] then
			table.insert(next_order, existing)
			seen[existing] = true
		end
	end
	if not found then
		table.insert(next_order, id)
	end

	limit = tonumber(limit) or 30
	if limit > 0 then
		while #next_order > limit do
			if next_order[1] == id then
				table.remove(next_order)
			else
				table.remove(next_order, 1)
			end
		end
	end

	local old = state.sessions.runtime_order
	state.sessions.runtime_order = next_order
	emit_change("sessions.runtime_order", old, state.sessions.runtime_order)
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
		if value ~= nil and value ~= vim.NIL then
			record[key] = value
		end
	end

	local title = display_session_title(record.title or record.name)
	local message_count = session.message_count
	if message_count == nil or message_count == vim.NIL then
		message_count = session.messageCount
	end
	if message_count == nil or message_count == vim.NIL then
		message_count = record.message_count
	end
	if message_count == nil or message_count == vim.NIL then
		message_count = record.messageCount
	end

	local updated_at = session.updated_at or session.updatedAt
	if updated_at == nil and type(session.time) == "table" then
		updated_at = session.time.updated or session.time.created
	end

	record.title = title or record.title or record.name or id
	record.name = display_session_title(record.name or record.title) or record.title or id
	record.message_count = tonumber(message_count) or 0
	record.messageCount = record.message_count
	record.updated_at = updated_at or record.updated_at or os.time() * 1000

	state.sessions.by_id[id] = record
	emit_change("sessions.by_id." .. id, old, record)
	return record
end

---@param status any
---@return table
local function normalize_session_status(status)
	if type(status) == "table" then
		return vim.deepcopy(status)
	end
	if type(status) == "string" and status ~= "" then
		return { type = status }
	end
	return { type = "idle" }
end

local function zero_pending_counts()
	return {
		permissions = 0,
		questions = 0,
		edits = 0,
	}
end

---@param counts table|nil
---@return table
local function normalize_pending_counts(counts)
	counts = counts or {}
	return {
		permissions = tonumber(counts.permissions or counts.permission or 0) or 0,
		questions = tonumber(counts.questions or counts.question or 0) or 0,
		edits = tonumber(counts.edits or counts.edit or 0) or 0,
	}
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
	
	if info.host then
		set("host", info.host, "server")
	end
	if info.port ~= nil then
		set("port", info.port, "server")
	end
	if info.version then
		set("version", info.version, "server")
	end
	
	return { host = old_host, port = old_port }
end

function M.get_server_info()
	return vim.deepcopy(state.server)
end

-- Session

---@param id string|nil
---@param name string|nil
---@param opts? { runtime?: boolean }
function M.set_session(id, name, opts)
	opts = opts or {}
	local old_id = state.session.id
	local old_name = state.session.name
	local display_name = display_session_title(name) or id

	set("id", id, "session")
	set("name", display_name, "session")

	if id then
		local existing_record = state.sessions.by_id[id]
		local recent_limit = state.config
			and state.config.session
			and state.config.session.parallel
			and state.config.session.parallel.recent_limit
		local record = upsert_session_record({
			id = id,
			title = name,
			name = display_name,
			message_count = existing_record and existing_record.message_count or 0,
		})
		if opts.runtime ~= false then
			touch_runtime_session(id, recent_limit)
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
---@param opts? table { touch?: boolean, limit?: number }
---@return table|nil
function M.upsert_session(session, opts)
	opts = opts or {}
	local record = upsert_session_record(session)
	if record and opts.touch ~= false then
		local recent_limit = state.config
			and state.config.session
			and state.config.session.parallel
			and state.config.session.parallel.recent_limit
		touch_runtime_session(record.id, opts.limit or recent_limit)
	end
	return record and vim.deepcopy(record) or nil
end

---@param sessions table[]|nil
---@param limit? number
function M.set_recent_sessions(sessions, limit)
	local next_order = {}
	local seen = {}
	limit = tonumber(limit) or 30

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

---@return table[]
function M.get_recent_sessions()
	local result = {}
	local seen = {}
	for _, id in ipairs(state.sessions.recent_order or {}) do
		local record = state.sessions.by_id[id]
		if record and not seen[id] then
			table.insert(result, vim.deepcopy(record))
			seen[id] = true
		end
	end

	if state.session.id and M.is_runtime_session(state.session.id) and not seen[state.session.id] then
		table.insert(result, 1, {
			id = state.session.id,
			title = state.session.name,
			name = state.session.name,
			message_count = state.session.message_count,
		})
	end

	return result
end

---@return table[]
function M.get_runtime_sessions()
	local result = {}
	local seen = {}
	for _, id in ipairs(state.sessions.runtime_order or {}) do
		local record = state.sessions.by_id[id]
		if record and not seen[id] then
			table.insert(result, vim.deepcopy(record))
			seen[id] = true
		end
	end

	return result
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

---@param session_id string|nil
---@return table|nil removed
function M.remove_session(session_id)
	if not session_id or session_id == "" then
		return nil
	end

	local removed = state.sessions.by_id[session_id]
	local old_runtime = state.sessions.runtime_order
	local old_recent = state.sessions.recent_order
	local old_status = state.sessions.status[session_id]
	local old_pending = state.sessions.pending[session_id]
	local old_cache = state.sessions.message_cache[session_id]

	state.sessions.runtime_order = remove_order_id(state.sessions.runtime_order, session_id)
	state.sessions.recent_order = remove_order_id(state.sessions.recent_order, session_id)
	state.sessions.by_id[session_id] = nil
	state.sessions.status[session_id] = nil
	state.sessions.pending[session_id] = nil
	state.sessions.message_cache[session_id] = nil

	emit_change("sessions.runtime_order", old_runtime, state.sessions.runtime_order)
	emit_change("sessions.recent_order", old_recent, state.sessions.recent_order)
	emit_change("sessions.by_id." .. session_id, removed, nil)
	emit_change("sessions.status." .. session_id, old_status, nil)
	emit_change("sessions.pending." .. session_id, old_pending, nil)
	emit_change("sessions.message_cache." .. session_id, old_cache, nil)

	return removed and vim.deepcopy(removed) or nil
end

---@param session_id string|nil
---@return table|nil closed
function M.close_runtime_session(session_id)
	if not session_id or session_id == "" then
		return nil
	end

	local was_runtime = M.is_runtime_session(session_id)
	local record = state.sessions.by_id[session_id]
	local old_runtime = state.sessions.runtime_order
	local old_recent = state.sessions.recent_order
	local old_status = state.sessions.status[session_id]
	local old_pending = state.sessions.pending[session_id]
	local old_cache = state.sessions.message_cache[session_id]

	state.sessions.runtime_order = remove_order_id(state.sessions.runtime_order, session_id)
	state.sessions.status[session_id] = nil
	state.sessions.pending[session_id] = nil
	state.sessions.message_cache[session_id] = nil

	if record then
		local next_recent = { session_id }
		for _, existing in ipairs(state.sessions.recent_order or {}) do
			if existing ~= session_id then
				table.insert(next_recent, existing)
			end
		end

		local recent_limit = state.config
			and state.config.session
			and state.config.session.parallel
			and state.config.session.parallel.recent_limit
		recent_limit = tonumber(recent_limit) or 30
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
	emit_change("sessions.status." .. session_id, old_status, nil)
	emit_change("sessions.pending." .. session_id, old_pending, nil)
	emit_change("sessions.message_cache." .. session_id, old_cache, nil)

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
function M.set_session_status(session_id, status)
	if not session_id or session_id == "" then
		return nil
	end
	local old = state.sessions.status[session_id]
	local next_status = normalize_session_status(status)
	state.sessions.status[session_id] = next_status
	emit_change("sessions.status." .. session_id, old, next_status)
	return old and vim.deepcopy(old) or nil
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
	local ids = {}
	for id, _ in pairs(state.sessions.status or {}) do
		table.insert(ids, id)
	end
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
	local normalized = normalize_pending_counts(counts)
	state.sessions.pending[session_id] = normalized
	emit_change("sessions.pending." .. session_id, old, normalized)
	return old and vim.deepcopy(old) or nil
end

---@param session_id string|nil
---@return table
function M.get_session_pending_counts(session_id)
	if not session_id or session_id == "" then
		return zero_pending_counts()
	end
	return vim.deepcopy(state.sessions.pending[session_id] or zero_pending_counts())
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
			messageCount = normalized.count,
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
function M.get_active_sessions()
	local result = {}
	local seen = {}

	local function add_session(id)
		if not id or id == "" or seen[id] then
			return
		end
		local record = vim.deepcopy(state.sessions.by_id[id] or {
			id = id,
			title = id,
			name = id,
			message_count = 0,
		})
		local cache = M.get_session_message_cache(id)
		local pending = M.get_session_pending_counts(id)
		record.status = M.get_session_status(id)
		record.pending = pending
		record.cached_messages = cache
		record.message_count = record.message_count or record.messageCount or cache.count or 0
		record.name = display_session_title(record.name or record.title) or record.title or id
		record.title = display_session_title(record.title or record.name) or record.name or id
		record.is_current = state.session.id == id
		table.insert(result, record)
		seen[id] = true
	end

	for _, id in ipairs(state.sessions.runtime_order or {}) do
		add_session(id)
	end

	for id, status in pairs(state.sessions.status or {}) do
		local status_type = type(status) == "table" and status.type or status
		if M.is_runtime_session(id) and state.sessions.by_id[id] and status_type and status_type ~= "idle" then
			add_session(id)
		end
	end

	for id, pending in pairs(state.sessions.pending or {}) do
		local counts = normalize_pending_counts(pending)
		if
			M.is_runtime_session(id)
			and state.sessions.by_id[id]
			and (counts.permissions > 0 or counts.questions > 0 or counts.edits > 0)
		then
			add_session(id)
		end
	end

	return result
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

function M.increment_message_count()
	local current = M.get_message_count()
	M.set_message_count(current + 1)
	return current + 1
end

-- Model

function M.set_model(id, name, provider)
	local old = vim.deepcopy(state.model)
	
	set("id", id, "model")
	set("name", name or id, "model")
	set("provider", provider, "model")
	
	return old
end

function M.get_model()
	local ok, selectors = pcall(require, "opencode.selectors")
	if ok and selectors.current_model then
		local model = selectors.current_model()
		if type(model) == "table" and ((model.modelID and model.modelID ~= "") or (model.name and model.name ~= "")) then
			return {
				id = model.modelID or model.id,
				name = model.name or model.modelID or model.id,
				provider = model.providerID or model.provider,
			}
		end
	end
	return vim.deepcopy(state.model)
end

-- Agent

function M.set_agent(id, name)
	local old = vim.deepcopy(state.agent)

	set("id", id, "agent")
	set("name", name or id, "agent")

	return old
end

function M.get_agent()
	local ok, selectors = pcall(require, "opencode.selectors")
	if ok and selectors.current_agent then
		local agent = selectors.current_agent()
		if type(agent) == "table" and ((agent.id and agent.id ~= "") or (agent.name and agent.name ~= "")) then
			return {
				id = agent.id or agent.name,
				name = agent.name or agent.id,
			}
		end
	end
	return vim.deepcopy(state.agent)
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

-- Pending changes

function M.add_pending_change(file_path, change_data)
	state.pending_changes.files[file_path] = {
		original = change_data.original,
		modified = change_data.modified,
		hunks = change_data.hunks or {},
		status = "pending",
		additions = change_data.additions or 0,
		deletions = change_data.deletions or 0,
	}
	
	state.pending_changes.total_additions = state.pending_changes.total_additions + (change_data.additions or 0)
	state.pending_changes.total_deletions = state.pending_changes.total_deletions + (change_data.deletions or 0)
	
	emit_change("pending_changes.files." .. file_path, nil, state.pending_changes.files[file_path])
	emit_change("pending_changes.total_additions", nil, state.pending_changes.total_additions)
	emit_change("pending_changes.total_deletions", nil, state.pending_changes.total_deletions)
	
	return true
end

function M.get_pending_change(file_path)
	local ok, changes = pcall(require, "opencode.artifact.changes")
	if ok and changes.get_all then
		for _, change in ipairs(changes.get_all()) do
			if change.filepath == file_path then
				return change
			end
		end
	end
	return state.pending_changes.files[file_path] and vim.deepcopy(state.pending_changes.files[file_path]) or nil
end

function M.get_all_pending_changes()
	local ok, changes = pcall(require, "opencode.artifact.changes")
	if ok and changes.get_pending then
		local result = {}
		for _, change in ipairs(changes.get_pending()) do
			result[change.filepath] = change
		end
		return result
	end
	return vim.deepcopy(state.pending_changes.files)
end

function M.get_pending_changes_stats()
	local ok, selectors = pcall(require, "opencode.selectors")
	if ok and selectors.changes_stats then
		return selectors.changes_stats()
	end
	return {
		total_files = vim.tbl_count(state.pending_changes.files),
		total_additions = state.pending_changes.total_additions,
		total_deletions = state.pending_changes.total_deletions,
	}
end

function M.update_pending_change_status(file_path, hunk_index, status)
	local change = state.pending_changes.files[file_path]
	if not change then
		return nil
	end
	
	if hunk_index then
		local hunk = change.hunks[hunk_index]
		if hunk then
			hunk.status = status
		end
	else
		change.status = status
	end
	
	emit_change("pending_changes.files." .. file_path .. ".status", nil, status)
	
	return change
end

function M.remove_pending_change(file_path)
	local change = state.pending_changes.files[file_path]
	if change then
		state.pending_changes.total_additions = state.pending_changes.total_additions - change.additions
		state.pending_changes.total_deletions = state.pending_changes.total_deletions - change.deletions
		state.pending_changes.files[file_path] = nil
		
		emit_change("pending_changes.files." .. file_path, change, nil)
		emit_change("pending_changes.total_additions", nil, state.pending_changes.total_additions)
		emit_change("pending_changes.total_deletions", nil, state.pending_changes.total_deletions)
	end
	
	return change
end

function M.clear_all_pending_changes()
	local old = vim.deepcopy(state.pending_changes)
	state.pending_changes = {
		files = {},
		total_additions = 0,
		total_deletions = 0,
	}
	
	emit_change("pending_changes", old, state.pending_changes)
	
	return old
end

-- Configuration

function M.set_config(config)
	local old = state.config
	state.config = vim.deepcopy(config)
	emit_change("config", old, state.config)
	return old
end

function M.get_config()
	return vim.deepcopy(state.config)
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
		recent_order = {},
		by_id = {},
		status = {},
		pending = {},
		message_cache = {},
	}
	state.status = "idle"
	state.danger_mode = false
	state.pending_changes = {
		files = {},
		total_additions = 0,
		total_deletions = 0,
	}
	
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
function M.get_status_summary()
	local model = M.get_model()
	local agent = M.get_agent()
	return {
		connected = M.is_connected(),
		connection_state = state.connection,
		status = state.status,
		model = model.name,
		provider = model.provider,
		agent = agent.name,
		session = state.session.name,
		message_count = state.session.message_count,
		session_status = state.session.id and M.get_session_status(state.session.id) or { type = "idle" },
		session_pending = state.session.id and M.get_session_pending_counts(state.session.id) or zero_pending_counts(),
		active_sessions = M.get_active_sessions(),
		danger_mode = state.danger_mode,
		diff_stats = M.get_pending_changes_stats(),
	}
end

return M
