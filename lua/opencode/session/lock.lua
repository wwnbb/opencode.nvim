-- Per-session child-agent execution locks.

local M = {}

local locks = {}

---@param session_id string|nil
---@return boolean
local function valid_session_id(session_id)
	return type(session_id) == "string" and session_id ~= ""
end

---@param session_id string
---@param record table
---@return table|nil
function M.set(session_id, record)
	if not valid_session_id(session_id) or type(record) ~= "table" then
		return nil
	end

	local value = vim.deepcopy(record)
	value.session_id = session_id
	locks[session_id] = value
	return vim.deepcopy(value)
end

---@param session_id string|nil
---@return table|nil
function M.get(session_id)
	if not valid_session_id(session_id) or not locks[session_id] then
		return nil
	end
	return vim.deepcopy(locks[session_id])
end

-- Lock local controls while following authoritative selections from the server.
function M.update_selection(session_id, selection)
	local value = valid_session_id(session_id) and locks[session_id]
	if not value or type(selection) ~= "table" then return end
	local agent = type(selection.agent) == "string" and selection.agent ~= "" and selection.agent or nil
	local model = selection.model and require("opencode.protocol.requests").model(selection.model)
	if model and (model.providerID == "" or model.id == "") then model = nil end
	if not agent and not model then return end
	value.child_session = value.child_session or { id = session_id }
	if agent then
		value.agent, value.child_session.agent = agent, agent
	end
	if model then
		value.model = { providerID = model.providerID, modelID = model.id }
		value.variant, value.pending = model.variant, nil
		value.child_session.model = vim.deepcopy(selection.model)
	end
	value.error = nil
end

---@param session_id string|nil
---@return boolean
function M.is_locked(session_id)
	return valid_session_id(session_id) and locks[session_id] ~= nil
end

---@param session_id string|nil
function M.clear(session_id)
	if valid_session_id(session_id) then
		locks[session_id] = nil
	end
end

function M.clear_all()
	locks = {}
end

---@param value any
---@return string|nil
local function nonempty_string(value)
	if type(value) ~= "string" then
		return nil
	end
	local result = vim.trim(value)
	return result ~= "" and result or nil
end

---@param value any
---@return table|nil
---@return string|nil
local function model_ref(value)
	if type(value) ~= "table" then
		return nil, nil
	end

	local provider_id = nonempty_string(value.providerID or value.providerId or value.provider_id)
	local model_id = nonempty_string(value.modelID or value.modelId or value.model_id or value.id)
	if not provider_id or not model_id then
		return nil, nil
	end
	return { providerID = provider_id, modelID = model_id }, nonempty_string(value.variant)
end

---@param tool_part table
---@param child_session table|nil
---@param messages table[]
---@return table|nil model
---@return string|nil variant
local function resolve_child_model(tool_part, child_session, messages)
	if type(child_session) == "table" then
		local model, variant = model_ref(child_session.model)
		if model then return model, variant end
	end
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = type(tool_state.input) == "table" and tool_state.input or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}
	local metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	local metadata_candidates = {
		state_metadata.model or {},
		metadata.model or {},
		state_metadata,
		metadata,
		input.model or {},
	}
	local fallback_variant = nonempty_string(state_metadata.variant)
		or nonempty_string(metadata.variant)
		or nonempty_string(input.variant)
	for _, role in ipairs({ "assistant", "user" }) do
		for index = #messages, 1, -1 do
			local message = messages[index]
			if type(message) == "table" and message.role == role then
				local message_model = type(message.model) == "table" and message.model or message
				fallback_variant = fallback_variant or nonempty_string(message_model.variant)
			end
		end
	end
	if type(child_session) == "table" then
		fallback_variant = fallback_variant or nonempty_string(child_session.variant)
	end

	for _, candidate in ipairs(metadata_candidates) do
		local model, variant = model_ref(candidate)
		if model then
			return model, variant or fallback_variant
		end
	end

	for _, role in ipairs({ "assistant", "user" }) do
		for index = #messages, 1, -1 do
			local message = messages[index]
			if type(message) == "table" and message.role == role then
				local model, variant = model_ref(message.model)
				if not model then
					model, variant = model_ref(message)
				end
				if model then
					return model, variant or fallback_variant
				end
			end
		end
	end

	if type(child_session) == "table" then
		local model, variant = model_ref(child_session)
		if model then
			return model, variant or fallback_variant
		end
	end

	return nil, nil
end

---@param tool_part table
---@param child_session table|nil
---@param messages table[]
---@return string|nil
local function resolve_child_agent(tool_part, child_session, messages)
	if type(child_session) == "table" then
		local agent = nonempty_string(child_session.agent)
		if agent then
			return agent
		end
	end

	for _, role in ipairs({ "assistant", "user" }) do
		for index = #messages, 1, -1 do
			local message = messages[index]
			if type(message) == "table" and message.role == role then
				local agent = nonempty_string(message.agent)
				if agent then
					return agent
				end
			end
		end
	end

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}
	local metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	return nonempty_string(state_metadata.agent)
		or nonempty_string(metadata.agent)
		or nonempty_string(tool_state.input and tool_state.input.subagent_type)
end

---Resolve the agent and model a child session runs with, from fresh session
---metadata, its messages and the launching tool part. `fetch` supplies the
---session/messages requests and the latest version of the tool part.
---@param child_session_id string
---@param tool_part table
---@param fetch { get_session: function, load_messages: function, tool_part: fun(part: table): table|nil }
---@param callback fun(err: string|nil, record: table|nil)
function M.resolve(child_session_id, tool_part, fetch, callback)
	local child_session = nil
	local pending = require("opencode.session.pending")
	local app_state = require("opencode.state")
	local snapshot = app_state.get_session_record(child_session_id)
	local token = pending.token(child_session_id)
	fetch.get_session(child_session_id, function(session_error, session)
		if not pending.is_current(token) then return end
		if session_error then callback(session_error); return end
		if type(session) ~= "table" or session.id ~= child_session_id then
			callback({ message = "Session metadata is unavailable or does not match the requested session" })
			return
		end
		child_session = vim.deepcopy(session)

		fetch.load_messages(child_session_id, { limit = 100 }, function(messages_error, response)
			if not pending.is_current(token) then return end
			if messages_error then callback(messages_error); return end
			local sync = require("opencode.sync")
			local latest = app_state.get_session_record(child_session_id)
			local model_updated = latest and type(latest.model) == "table" and
				(not vim.deep_equal((snapshot or {}).model, latest.model)
					or (snapshot or {})._model_selection_revision ~= latest._model_selection_revision)
			if latest and not vim.deep_equal(snapshot, latest) then
				child_session = child_session or { id = child_session_id }
				-- Apply newer fields atomically, including fields explicitly cleared since the request.
				for key, value in pairs(latest) do
					if not vim.deep_equal((snapshot or {})[key], value) then child_session[key] = vim.deepcopy(value) end
				end
				for key in pairs(snapshot or {}) do
					if latest[key] == nil then child_session[key] = nil end
				end
				if model_updated then child_session.model = vim.deepcopy(latest.model) end
			end
			if latest and latest.fork and child_session and child_session.parentID == latest.fork.sessionID then
				child_session.parentID = latest.parentID
			end
			local current_tool_part = fetch.tool_part(tool_part) or tool_part
			local messages = sync.get_messages(child_session_id)
			if #messages == 0 and type(response) == "table" then
				messages = {}
				for _, item in ipairs(response) do
					table.insert(messages, type(item.info) == "table" and item.info or item)
				end
			end

			local model, variant = resolve_child_model(current_tool_part, child_session, messages)
			if model_updated then
				model, variant = model_ref(latest.model)
			end
			local agent = resolve_child_agent(current_tool_part, child_session, messages)
			local errors = {}
			if not model then
				table.insert(errors, "Unable to determine the subagent execution model")
			end
			if not agent then
				table.insert(errors, "Unable to determine the subagent agent")
			end

			local record = {
				agent = agent,
				model = model,
				variant = variant,
				child_session = child_session or { id = child_session_id },
				task = vim.deepcopy(current_tool_part),
			}
			if #errors > 0 then
				record.error = table.concat(errors, "; ")
				record.pending = not model
			end
			callback(nil, record)
		end)
	end)
end

return M
