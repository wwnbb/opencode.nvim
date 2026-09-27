-- Scalar history metadata, retained without live message references.
local M = {}
local sync = require("opencode.sync")
local throughput = require("opencode.ui.chat.throughput")
local cache = require("opencode.util.memo").new("history_metadata", { max_entries = 1000 })

local function build_user_created_by_id(all_messages)
	local user_created_by_id = {}
	for _, msg in ipairs(all_messages) do
		if msg.id and msg.role == "user" and msg.time and type(msg.time.created) == "number" then
			user_created_by_id[msg.id] = msg.time.created
		end
	end
	return user_created_by_id
end

-- Native v2 user messages have no agent. For history that predates our local
-- binding, the following assistant (or an explicit switch) is the best hint.
local function infer_user_agents(all_messages)
	local agents = {}
	local from_response = {}
	local active_agent, latest_user_id
	for _, message in ipairs(all_messages) do
		if message.type == "agent-switched" and message.agent then
			active_agent = message.agent
		elseif message.role == "user" then
			latest_user_id = message.id
			if active_agent and message.id then agents[message.id] = active_agent end
		elseif message.role == "assistant" and message.agent then
			local user_id = message.parentID or latest_user_id
			if user_id and not from_response[user_id] then
				agents[user_id] = message.agent
				from_response[user_id] = true
			end
			active_agent = message.agent
		end
	end
	return agents
end

local function derive(messages, tps)
	return {
		created = build_user_created_by_id(messages),
		agents = infer_user_agents(messages),
		rates = tps and throughput.by_message(messages) or {},
	}
end

-- Only scalar lookups escape; callers cannot mutate retained containers.
local function lookups(value)
	return {
		created = function(id) return value.created[id] end,
		agent = function(id) return value.agents[id] end,
		rate = function(id) return value.rates[id] end,
	}
end

function M.get(session_id, messages, revert_message_id, tps)
	tps = tps ~= false
	local generation = sync.get_history_metadata_generation(session_id)
	local filter = revert_message_id and (#revert_message_id .. ":" .. revert_message_id) or "-"
	local signature = tostring(generation) .. "\0" .. filter .. "\0" .. tostring(tps)
	local value = session_id and generation and cache:get(session_id, signature)
	if not value then
		value = derive(messages, tps)
		if session_id and generation then cache:put(session_id, signature, value) end
	end
	return lookups(value)
end

function M.clear_session(session_id) cache:delete(session_id) end
function M.clear() cache:clear() end

return M
