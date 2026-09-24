-- Pure turn-level throughput derived from native OpenCode timing and usage.
local M = {}

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function kind(message)
	return message.type or message.role
end

---Average output + reasoning tokens per second, through each assistant message.
---OpenCode v2 measures each model request from time.created to time.streamed;
---time.completed can include tool execution and must not be used here.
---@param messages table[] Chronological session history, including hidden idle messages
---@return table<string, number>
function M.by_message(messages)
	local partial_history_turns = true
	for _, message in ipairs(messages) do
		if kind(message) == "idle" then
			partial_history_turns = false
			break
		end
	end

	local rates = {}
	local tokens, duration = 0, 0
	local valid, has_prompt = true, false
	for _, message in ipairs(messages) do
		local message_kind = kind(message)
		if message_kind == "idle" then
			tokens, duration, valid, has_prompt = 0, 0, true, false
		elseif message_kind == "user" or message_kind == "synthetic" then
			-- Native turns can contain steering prompts. When a loaded page has no
			-- idle boundary, use the most recent prompt as the visible turn start.
			if partial_history_turns or not has_prompt then
				tokens, duration, valid = 0, 0, true
			end
			has_prompt = true
		elseif message_kind == "assistant" then
			local time = type(message.time) == "table" and message.time or {}
			local usage = type(message.tokens) == "table" and message.tokens or {}
			local output, reasoning = usage.output or 0, usage.reasoning or 0
			if not finite(time.created) or not finite(time.streamed)
				or not finite(output) or not finite(reasoning) or output < 0 or reasoning < 0 then
				valid = false
			else
				tokens = tokens + output + reasoning
				duration = duration + math.max(0, time.streamed - time.created)
			end
			if valid and message.id and tokens > 0 and duration > 0 then
				local rate = tokens / (duration / 1000)
				if finite(rate) then rates[message.id] = rate end
			end
		end
	end
	return rates
end

return M
