local M = {}

local PROCESSING_STATUS = {
	busy = true,
	streaming = true,
	thinking = true,
	retry = true,
}

local function status_type(status)
	return type(status) == "table" and status.type or status
end

local function nonempty_string(value)
	return type(value) == "string" and value ~= ""
end

local function has_metadata(message)
	return type(message) == "table"
		and (
			nonempty_string(message.agent)
			or nonempty_string(message.mode)
			or nonempty_string(message.modelID)
			or nonempty_string(message.providerID)
		)
end

local function metadata_projection(message)
	message = type(message) == "table" and message or {}
	return {
		id = message.id,
		role = "assistant",
		agent = message.agent,
		mode = message.mode,
		modelID = message.modelID,
		providerID = message.providerID,
	}
end

---@param status table|string|nil
---@return boolean
function M.is_processing(status)
	return PROCESSING_STATUS[status_type(status)] == true
end

---@param messages table[]
---@return boolean
function M.has_pending_response_gap(messages)
	messages = messages or {}
	local last_message = messages[#messages]
	if not last_message or last_message.role ~= "assistant" then
		return true
	end
	local completed = last_message.time and last_message.time.completed ~= nil
	return not completed or last_message.finish == "tool-calls"
end

---@param messages table[]
---@param fallback_message table
---@return table
function M.metadata_message(messages, fallback_message)
	messages = messages or {}
	local active_assistant_index = nil
	for i = #messages, 1, -1 do
		local message = messages[i]
		if message.role == "user" then
			return fallback_message
		elseif message.role == "assistant" then
			active_assistant_index = i
			break
		end
	end
	if not active_assistant_index then
		return fallback_message
	end

	local active_assistant = messages[active_assistant_index]
	if has_metadata(active_assistant) then
		return active_assistant
	end

	-- A metadata-free assistant placeholder may be the continuation of the
	-- immediately preceding tool-calls message. Never cross a user-turn
	-- boundary: the local agent/model selection may have changed there.
	for i = active_assistant_index - 1, 1, -1 do
		local message = messages[i]
		if message.role == "user" then
			break
		end
		if message.role == "assistant" and message.finish == "tool-calls" and has_metadata(message) then
			return message
		end
	end
	return fallback_message
end

---The settled assistant message that closes the history, if the history ends in one.
---@param messages table[]
---@return table|nil
local function settled_last_assistant(messages)
	local last = messages[#messages]
	if type(last) == "table" and last.role == "assistant" and not M.has_pending_response_gap(messages) then
		return last
	end
	return nil
end

---@param opts table { status: table|string|nil, messages: table[]|nil, waiting_for_interaction?: boolean, fallback_message: table, delegated?: { working: boolean }|nil }
---@return table|nil presentation { message: table, source_message: table, animated: boolean, delegated?: boolean }
function M.derive(opts)
	opts = opts or {}
	local messages = opts.messages or {}
	if M.is_processing(opts.status) then
		if not M.has_pending_response_gap(messages) then return nil end
		local source_message = M.metadata_message(messages, opts.fallback_message)
		return {
			message = metadata_projection(source_message),
			source_message = source_message,
			animated = opts.waiting_for_interaction ~= true,
		}
	end
	-- The session's own turn ended, but subagents it launched in the background
	-- still work. Its last footer stays complete (duration, usage) and animates
	-- until they finish, so the chat never looks idle while work continues.
	local delegated = type(opts.delegated) == "table" and opts.delegated or nil
	if not delegated then return nil end
	local last = settled_last_assistant(messages)
	local source_message = last or M.metadata_message(messages, opts.fallback_message)
	return {
		message = last or metadata_projection(source_message),
		source_message = source_message,
		animated = opts.waiting_for_interaction ~= true and delegated.working == true,
		delegated = true,
	}
end

return M
