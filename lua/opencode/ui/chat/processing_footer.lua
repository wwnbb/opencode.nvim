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

local function last_assistant(messages)
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" then
			return messages[i]
		end
	end
	return nil
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
	local assistant = last_assistant(messages)
	if not last_message or last_message.role ~= "assistant" or not assistant then
		return true
	end
	local completed = assistant.time and assistant.time.completed ~= nil
	return not completed or assistant.finish == "tool-calls"
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

---@param opts table { status: table|string|nil, messages: table[]|nil, waiting_for_interaction?: boolean, fallback_message: table }
---@return table|nil presentation { message: table, animated: boolean }
function M.derive(opts)
	opts = opts or {}
	local messages = opts.messages or {}
	if not M.is_processing(opts.status) or not M.has_pending_response_gap(messages) then
		return nil
	end
	local source_message = M.metadata_message(messages, opts.fallback_message)
	return {
		message = metadata_projection(source_message),
		source_message = source_message,
		animated = opts.waiting_for_interaction ~= true,
	}
end

return M
