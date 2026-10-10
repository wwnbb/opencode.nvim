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

-- Native rows.ts closes modern turns on idle, including any steering prompts.
-- Histories without idle markers close on a terminal assistant step. Missing
-- usage or an unloaded prompt yields a known partial total, never an estimate.
local function turn_usage(messages)
	local legacy = true
	for _, message in ipairs(messages) do if message.type == "idle" then legacy = false; break end end
	local turns, totals, last_id, has_prompt
	turns = {}
	local function reset()
		totals = { input = 0, output = 0, reasoning = 0, cached = 0, cache_write = 0, new = 0, total = 0, steps = 0, complete = true }
		last_id, has_prompt = nil, false
	end
	local function flush()
		if last_id and totals.steps > 0 and totals.total < math.huge then
			totals.complete = totals.complete and has_prompt
			turns[last_id] = totals
		end
		reset()
	end
	reset()
	for _, message in ipairs(messages) do
		local kind = message.type or message.role
		if kind == "idle" then flush()
		elseif kind == "user" or kind == "synthetic" then
			if not message.provisional then has_prompt = true end
		elseif kind == "assistant" then
			last_id = message.id
			local step = require("opencode.selectors").token_usage(message.tokens)
			if not step then totals.complete = false
			elseif step.total > 0 then
				for key, value in pairs(step) do totals[key] = totals[key] + value end
				totals.steps = totals.steps + 1
			end
			local terminal = message.error or (message.finish and message.finish ~= "tool-calls" and message.finish ~= "unknown")
			if legacy and terminal then flush() end
		end
	end
	return turns
end

local function derive(messages, tps)
	return {
		created = build_user_created_by_id(messages),
		agents = infer_user_agents(messages),
		rates = tps and throughput.by_message(messages) or {},
		turns = turn_usage(messages),
	}
end

-- Only scalar lookups escape; callers cannot mutate retained containers.
local function lookups(value)
	return {
		created = function(id) return value.created[id] end,
		agent = function(id) return value.agents[id] end,
		rate = function(id) return value.rates[id] end,
		turn = function(id) return value.turns[id] and vim.deepcopy(value.turns[id]) or nil end,
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
