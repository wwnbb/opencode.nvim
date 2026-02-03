-- opencode.nvim - Sync module (mirrors TUI's sync.tsx)
-- Centralized store for messages, parts, sessions, and other sync data
-- Uses binary search for efficient lookups like the TUI implementation

local M = {}

---@class SyncStore
---@field message table<string, Message[]> Messages by sessionID
---@field part table<string, Part[]> Parts by messageID
---@field session_status table<string, SessionStatus> Status by sessionID

---@class Message
---@field id string
---@field sessionID string
---@field role "user" | "assistant"
---@field parentID? string
---@field time { created: number, completed?: number }
---@field agent? string
---@field modelID? string
---@field providerID? string

---@class Part
---@field id string
---@field messageID string
---@field sessionID string
---@field type "text" | "tool" | "reasoning"
---@field text? string
---@field tool? string
---@field state? table

-- Internal store
local store = {
	message = {}, -- { [sessionID] = { Message, ... } }
	part = {}, -- { [messageID] = { Part, ... } }
	session_status = {}, -- { [sessionID] = { type = "idle" | "busy" } }
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

-- Get part ID from part
local function get_part_id(part)
	return part.id
end

---Handle message.updated event (mirrors TUI sync.tsx:228-265)
---@param info Message
function M.handle_message_updated(info)
	local session_id = info.sessionID
	if not session_id then
		return
	end

	local messages = store.message[session_id]

	-- If no messages for this session, create array with this message
	if not messages then
		store.message[session_id] = { info }
		return
	end

	-- Binary search for existing message
	local result = binary_search(messages, info.id, get_message_id)

	if result.found then
		-- Update existing message (reconcile)
		messages[result.index] = vim.tbl_deep_extend("force", messages[result.index], info)
	else
		-- Insert new message at correct position (maintains sorted order)
		table.insert(messages, result.index, info)

		-- Limit to 100 messages per session (like TUI)
		if #messages > 100 then
			local oldest = messages[1]
			table.remove(messages, 1)
			-- Also remove parts for oldest message
			store.part[oldest.id] = nil
		end
	end
end

---Handle message.removed event (mirrors TUI sync.tsx:267-279)
---@param session_id string
---@param message_id string
function M.handle_message_removed(session_id, message_id)
	local messages = store.message[session_id]
	if not messages then
		return
	end

	local result = binary_search(messages, message_id, get_message_id)
	if result.found then
		table.remove(messages, result.index)
		-- Also remove parts
		store.part[message_id] = nil
	end
end

---Handle message.part.updated event (mirrors TUI sync.tsx:281-299)
---@param part Part
function M.handle_part_updated(part)
	local message_id = part.messageID
	if not message_id then
		return
	end

	local parts = store.part[message_id]

	-- If no parts for this message, create array with this part
	if not parts then
		store.part[message_id] = { part }
		return
	end

	-- Binary search for existing part
	local result = binary_search(parts, part.id, get_part_id)

	if result.found then
		-- Update existing part (reconcile)
		parts[result.index] = vim.tbl_deep_extend("force", parts[result.index], part)
	else
		-- Insert new part at correct position
		table.insert(parts, result.index, part)
	end
end

---Handle message.part.removed event (mirrors TUI sync.tsx:302-314)
---@param message_id string
---@param part_id string
function M.handle_part_removed(message_id, part_id)
	local parts = store.part[message_id]
	if not parts then
		return
	end

	local result = binary_search(parts, part_id, get_part_id)
	if result.found then
		table.remove(parts, result.index)
	end
end

---Handle session.status event (mirrors TUI sync.tsx:223-225)
---@param session_id string
---@param status table
function M.handle_session_status(session_id, status)
	store.session_status[session_id] = status
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

---Get parts for a message
---@param message_id string
---@return Part[]
function M.get_parts(message_id)
	return store.part[message_id] or {}
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
		return parts[result.index]
	end
	return nil
end

---Get assembled text content for a message (from all text parts)
---@param message_id string
---@return string
function M.get_message_text(message_id)
	local parts = store.part[message_id] or {}
	local text_parts = {}

	for _, part in ipairs(parts) do
		if part.type == "text" and part.text then
			table.insert(text_parts, part.text)
		end
	end

	return table.concat(text_parts, "")
end

---Get reasoning text for a message (from all reasoning parts)
---@param message_id string
---@return string
function M.get_message_reasoning(message_id)
	local parts = store.part[message_id] or {}
	local reasoning_parts = {}

	for _, part in ipairs(parts) do
		if part.type == "reasoning" and part.text then
			table.insert(reasoning_parts, part.text)
		end
	end

	return table.concat(reasoning_parts, "")
end

---Get tool parts for a message
---@param message_id string
---@return Part[]
function M.get_message_tools(message_id)
	local parts = store.part[message_id] or {}
	local tool_parts = {}

	for _, part in ipairs(parts) do
		if part.type == "tool" then
			table.insert(tool_parts, part)
		end
	end

	return tool_parts
end

---Get session status
---@param session_id string
---@return table|nil
function M.get_session_status(session_id)
	return store.session_status[session_id]
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
		store.part[msg.id] = nil
	end

	-- Remove messages
	store.message[session_id] = nil

	-- Remove status
	store.session_status[session_id] = nil
end

---Clear all data
function M.clear_all()
	store.message = {}
	store.part = {}
	store.session_status = {}
end

---Get the raw store (for debugging)
---@return SyncStore
function M.get_store()
	return store
end

---Binary search utility (exported for testing)
M.binary_search = binary_search

return M
