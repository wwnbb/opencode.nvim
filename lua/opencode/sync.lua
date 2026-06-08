-- opencode.nvim - Sync module (mirrors TUI's sync.tsx)
-- Centralized store for messages, parts, sessions, and other sync data
-- Uses binary search for efficient lookups like the TUI implementation

local M = {}
local perf = require("opencode.perf")

---@class SyncStore
---@field message table<string, Message[]> Messages by sessionID
---@field part table<string, Part[]> Parts by messageID
---@field session_status table<string, SessionStatus> Status by sessionID
---@field todo table<string, OpenCodeTodo[]> Todos by sessionID

---@class OpenCodeTodo
---@field content string Brief task description
---@field status "pending"|"in_progress"|"completed"|"cancelled"
---@field priority? "high"|"medium"|"low"

---@class Message
---@field id string
---@field sessionID string
---@field role "user" | "assistant"
---@field parentID? string
---@field time { created: number, completed?: number }
---@field agent? string
---@field modelID? string
---@field providerID? string
---@field finish? string Finish reason: "tool-calls", "end-turn", "stop", "unknown", etc.

---@class Part
---@field id string
---@field messageID string
---@field sessionID string
---@field type "text" | "tool" | "reasoning"
---@field text? string
---@field tool? string
---@field state? table
---@field synthetic? boolean

---@class PartDelta
---@field messageID string
---@field partID string
---@field field string
---@field delta string
---@field sessionID? string

-- Internal store
local store = {
	message = {},       -- { [sessionID] = { Message, ... } }
	message_session = {}, -- { [messageID] = sessionID }
	part = {},          -- { [messageID] = { Part, ... } }
	part_delta_buffer = {}, -- { [messageID .. "\0" .. partID .. "\0" .. field] = { string, ... } }
	session_status = {}, -- { [sessionID] = { type = "idle" | "busy" } }
	todo = {},          -- { [sessionID] = { Todo, ... } }
	task_child_parent = {}, -- { [child_session_id] = parent_session_id }
	task_child_owner = {}, -- { [child_session_id] = messageID .. "\0" .. partID }
	task_part_child = {}, -- { [messageID .. "\0" .. partID] = child_session_id }
	message_revision = {}, -- { [messageID] = number } internal render invalidation
	part_revision = {}, -- { [messageID .. "\0" .. partID] = number } internal render invalidation
	session_revision = {}, -- { [sessionID] = number } internal render invalidation
	provider_revision = 0, -- internal render invalidation for model metadata
	agent_revision = 0,    -- internal render invalidation for agent colors
	-- Provider/agent/model data (like TUI's sync.tsx)
	provider = {},      -- Array of connected provider info
	provider_default = {}, -- { [providerID] = default_modelID }
	agent = {},         -- Array of available agents
	command = {},       -- Array of custom commands
	skill = {},         -- Array of available skills
	config = {},        -- Global config
	mcp = {},           -- MCP server status
}

local UTILITY_AGENT_NAMES = {
	compaction = true,
	summary = true,
	title = true,
}

-- Binary search implementation (matches TUI's Binary.search)
-- Returns { found = bool, index = number }
-- If found, index is the position of the item
-- If not found, index is where the item should be inserted
---@param arr table Array to search
---@param target string Target ID to find
---@param get_id function Function to extract ID from item
---@return { found: boolean, index: number }
local function binary_search(arr, target, get_id)
	if not arr or #arr == 0 then
		return { found = false, index = 1 }
	end

	local left = 1
	local right = #arr

	while left <= right do
		local mid = math.floor((left + right) / 2)
		local mid_id = get_id(arr[mid])

		if mid_id == target then
			return { found = true, index = mid }
		elseif mid_id < target then
			left = mid + 1
		else
			right = mid - 1
		end
	end

	return { found = false, index = left }
end

-- Get message ID from message
local function get_message_id(msg)
	return msg.id
end

local find_message_session_id
local clear_part_delta_buffers_for_message
local clear_task_child_indices_for_message

local function index_message_session(session_id, message_id)
	if session_id and message_id and message_id ~= "" then
		store.message_session[message_id] = session_id
	end
end

local function unindex_message_session(message_id)
	if message_id then
		store.message_session[message_id] = nil
	end
end

---@param message_id string|nil
---@param part_id string|nil
---@return string|nil
local function part_revision_key(message_id, part_id)
	if not message_id or not part_id then
		return nil
	end
	return message_id .. "\0" .. part_id
end

---@param message_id string|nil
---@param part_id string|nil
---@param field string|nil
---@return string|nil
local function part_delta_key(message_id, part_id, field)
	if not message_id or not part_id or not field then
		return nil
	end
	return message_id .. "\0" .. part_id .. "\0" .. field
end

---@param message_id string|nil
---@param part_id string|nil
---@return string|nil
local function part_key(message_id, part_id)
	return part_revision_key(message_id, part_id)
end

---@param map table
---@param key string|nil
---@return number
local function bump_revision(map, key)
	if not key or key == "" then
		return 0
	end
	local next_revision = (map[key] or 0) + 1
	map[key] = next_revision
	return next_revision
end

---@param field string
local function bump_store_counter(field)
	store[field] = (store[field] or 0) + 1
end

---@param session_id string|nil
local function bump_session_revision(session_id)
	bump_revision(store.session_revision, session_id)
end

---@param message_id string|nil
---@param session_id string|nil
local function bump_message_revision(message_id, session_id)
	if not message_id or message_id == "" then
		return
	end
	bump_revision(store.message_revision, message_id)
	bump_session_revision(session_id or find_message_session_id(message_id))
end

---@param message_id string|nil
---@param part_id string|nil
---@param session_id string|nil
local function bump_part_revision(message_id, part_id, session_id)
	bump_message_revision(message_id, session_id)
	bump_revision(store.part_revision, part_revision_key(message_id, part_id))
end

---@param old_value any
---@param new_value any
---@return boolean
local function values_changed(old_value, new_value)
	return not vim.deep_equal(old_value, new_value)
end

---@param message_id string|nil
local function clear_message_revisions(message_id)
	if not message_id then
		return
	end
	store.message_revision[message_id] = nil
	local prefix = message_id .. "\0"
	for key in pairs(store.part_revision) do
		if key:sub(1, #prefix) == prefix then
			store.part_revision[key] = nil
		end
	end
end

-- Find owning session for a message ID.
-- Returns sessionID string or nil.
function find_message_session_id(message_id)
	local indexed = store.message_session[message_id]
	if indexed then
		return indexed
	end
	for session_id, messages in pairs(store.message) do
		local result = binary_search(messages, message_id, get_message_id)
		if result.found then
			index_message_session(session_id, message_id)
			return session_id
		end
	end
	return nil
end

-- Ensure a message row exists for a part update.
-- This lets streaming text render even if message.updated arrives slightly later.
local function ensure_message_for_part(part)
	local message_id = part.messageID
	if not message_id then
		return
	end

	local session_id = part.sessionID or find_message_session_id(message_id)
	if not session_id then
		return
	end

	part.sessionID = part.sessionID or session_id

	local placeholder = {
		id = message_id,
		sessionID = session_id,
		role = "assistant",
		time = {
			created = vim.uv.now(),
		},
	}

	local messages = store.message[session_id]
	if not messages then
		store.message[session_id] = { placeholder }
		index_message_session(session_id, message_id)
		return
	end

	local result = binary_search(messages, message_id, get_message_id)
	if result.found then
		return
	end

	table.insert(messages, result.index, placeholder)
	index_message_session(session_id, message_id)

	-- Keep the same 100 message cap behavior as regular message updates.
	if #messages > 100 then
		local oldest = messages[1]
		table.remove(messages, 1)
		clear_part_delta_buffers_for_message(oldest.id)
		clear_task_child_indices_for_message(oldest.id)
		store.part[oldest.id] = nil
		unindex_message_session(oldest.id)
		clear_message_revisions(oldest.id)
	end
end

-- Get part ID from part
local function get_part_id(part)
	return part.id
end

---@param root table
---@param path string[]
---@return any
local function get_nested(root, path)
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

---@param root table
---@param path string[]
---@param value any
local function set_nested(root, path, value)
	if #path == 0 then
		return
	end

	local node = root
	for i = 1, #path - 1 do
		local key = path[i]
		if type(node[key]) ~= "table" then
			node[key] = {}
		end
		node = node[key]
	end
	node[path[#path]] = value
end

---@param field string
---@return string[]
local function split_part_field(field)
	if type(field) ~= "string" or field == "" then
		return {}
	end
	return vim.split(field, ".", { plain = true, trimempty = true })
end

---@param message_id string
---@param part_id string
---@param field string
---@param delta string
local function buffer_part_delta(message_id, part_id, field, delta)
	local key = part_delta_key(message_id, part_id, field)
	if not key or delta == "" then
		return
	end
	local chunks = store.part_delta_buffer[key]
	if not chunks then
		chunks = {}
		store.part_delta_buffer[key] = chunks
	end
	table.insert(chunks, delta)
end

---@param part Part
---@param field string
local function materialize_part_field(part, field)
	if type(part) ~= "table" then
		return
	end
	local message_id = part.messageID
	local part_id = part.id
	local key = part_delta_key(message_id, part_id, field)
	local chunks = key and store.part_delta_buffer[key]
	if type(chunks) ~= "table" or #chunks == 0 then
		if key then
			store.part_delta_buffer[key] = nil
		end
		return
	end

	local path = split_part_field(field)
	if #path == 0 then
		store.part_delta_buffer[key] = nil
		return
	end

	local current = get_nested(part, path)
	if type(current) ~= "string" then
		current = ""
	end
	set_nested(part, path, current .. table.concat(chunks))
	store.part_delta_buffer[key] = nil
end

---@param part Part
local function materialize_part(part)
	if type(part) ~= "table" or not part.messageID or not part.id then
		return
	end
	local prefix = part.messageID .. "\0" .. part.id .. "\0"
	local fields = {}
	for key in pairs(store.part_delta_buffer) do
		if key:sub(1, #prefix) == prefix then
			table.insert(fields, key:sub(#prefix + 1))
		end
	end
	for _, field in ipairs(fields) do
		materialize_part_field(part, field)
	end
end

---@param parts Part[]|nil
---@return Part[]
local function materialize_parts(parts)
	local done = perf.start("sync.materialize_parts")
	for _, part in ipairs(parts or {}) do
		materialize_part(part)
	end
	local result = parts or {}
	done({ parts = #result })
	return result
end

---@param message_id string|nil
---@param part_id string|nil
local function clear_part_delta_buffers(message_id, part_id)
	if not message_id or not part_id then
		return
	end
	local prefix = message_id .. "\0" .. part_id .. "\0"
	for key in pairs(store.part_delta_buffer) do
		if key:sub(1, #prefix) == prefix then
			store.part_delta_buffer[key] = nil
		end
	end
end

---@param message_id string|nil
clear_part_delta_buffers_for_message = function(message_id)
	if not message_id then
		return
	end
	local prefix = message_id .. "\0"
	for key in pairs(store.part_delta_buffer) do
		if key:sub(1, #prefix) == prefix then
			store.part_delta_buffer[key] = nil
		end
	end
end

---@param message_id string|nil
---@return Message|nil
local function get_message_by_id(message_id)
	local session_id = message_id and find_message_session_id(message_id)
	if not session_id then
		return nil
	end

	local messages = store.message[session_id]
	if not messages then
		return nil
	end

	local result = binary_search(messages, message_id, get_message_id)
	if result.found then
		return messages[result.index]
	end
	return nil
end

---@param message_id string|nil
---@return boolean
local function is_incomplete_assistant_message(message_id)
	local message = get_message_by_id(message_id)
	return message ~= nil and message.role == "assistant" and not (message.time and message.time.completed ~= nil)
end

---@param dest table
---@param src table
---@param merged table
local function preserve_streaming_text(dest, src, merged)
	if not (src.type == "text" or src.type == "reasoning" or dest.type == "text" or dest.type == "reasoning") then
		return
	end
	if not is_incomplete_assistant_message(dest.messageID or src.messageID) then
		return
	end

	local dest_text = dest.text
	local src_text = src.text
	if type(dest_text) ~= "string" or type(src_text) ~= "string" then
		return
	end
	if #src_text < #dest_text then
		merged.text = dest_text
	end
end

---@param dest table
---@param src table
---@param merged table
---@param path string[]
local function preserve_summary_path(dest, src, merged, path)
	local src_summary = get_nested(src, path)
	if src_summary == nil then
		return
	end

	local dest_summary = get_nested(dest, path)
	if type(src_summary) == "table" and next(src_summary) == nil then
		if type(dest_summary) == "table" and next(dest_summary) ~= nil then
			set_nested(merged, path, dest_summary)
			return
		end
	end

	set_nested(merged, path, src_summary)
end

---@param tool_part table|nil
---@return string|nil
local function resolve_task_child_session_id(tool_part)
	if type(tool_part) ~= "table" or tool_part.tool ~= "task" then
		return nil
	end

	local part_metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}

	return state_metadata.sessionId
		or state_metadata.sessionID
		or state_metadata.session_id
		or state_metadata.childSessionID
		or state_metadata.childSessionId
		or state_metadata.child_session_id
		or part_metadata.sessionId
		or part_metadata.sessionID
		or part_metadata.session_id
		or part_metadata.childSessionID
		or part_metadata.childSessionId
		or part_metadata.child_session_id
		or tool_part.childSessionID
		or tool_part.childSessionId
		or tool_part.child_session_id
end

---@param message_id string|nil
---@param part_id string|nil
local function clear_task_child_index(message_id, part_id)
	local key = part_key(message_id, part_id)
	if not key then
		return
	end
	local child_session_id = store.task_part_child[key]
	if child_session_id then
		if store.task_child_owner[child_session_id] == key then
			store.task_child_parent[child_session_id] = nil
			store.task_child_owner[child_session_id] = nil
		end
	end
	store.task_part_child[key] = nil
end

---@param parent_session_id string
---@param message_id string
---@param part_id string
---@param child_session_id string
---@return boolean changed
local function record_task_child_index(parent_session_id, message_id, part_id, child_session_id)
	if
		not parent_session_id
		or parent_session_id == ""
		or not message_id
		or message_id == ""
		or not part_id
		or part_id == ""
		or not child_session_id
		or child_session_id == ""
	then
		return false
	end

	local key = part_key(message_id, part_id)
	if not key then
		return false
	end

	local changed = false
	local existing_child = store.task_part_child[key]
	if existing_child ~= child_session_id then
		clear_task_child_index(message_id, part_id)
		changed = true
	end

	local existing_owner = store.task_child_owner[child_session_id]
	if existing_owner and existing_owner ~= key then
		store.task_part_child[existing_owner] = nil
		local old_message_id, old_part_id = existing_owner:match("^(.-)%z(.+)$")
		if old_message_id and old_part_id then
			bump_part_revision(old_message_id, old_part_id, find_message_session_id(old_message_id))
		end
		changed = true
	end

	if
		store.task_part_child[key] ~= child_session_id
		or store.task_child_parent[child_session_id] ~= parent_session_id
		or store.task_child_owner[child_session_id] ~= key
	then
		changed = true
	end

	store.task_part_child[key] = child_session_id
	store.task_child_parent[child_session_id] = parent_session_id
	store.task_child_owner[child_session_id] = key

	if changed then
		bump_part_revision(message_id, part_id, parent_session_id)
	end
	return changed
end

---@param part table|nil
local function index_task_child(part)
	if type(part) ~= "table" then
		return
	end

	local message_id = part.messageID
	local part_id = part.id
	clear_task_child_index(message_id, part_id)

	if part.type ~= "tool" or part.tool ~= "task" then
		return
	end

	local child_session_id = resolve_task_child_session_id(part)
	if not child_session_id or child_session_id == "" then
		return
	end

	local parent_session_id = part.sessionID or find_message_session_id(message_id)
	if not parent_session_id or parent_session_id == "" then
		return
	end

	local key = part_key(message_id, part_id)
	if not key then
		return
	end

	record_task_child_index(parent_session_id, message_id, part_id, child_session_id)
end

---@param message_id string|nil
clear_task_child_indices_for_message = function(message_id)
	if not message_id then
		return
	end
	local prefix = message_id .. "\0"
	for key in pairs(store.task_part_child) do
		if key:sub(1, #prefix) == prefix then
			local child_session_id = store.task_part_child[key]
			if child_session_id and store.task_child_owner[child_session_id] == key then
				store.task_child_parent[child_session_id] = nil
				store.task_child_owner[child_session_id] = nil
			end
			store.task_part_child[key] = nil
		end
	end
end

---Handle message.updated event (mirrors TUI sync.tsx:228-265)
---@param info Message
---@return boolean changed
function M.handle_message_updated(info)
	local session_id = info.sessionID
	if not session_id then
		return false
	end

	local messages = store.message[session_id]
	local changed = false
	local previous_session_id = store.message_session[info.id]
	if previous_session_id and previous_session_id ~= session_id then
		M.handle_message_removed(previous_session_id, info.id)
		changed = true
	end

	-- If no messages for this session, create array with this message
	if not messages then
		store.message[session_id] = { info }
		index_message_session(session_id, info.id)
		bump_message_revision(info.id, session_id)
		return true
	end

	-- Binary search for existing message
	local result = binary_search(messages, info.id, get_message_id)

	if result.found then
		-- Update existing message (reconcile)
		local current = messages[result.index]
		local merged = vim.tbl_deep_extend("force", current, info)
		changed = values_changed(current, merged)
		messages[result.index] = merged
		index_message_session(session_id, info.id)
		if changed then
			bump_message_revision(info.id, session_id)
		end
	else
		-- Insert new message at correct position (maintains sorted order)
		table.insert(messages, result.index, info)
		index_message_session(session_id, info.id)
		bump_message_revision(info.id, session_id)
		changed = true

		-- Limit to 100 messages per session (like TUI)
		if #messages > 100 then
			local oldest = messages[1]
			table.remove(messages, 1)
			-- Also remove parts for oldest message
			clear_part_delta_buffers_for_message(oldest.id)
			clear_task_child_indices_for_message(oldest.id)
			store.part[oldest.id] = nil
			unindex_message_session(oldest.id)
			clear_message_revisions(oldest.id)
		end
	end
	return changed
end

---Handle message.removed event (mirrors TUI sync.tsx:267-279)
---@param session_id string
---@param message_id string
function M.handle_message_removed(session_id, message_id)
	local messages = store.message[session_id]
	if not messages then
		clear_part_delta_buffers_for_message(message_id)
		clear_task_child_indices_for_message(message_id)
		store.part[message_id] = nil
		unindex_message_session(message_id)
		clear_message_revisions(message_id)
		return
	end

	local result = binary_search(messages, message_id, get_message_id)
	if result.found then
		table.remove(messages, result.index)
		-- Also remove parts
		clear_part_delta_buffers_for_message(message_id)
		clear_task_child_indices_for_message(message_id)
		store.part[message_id] = nil
		unindex_message_session(message_id)
		clear_message_revisions(message_id)
		bump_session_revision(session_id)
	end
end

---Handle message.part.updated event (mirrors TUI sync.tsx:281-299)
---@param part Part
---@return boolean changed
function M.handle_part_updated(part)
	local message_id = part.messageID
	if not message_id then
		return false
	end

	ensure_message_for_part(part)

	local parts = store.part[message_id]

	-- If no parts for this message, create array with this part
	if not parts then
		store.part[message_id] = { part }
		clear_part_delta_buffers(message_id, part.id)
		index_task_child(part)
		bump_part_revision(message_id, part.id, part.sessionID)
		return true
	end

	-- Binary search for existing part
	local result = binary_search(parts, part.id, get_part_id)

	if result.found then
		-- Update existing part (reconcile)
		local dest = parts[result.index]
		materialize_part(dest)
		local src = part
		local merged = vim.tbl_deep_extend("force", dest, src)

		-- During streaming, /message snapshots and part.updated events can lag
		-- behind accumulated deltas. Do not let a stale shorter snapshot erase
		-- text that will be restored only after the final full update.
		preserve_streaming_text(dest, src, merged)

		-- Preserve task summary arrays when backend sends an empty dictionary in partial updates.
		preserve_summary_path(dest, src, merged, { "state", "metadata", "summary" })
		preserve_summary_path(dest, src, merged, { "metadata", "summary" })

		local changed = values_changed(dest, merged)
		parts[result.index] = merged
		clear_part_delta_buffers(message_id, part.id)
		index_task_child(merged)
		if changed then
			bump_part_revision(message_id, part.id, part.sessionID)
		end
		return changed
	else
		-- Insert new part at correct position
		table.insert(parts, result.index, part)
		clear_part_delta_buffers(message_id, part.id)
		index_task_child(part)
		bump_part_revision(message_id, part.id, part.sessionID)
		return true
	end
end

---Handle message.part.delta event by appending streamed text to an existing part field.
---Falls back to creating a text part if the part does not exist yet.
---@param part_delta PartDelta
---@return Part|nil
function M.handle_part_delta(part_delta)
	local done = perf.start("sync.handle_part_delta")
	local message_id = part_delta.messageID
	local part_id = part_delta.partID
	local field = part_delta.field
	local delta = part_delta.delta

	if not message_id or not part_id or not field or type(delta) ~= "string" then
		done({ ignored = true })
		return nil
	end

	local session_id = part_delta.sessionID or find_message_session_id(message_id)
	local parts = store.part[message_id]
	if not parts then
		parts = {}
		store.part[message_id] = parts
	end

	local result = binary_search(parts, part_id, get_part_id)
	if not result.found then
		local new_part = {
			id = part_id,
			messageID = message_id,
			sessionID = session_id,
			type = "text",
		}
		ensure_message_for_part(new_part)
		table.insert(parts, result.index, new_part)
	end

	local part = parts[result.index]
	if part_delta.sessionID and not part.sessionID then
		part.sessionID = part_delta.sessionID
	end
	buffer_part_delta(message_id, part_id, field, delta)
	bump_part_revision(message_id, part_id, part.sessionID)
	done({
		message_id = message_id,
		part_id = part_id,
		field = field,
		delta_bytes = #delta,
		parts = #parts,
	})
	return part
end

---Handle message.part.removed event (mirrors TUI sync.tsx:302-314)
---@param message_id string
---@param part_id string
function M.handle_part_removed(message_id, part_id)
	local parts = store.part[message_id]
	if not parts then
		clear_part_delta_buffers(message_id, part_id)
		clear_task_child_index(message_id, part_id)
		return
	end

	clear_part_delta_buffers(message_id, part_id)
	clear_task_child_index(message_id, part_id)
	local result = binary_search(parts, part_id, get_part_id)
	if result.found then
		table.remove(parts, result.index)
		bump_part_revision(message_id, part_id, find_message_session_id(message_id))
	end
end

---Hydrate messages and parts from /session/:id/message (mirrors TUI session.sync)
---@param session_id string
---@param messages table[]|nil
---@return number message_count
---@return number part_count
---@return number changed_count
function M.handle_session_messages(session_id, messages)
	if type(messages) ~= "table" then
		return 0, 0, 0
	end

	local message_count = 0
	local part_count = 0
	local changed_count = 0

	for _, msg_with_parts in ipairs(messages) do
		if type(msg_with_parts) == "table" then
			local info = msg_with_parts.info or msg_with_parts
			if type(info) == "table" and info.id then
				info.sessionID = info.sessionID or session_id
				if M.handle_message_updated(info) then
					changed_count = changed_count + 1
				end
				message_count = message_count + 1
			end

			if type(msg_with_parts.parts) == "table" then
				for _, part in ipairs(msg_with_parts.parts) do
					if type(part) == "table" then
						part.sessionID = part.sessionID or (info and info.sessionID) or session_id
						if M.handle_part_updated(part) then
							changed_count = changed_count + 1
						end
						part_count = part_count + 1
					end
				end
			end
		end
	end

	return message_count, part_count, changed_count
end

---Handle session.status event (mirrors TUI sync.tsx:223-225)
---@param session_id string
---@param status table
function M.handle_session_status(session_id, status)
	store.session_status[session_id] = status
	bump_session_revision(session_id)
end

---Handle todo.updated event (mirrors TUI sync.tsx todo store updates)
---@param session_id string
---@param todos OpenCodeTodo[]|nil
function M.handle_todo_updated(session_id, todos)
	if not session_id or session_id == "" then
		return
	end
	if type(todos) ~= "table" then
		store.todo[session_id] = {}
		return
	end

	store.todo[session_id] = vim.deepcopy(todos)
	bump_session_revision(session_id)
end

---Get messages for a session
---@param session_id string
---@return Message[]
function M.get_messages(session_id)
	return store.message[session_id] or {}
end

---Get a specific message
---@param session_id string
---@param message_id string
---@return Message|nil
function M.get_message(session_id, message_id)
	local messages = store.message[session_id]
	if not messages then
		return nil
	end

	local result = binary_search(messages, message_id, get_message_id)
	if result.found then
		return messages[result.index]
	end
	return nil
end

---Find the owning session for a message ID
---@param message_id string
---@return string|nil
function M.find_message_session_id(message_id)
	return find_message_session_id(message_id)
end

---@param session_id string
---@return number
function M.get_session_revision(session_id)
	return store.session_revision[session_id] or 0
end

---@param message_id string
---@return number
function M.get_message_revision(message_id)
	return store.message_revision[message_id] or 0
end

---@param message_id string
---@param part_id string
---@return number
function M.get_part_revision(message_id, part_id)
	local key = part_revision_key(message_id, part_id)
	return key and store.part_revision[key] or 0
end

---Get parts for a message
---@param message_id string
---@return Part[]
function M.get_parts(message_id)
	local done = perf.start("sync.get_parts")
	local parts = materialize_parts(store.part[message_id])
	done({ message_id = message_id, parts = #parts })
	return parts
end

---Get a specific part
---@param message_id string
---@param part_id string
---@return Part|nil
function M.get_part(message_id, part_id)
	local parts = store.part[message_id]
	if not parts then
		return nil
	end

	local result = binary_search(parts, part_id, get_part_id)
	if result.found then
		materialize_part(parts[result.index])
		return parts[result.index]
	end
	return nil
end

---Get all render-relevant part data for a message in one scan.
---@param message_id string
---@param opts? { include_synthetic?: boolean }
---@return { content: string, reasoning: string, tool_parts: Part[], parts: Part[], message_revision: number, part_revisions: table<string, number> }
function M.get_message_render_parts(message_id, opts)
	local done = perf.start("sync.get_message_render_parts")
	opts = opts or {}
	local parts = materialize_parts(store.part[message_id])
	local text_parts = {}
	local reasoning_parts = {}
	local tool_parts = {}
	local part_revisions = {}

	for _, part in ipairs(parts) do
		if part.id then
			local key = part_revision_key(message_id, part.id)
			part_revisions[part.id] = key and store.part_revision[key] or 0
		end
		if part.type == "text" and part.text and (opts.include_synthetic ~= false or not part.synthetic) then
			table.insert(text_parts, part.text)
		elseif part.type == "reasoning" and part.text then
			table.insert(reasoning_parts, part.text)
		elseif part.type == "tool" then
			table.insert(tool_parts, part)
		end
	end

	local result = {
		content = table.concat(text_parts, ""),
		reasoning = table.concat(reasoning_parts, ""),
		tool_parts = tool_parts,
		parts = parts,
		message_revision = store.message_revision[message_id] or 0,
		part_revisions = part_revisions,
	}
	done({
		message_id = message_id,
		parts = #parts,
		text_parts = #text_parts,
		reasoning_parts = #reasoning_parts,
		tool_parts = #tool_parts,
		content_bytes = #result.content,
		reasoning_bytes = #result.reasoning,
	})
	return result
end

---Get assembled text content for a message (from all text parts)
---@param message_id string
---@param opts? { include_synthetic?: boolean }
---@return string
function M.get_message_text(message_id, opts)
	return M.get_message_render_parts(message_id, opts).content
end

---Get reasoning text for a message (from all reasoning parts)
---@param message_id string
---@return string
function M.get_message_reasoning(message_id)
	return M.get_message_render_parts(message_id).reasoning
end

---Get tool parts for a message
---@param message_id string
---@return Part[]
function M.get_message_tools(message_id)
	return M.get_message_render_parts(message_id).tool_parts
end

---@param child_session_id string|nil
---@return string|nil
function M.get_task_parent_session(child_session_id)
	if not child_session_id or child_session_id == "" then
		return nil
	end
	return store.task_child_parent[child_session_id]
end

---@param message_id string|nil
---@param part_id string|nil
---@return string|nil
function M.get_task_child_session(message_id, part_id)
	local key = part_key(message_id, part_id)
	return key and store.task_part_child[key] or nil
end

---@param child_session_id string|nil
---@return string|nil message_id
---@return string|nil part_id
function M.get_task_child_owner(child_session_id)
	if not child_session_id or child_session_id == "" then
		return nil, nil
	end
	local key = store.task_child_owner[child_session_id]
	if not key then
		return nil, nil
	end
	local message_id, part_id = key:match("^(.-)%z(.+)$")
	return message_id, part_id
end

---@param tool_part table|nil
---@return string|nil
function M.get_task_child_session_for_part(tool_part)
	if type(tool_part) ~= "table" then
		return nil
	end
	return M.get_task_child_session(tool_part.messageID, tool_part.id) or resolve_task_child_session_id(tool_part)
end

---@param parent_session_id string
---@param message_id string
---@param part_id string
---@param child_session_id string
---@return boolean changed
function M.record_task_child_session(parent_session_id, message_id, part_id, child_session_id)
	return record_task_child_index(parent_session_id, message_id, part_id, child_session_id)
end

---Get session status
---@param session_id string
---@return table|nil
function M.get_session_status(session_id)
	return store.session_status[session_id]
end

---Get todos for a session
---@param session_id string
---@return OpenCodeTodo[]
function M.get_todos(session_id)
	return store.todo[session_id] or {}
end

---Check if session is busy
---@param session_id string
---@return boolean
function M.is_session_busy(session_id)
	local status = store.session_status[session_id]
	return status and status.type == "busy"
end

---Clear all data for a session
---@param session_id string
function M.clear_session(session_id)
	-- Remove all parts for messages in this session
	local messages = store.message[session_id] or {}
	for _, msg in ipairs(messages) do
		clear_part_delta_buffers_for_message(msg.id)
		clear_task_child_indices_for_message(msg.id)
		store.part[msg.id] = nil
		unindex_message_session(msg.id)
		clear_message_revisions(msg.id)
	end

	-- Remove messages
	store.message[session_id] = nil
	store.session_revision[session_id] = nil

	-- Remove status
	store.session_status[session_id] = nil

	-- Remove todos
	store.todo[session_id] = nil
end

---Clear only messages/parts for a session, preserving status and todos.
---@param session_id string
function M.clear_session_messages(session_id)
	local messages = store.message[session_id] or {}
	for _, msg in ipairs(messages) do
		clear_part_delta_buffers_for_message(msg.id)
		clear_task_child_indices_for_message(msg.id)
		store.part[msg.id] = nil
		unindex_message_session(msg.id)
		clear_message_revisions(msg.id)
	end
	store.message[session_id] = nil
	bump_session_revision(session_id)
end

---Clear all data
function M.clear_all()
	store.message = {}
	store.message_session = {}
	store.part = {}
	store.part_delta_buffer = {}
	store.session_status = {}
	store.todo = {}
	store.task_child_parent = {}
	store.task_child_owner = {}
	store.task_part_child = {}
	store.message_revision = {}
	store.part_revision = {}
	store.session_revision = {}
	store.provider_revision = 0
	store.agent_revision = 0
	store.provider = {}
	store.provider_default = {}
	store.agent = {}
	store.command = {}
	store.skill = {}
	store.config = {}
	store.mcp = {}
end

-- Provider management (mirrors TUI sync.tsx)

---Handle provider data update
---@param providers table[] Array of provider objects
function M.handle_providers(providers)
	store.provider = providers or {}
	bump_store_counter("provider_revision")
end

---Handle provider defaults
---@param defaults table<string, string> { [providerID] = default_modelID }
function M.handle_provider_defaults(defaults)
	store.provider_default = defaults or {}
	bump_store_counter("provider_revision")
end

---Get provider/model metadata revision.
---@return number
function M.get_provider_revision()
	return store.provider_revision or 0
end

---Get all providers
---@return table[]
function M.get_providers()
	return store.provider or {}
end

---Get provider defaults
---@return table<string, string>
function M.get_provider_defaults()
	return store.provider_default or {}
end

---Get a specific provider by ID
---@param provider_id string
---@return table|nil
function M.get_provider(provider_id)
	for _, provider in ipairs(store.provider) do
		if provider.id == provider_id then
			return provider
		end
	end
	return nil
end

---Get a model from a provider
---@param provider_id string
---@param model_id string
---@return table|nil
function M.get_model(provider_id, model_id)
	local provider = M.get_provider(provider_id)
	if provider and provider.models then
		return provider.models[model_id]
	end
	return nil
end

-- Agent management

---Handle agent data update
---@param agents table[] Array of agent objects
function M.handle_agents(agents)
	store.agent = agents or {}
	bump_store_counter("agent_revision")
end

---Get agent metadata revision.
---@return number
function M.get_agent_revision()
	return store.agent_revision or 0
end

---Get all agents
---@return table[]
function M.get_agents()
	return store.agent or {}
end

---Check whether an agent should be selectable as a primary chat agent.
---@param agent table|nil Agent object
---@return boolean visible Whether the agent should be shown in primary-agent UI
function M.is_visible_agent(agent)
	if type(agent) ~= "table" then
		return false
	end
	-- JSON null decodes to vim.NIL, which is truthy; only boolean true means hidden.
	if agent.hidden == true then
		return false
	end

	local name = agent.name or agent.id
	if type(name) == "string" and UTILITY_AGENT_NAMES[name] then
		return false
	end

	return agent.mode ~= "subagent"
end

---Filter agents to primary-capable, user-visible entries.
---@param agents table[]|nil Array of agent objects
---@return table[] agents Filtered agents
function M.filter_visible_agents(agents)
	local visible = {}
	for _, agent in ipairs(agents or {}) do
		if M.is_visible_agent(agent) then
			table.insert(visible, agent)
		end
	end
	return visible
end

---Get filtered agents (excluding subagents, hidden agents, and utility agents)
---@return table[]
function M.get_visible_agents()
	return M.filter_visible_agents(store.agent)
end

---Get a specific agent by name
---@param name string
---@return table|nil
function M.get_agent(name)
	for _, agent in ipairs(store.agent) do
		if agent.name == name then
			return agent
		end
	end
	return nil
end

-- Config management

---Handle config update
---@param config table
function M.handle_config(config)
	store.config = config or {}
end

---Get config
---@return table
function M.get_config()
	return store.config or {}
end

-- Command management

---Handle custom commands update
---@param commands table[]
function M.handle_commands(commands)
	store.command = commands or {}
end

---Get commands
---@return table[]
function M.get_commands()
	return store.command or {}
end

-- Skill management

---Handle skills update
---@param skills table[]
function M.handle_skills(skills)
	store.skill = skills or {}
end

---Get skills
---@return table[]
function M.get_skills()
	return store.skill or {}
end

-- MCP management

---Handle MCP status update
---@param mcp table<string, table>
function M.handle_mcp(mcp)
	store.mcp = mcp or {}
end

---Get MCP status
---@return table<string, table>
function M.get_mcp()
	return store.mcp or {}
end

---Get the raw store (for debugging)
---@return SyncStore
function M.get_store()
	return store
end

---Binary search utility (exported for testing)
M.binary_search = binary_search

return M
