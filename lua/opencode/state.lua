-- opencode.nvim - State management module
-- Centralized state store for all plugin data

local M = {}

-- Internal state store
local state = {
	-- Connection lifecycle
	connection = "idle", -- "idle" | "starting" | "connecting" | "connected" | "error"
	
	-- Server info
	server = {
		pid = nil,
		managed = false,
		host = "localhost",
		port = 9099,
		version = nil,
	},
	
	-- Current session
	session = {
		id = nil,
		name = nil,
		message_count = 0,
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
		mode = nil,
	},
	
	-- Streaming/thinking status
	status = "idle", -- "idle" | "streaming" | "thinking" | "paused" | "error"
	
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
	if info.port then
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

function M.set_session(id, name)
	local old_id = state.session.id
	local old_name = state.session.name
	
	set("id", id, "session")
	set("name", name or id, "session")
	
	return { id = old_id, name = old_name }
end

function M.get_session()
	return vim.deepcopy(state.session)
end

function M.set_message_count(count)
	return set("message_count", count, "session")
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
	return vim.deepcopy(state.model)
end

-- Agent

function M.set_agent(id, name, mode)
	local old = vim.deepcopy(state.agent)
	
	set("id", id, "agent")
	set("name", name or id, "agent")
	set("mode", mode, "agent")
	
	return old
end

function M.get_agent()
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
	return state.pending_changes.files[file_path] and vim.deepcopy(state.pending_changes.files[file_path]) or nil
end

function M.get_all_pending_changes()
	return vim.deepcopy(state.pending_changes.files)
end

function M.get_pending_changes_stats()
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
	state.status = "idle"
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
	return {
		connected = M.is_connected(),
		connection_state = state.connection,
		status = state.status,
		model = state.model.name,
		provider = state.model.provider,
		agent = state.agent.name,
		mode = state.agent.mode,
		session = state.session.name,
		message_count = state.session.message_count,
		diff_stats = M.get_pending_changes_stats(),
	}
end

return M
