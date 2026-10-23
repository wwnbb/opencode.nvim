local M = {}

local ERROR_DEDUPE_MS = 10000

---@param value any
---@return string|nil
local function nonempty_string(value)
	if type(value) ~= "string" then
		return nil
	end
	local trimmed = vim.trim(value)
	if trimmed == "" then
		return nil
	end
	return trimmed
end

---@param root any
---@param path string[]
---@return any
local function get_path(root, path)
	local node = root
	for _, key in ipairs(path) do
		if type(node) ~= "table" then
			return nil
		end
		node = node[key]
		if node == nil then
			return nil
		end
	end
	return node
end

---@param err any
---@param seen? table
---@return string|nil
local function extract_error_message(err, seen)
	local direct = nonempty_string(err)
	if direct then
		return direct
	end
	if type(err) ~= "table" then
		return nil
	end

	seen = seen or {}
	if seen[err] then
		return nil
	end
	seen[err] = true

	for _, path in ipairs({
		{ "data", "error", "message" },
		{ "error", "message" },
		{ "body", "error", "message" },
		{ "response", "error", "message" },
		{ "data", "message" },
		{ "body", "message" },
		{ "response", "message" },
		{ "message" },
		{ "error" },
	}) do
		local value = nonempty_string(get_path(err, path))
		if value then
			return value
		end
	end

	for _, key in ipairs({ "error", "data", "body", "response", "cause" }) do
		local nested = extract_error_message(err[key], seen)
		if nested then
			return nested
		end
	end

	return nonempty_string(err.name) or nonempty_string(err._tag)
end

---@param err any
---@param seen? table
---@return string|nil
local function extract_error_code(err, seen)
	if type(err) ~= "table" then
		return nil
	end

	seen = seen or {}
	if seen[err] then
		return nil
	end
	seen[err] = true

	for _, key in ipairs({ "code", "name", "_tag" }) do
		local value = nonempty_string(err[key])
		if value then
			return value
		end
	end

	for _, key in ipairs({ "error", "data", "body", "response", "cause" }) do
		local nested = extract_error_code(err[key], seen)
		if nested then
			return nested
		end
	end

	local type_value = nonempty_string(err.type)
	if type_value and type_value ~= "error" then
		return type_value
	end
	return nil
end

---@param err any
---@return boolean
local function is_abort_error(err, seen)
	local message = extract_error_message(err)
	if message and message:lower() == "aborted" then
		return true
	end
	if type(err) ~= "table" then
		return false
	end
	seen = seen or {}
	if seen[err] then
		return false
	end
	seen[err] = true
	local name = err.name or err._tag
	if name == "MessageAbortedError" or name == "AbortError" then
		return true
	end
	return is_abort_error(err.error, seen) or is_abort_error(err.data, seen) or is_abort_error(err.cause, seen)
end

---@param err any
---@return boolean
function M.is_abort_error(err)
	return is_abort_error(err, {})
end

---@param err any
---@param opts? { fallback?: string, include_code?: boolean, raw_fallback?: boolean }
---@return string
function M.format_session_error(err, opts)
	opts = opts or {}
	local fallback = opts.fallback or "Session error"
	local message = extract_error_message(err)
	local code = nil
	if opts.include_code ~= false then
		code = extract_error_code(err)
	end

	message = message or code
	if not message and opts.raw_fallback ~= false and type(err) == "table" then
		local ok, encoded = pcall(vim.json.encode, err)
		if ok and encoded and encoded ~= "" then
			message = encoded
		end
	end

	message = message or fallback
	if code and code ~= "" and not message:find(code, 1, true) then
		message = message .. " [" .. code .. "]"
	end

	return message
end

---@param cache table<string, number>
---@param key string
---@param ttl_ms? number
---@return boolean duplicate
function M.mark_recent_error(cache, key, ttl_ms)
	local now = vim.uv.now()
	local ttl = ttl_ms or ERROR_DEDUPE_MS

	for cache_key, timestamp in pairs(cache) do
		if type(timestamp) ~= "number" or now - timestamp > ttl then
			cache[cache_key] = nil
		end
	end

	local duplicate = cache[key] ~= nil and now - cache[key] <= ttl
	cache[key] = now
	return duplicate
end

---@param tool_part table|nil
---@return string|nil
function M.resolve_task_child_session_id(tool_part)
	if type(tool_part) ~= "table" or tool_part.tool ~= "task" then
		return nil
	end

	local ok_sync, sync = pcall(require, "opencode.sync")
	if ok_sync then
		return nonempty_string(sync.get_task_child_session_for_part(tool_part))
	end
end

---@param parent_session_id string|nil
---@param child_session_id string|nil
---@return boolean
function M.session_owns_task_child(parent_session_id, child_session_id)
	local ok_sync, sync = pcall(require, "opencode.sync")
	return ok_sync and sync.session_owns_task_child(parent_session_id, child_session_id) or false
end

---@param current_session_id string|nil
---@param event_session_id string|nil
---@return string|nil
function M.render_target_session_id(current_session_id, event_session_id)
	if not current_session_id or current_session_id == "" then
		return nil
	end
	if not event_session_id or event_session_id == "" then
		return current_session_id
	end
	if event_session_id == current_session_id then
		return current_session_id
	end
	if M.session_owns_task_child(current_session_id, event_session_id) then
		return current_session_id
	end
	return nil
end

---@param session_id string|nil
---@return string|nil
function M.runtime_root_for_session(session_id)
	if not session_id or session_id == "" then
		return nil
	end

	local ok_state, state = pcall(require, "opencode.state")
	if not ok_state then
		return session_id
	end
	local ok_sync, sync = pcall(require, "opencode.sync")
	local visited = {}
	while type(session_id) == "string" and session_id ~= "" and not visited[session_id] do
		visited[session_id] = true
		if state.is_runtime_session(session_id) then
			return session_id
		end
		local parent = ok_sync and sync.get_task_parent_session(session_id) or nil
		parent = parent or state.get_session_parent_id(session_id)
		if not parent then
			-- Parts can arrive before their task-parent index is available.
			for _, root_id in ipairs(state.get_runtime_session_order()) do
				if M.session_owns_task_child(root_id, session_id) then return root_id end
			end
		end
		session_id = parent
	end

	return nil
end

---@param current_session_id string|nil
---@param event_session_id string|nil
---@return boolean
function M.permission_session_is_relevant(current_session_id, event_session_id)
	if not event_session_id or event_session_id == "" then
		return true
	end
	if not current_session_id or current_session_id == "" then
		return true
	end
	if event_session_id == current_session_id then
		return true
	end

	return M.session_owns_task_child(current_session_id, event_session_id)
end


return M
