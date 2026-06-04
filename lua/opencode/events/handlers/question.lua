local M = {}

local util = require("opencode.events.util")
local pending_tool_question_sync = {}
local TOOL_SYNC_RETRY_DELAYS_MS = { 120, 300, 700 }

local function stop_spinner_for_current_question(current_session_id, question_session_id, logger)
	if not util.permission_session_is_relevant(current_session_id, question_session_id) then
		return
	end

	local spinner_ok, spinner = pcall(require, "opencode.ui.spinner")
	if spinner_ok and spinner.is_active and spinner.is_active() then
		spinner.stop()
		if logger then
			logger.debug("Stopped spinner for question interaction", {
				session_id = question_session_id,
				current_session_id = current_session_id,
			})
		end
	end
end

---@param data table|nil
---@return string|nil
local function get_request_id(data)
	if type(data) ~= "table" then
		return nil
	end
	return data.requestID or data.request_id or data.id
end

---@param data table|nil
---@return string|nil
local function get_request_session_id(data)
	if type(data) ~= "table" then
		return nil
	end
	return data.sessionID or data.session_id or data.sessionId
end

---@param data table|nil
---@return boolean
local function is_waiting_question_tool(data)
	if type(data) ~= "table" or data.tool_name ~= "question" then
		return false
	end

	local status = data.status
	return status == "pending" or status == "running" or status == "started"
end

---@param questions table|nil
---@return string|nil
local function questions_fingerprint(questions)
	if type(questions) ~= "table" then
		return nil
	end

	local normalized = {}
	for _, question in ipairs(questions) do
		if type(question) ~= "table" then
			return nil
		end
		local item = {
			header = question.header or question.title or "",
			question = question.question or question.prompt or "",
			multiple = question.multiple == true or question.type == "multi",
			options = {},
		}
		for _, option in ipairs(question.options or {}) do
			if type(option) == "table" then
				table.insert(item.options, {
					label = option.label or "",
					description = option.description or "",
					value = option.value or "",
				})
			else
				table.insert(item.options, { label = tostring(option), description = "", value = "" })
			end
		end
		table.insert(normalized, item)
	end

	local ok, encoded = pcall(vim.json.encode, normalized)
	if not ok then
		return nil
	end
	return encoded
end

---@param input table|nil
---@return table|nil
local function get_input_questions(input)
	if type(input) ~= "table" or type(input.questions) ~= "table" then
		return nil
	end
	return input.questions
end

---@param response any
---@return table[]
local function normalize_question_list(response)
	if type(response) ~= "table" then
		return {}
	end
	if response[1] ~= nil then
		return response
	end
	if type(response.questions) == "table" then
		return response.questions
	end
	if type(response.data) == "table" then
		return response.data
	end
	return {}
end

---@param question_state table
---@param message_id string|nil
---@param call_id string|nil
---@return boolean
local function has_question_for_tool(question_state, message_id, call_id)
	if type(call_id) ~= "string" or call_id == "" then
		return false
	end

	for _, qstate in ipairs(question_state.get_all()) do
		if qstate.call_id == call_id and (not message_id or not qstate.message_id or qstate.message_id == message_id) then
			return true
		end
	end
	return false
end

---@param request table
---@param tool_data table
---@return boolean
local function request_matches_tool(request, tool_data)
	local request_message_id = util.resolve_event_message_id(request)
	local request_call_id = util.resolve_event_call_id(request)
	local tool_message_id = tool_data.message_id
	local tool_call_id = tool_data.call_id

	if type(tool_call_id) == "string" and tool_call_id ~= "" and request_call_id == tool_call_id then
		return not tool_message_id or not request_message_id or request_message_id == tool_message_id
	end

	if type(tool_message_id) == "string" and tool_message_id ~= "" and request_message_id == tool_message_id then
		return true
	end

	local request_session_id = get_request_session_id(request)
	if request_session_id and request_session_id == tool_data.session_id then
		local request_fp = questions_fingerprint(request.questions)
		local input_fp = questions_fingerprint(get_input_questions(tool_data.input))
		return request_fp ~= nil and request_fp == input_fp
	end

	return false
end

---@param events table
---@param state table
---@param question_state table
---@param request table
---@param fallback table
---@param logger table
---@return boolean matched
local function add_or_update_question_request(events, state, question_state, request, fallback, logger)
	local request_id = get_request_id(request)
	local questions = type(request) == "table" and request.questions or nil
	if not request_id or type(questions) ~= "table" then
		return false
	end

	local current_session = state.get_session()
	local session_id = get_request_session_id(request) or fallback.session_id
	local message_id = util.resolve_event_message_id(request) or fallback.message_id
	local call_id = util.resolve_event_call_id(request) or fallback.call_id
	local timestamp = util.event_time_to_seconds(request.time and request.time.created) or fallback.timestamp

	if message_id then
		local ok_sync, sync = pcall(require, "opencode.sync")
		if ok_sync and sync.find_message_session_id then
			session_id = sync.find_message_session_id(message_id) or session_id
		end
	end
	session_id = session_id or (current_session and current_session.id) or ""

	if question_state.has_question(request_id) then
		if question_state.set_context(request_id, {
			session_id = session_id,
			message_id = message_id,
			call_id = call_id,
			timestamp = timestamp,
		}) then
			events.emit("interaction_changed", {
				kind = "question",
				action = "context_updated",
				id = request_id,
				session_id = session_id,
			})
		end
		return true
	end

	question_state.add_question(request_id, session_id, questions, {
		message_id = message_id,
		call_id = call_id,
		timestamp = timestamp,
	})
	events.emit("question_pending", {
		request_id = request_id,
		questions_count = #questions,
		session_id = session_id,
		message_id = message_id,
		call_id = call_id,
	})
	events.emit("interaction_changed", {
		kind = "question",
		action = "pending",
		id = request_id,
		session_id = session_id,
	})

	stop_spinner_for_current_question(current_session and current_session.id, session_id, logger)

	if logger then
		logger.info("Question added", { request_id = request_id:sub(1, 10), count = #questions })
	end
	return true
end

---@param data table
---@return string
local function tool_sync_key(data)
	return table.concat({
		data.session_id or "",
		data.message_id or "",
		data.call_id or "",
	}, "\0")
end

---@param events table
---@param state table
---@param question_state table
---@param data table
---@param attempt number|nil
local function sync_question_from_tool(events, state, question_state, data, attempt)
	attempt = attempt or 1
	if not is_waiting_question_tool(data) then
		return
	end
	if has_question_for_tool(question_state, data.message_id, data.call_id) then
		return
	end

	local key = tool_sync_key(data)
	if pending_tool_question_sync[key] then
		return
	end
	pending_tool_question_sync[key] = true

	local ok_client, client = pcall(require, "opencode.client")
	if not ok_client or type(client.list_questions) ~= "function" then
		pending_tool_question_sync[key] = nil
		return
	end

	client.list_questions(function(err, response)
		pending_tool_question_sync[key] = nil
		local logger = require("opencode.logger")
		if err then
			logger.debug("Pending question sync failed", {
				message_id = data.message_id,
				call_id = data.call_id,
				error = err.message or err.error or tostring(err),
			})
			return
		end

		for _, request in ipairs(normalize_question_list(response)) do
			if request_matches_tool(request, data) then
				add_or_update_question_request(events, state, question_state, request, {
					session_id = data.session_id,
					message_id = data.message_id,
					call_id = data.call_id,
					timestamp = os.time(),
				}, logger)
				return
			end
		end

		local delay = TOOL_SYNC_RETRY_DELAYS_MS[attempt]
		if delay and not has_question_for_tool(question_state, data.message_id, data.call_id) then
			vim.defer_fn(function()
				sync_question_from_tool(events, state, question_state, data, attempt + 1)
			end, delay)
		end
	end)
end

function M.setup(events)
	local state = require("opencode.state")
	local question_state = require("opencode.question.state")

	-- Handle question.asked - store question and trigger UI update
	events.on("question_asked", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			logger.debug("Question asked event received", { data = data })

			if not get_request_id(data) or not data.questions then
				logger.warn(
					"Invalid question data",
					{ data = data, request_id = get_request_id(data), has_questions = data.questions ~= nil }
				)
				return
			end

			add_or_update_question_request(events, state, question_state, data, {}, logger)
		end)
	end)

	-- If the question.asked SSE event is missed, recover the real requestID from
	-- the pending /question list when the running question tool part appears.
	events.on("tool_update", function(data)
		vim.schedule(function()
			sync_question_from_tool(events, state, question_state, data)
		end)
	end)

	-- Handle question.replied - mark as answered
	events.on("question_replied", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			local request_id = get_request_id(data)

			if not request_id then
				return
			end

			-- Mark as answered
			question_state.mark_answered(request_id, data.answers)
			events.emit("question_answered", {
				request_id = request_id,
				answers = data.answers,
			})
			events.emit("interaction_changed", {
				kind = "question",
				action = "answered",
				id = request_id,
			})

			logger.debug("Question answered", { request_id = request_id:sub(1, 10) })
		end)
	end)

	-- Handle question.rejected - mark as rejected
	events.on("question_rejected", function(data)
		vim.schedule(function()
			if not data then
				return
			end

			local logger = require("opencode.logger")
			local request_id = get_request_id(data)

			if not request_id then
				return
			end

			-- Mark as rejected
			question_state.mark_rejected(request_id)
			events.emit("interaction_changed", {
				kind = "question",
				action = "rejected",
				id = request_id,
			})

			logger.debug("Question rejected", { request_id = request_id:sub(1, 10) })
		end)
	end)

	-- Clear questions on session change unless the session boundary marks this
	-- as a cache-preserving navigation.
	events.on("session_change", function(data)
		if data and data.preserve_cache then
			return
		end
		local removed = question_state.clear_all()
		for _, request_id in ipairs(removed or {}) do
			events.emit("question_removed", { request_id = request_id })
		end
	end)
end

return M
