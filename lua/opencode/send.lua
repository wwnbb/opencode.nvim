-- Send-flow orchestration for OpenCode prompts.

local M = {}

local state = require("opencode.state")
local selectors = require("opencode.selectors")
local session_actions = require("opencode.session")
local logger = require("opencode.logger")

local ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local id_last_timestamp = 0
local id_counter = 0

---@return number
local function current_time_ms()
	if vim.uv and type(vim.uv.gettimeofday) == "function" then
		local ok, seconds, microseconds = pcall(vim.uv.gettimeofday)
		if ok and type(seconds) == "number" then
			return (seconds * 1000) + math.floor((microseconds or 0) / 1000)
		end
	end
	return os.time() * 1000
end

---@param len number
---@return string
local function random_base62(len)
	local out = {}
	for i = 1, len do
		local idx = math.random(#ID_CHARS)
		out[i] = ID_CHARS:sub(idx, idx)
	end
	return table.concat(out)
end

---@param prefix string
---@return string
local function ascending_id(prefix)
	local timestamp = current_time_ms()
	if timestamp ~= id_last_timestamp then
		id_last_timestamp = timestamp
		id_counter = 0
	end
	id_counter = (id_counter % 0xfff) + 1

	local value = (timestamp * 0x1000) + id_counter
	local hex = {}
	for shift = 40, 0, -8 do
		local byte = math.floor(value / (2 ^ shift)) % 256
		table.insert(hex, string.format("%02x", byte))
	end
	return prefix .. "_" .. table.concat(hex) .. random_base62(14)
end

---@return table
local function client()
	return require("opencode.client")
end

---@return table
local function sync()
	return require("opencode.sync")
end

---@return table
local function chat()
	return require("opencode.ui.chat")
end

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

---@param ref any
---@return table
local function summarize_model_ref(ref)
	if type(ref) ~= "table" then
		return {
			kind = ref == vim.NIL and "vim.NIL" or type(ref),
		}
	end
	return {
		kind = "table",
		providerID = ref.providerID,
		modelID = ref.modelID,
		variant = ref.variant,
	}
end

---@param err any
---@return string
local function error_text(err)
	if type(err) == "table" then
		return tostring(err.message or err.error or err)
	end
	return tostring(err)
end

---@param messages table[]|nil
---@return number
local function count_assistant_messages(messages)
	local count = 0
	for _, msg in ipairs(messages or {}) do
		if msg.role == "assistant" then
			count = count + 1
		end
	end
	return count
end

---@param part table
---@param payload table
local function append_payload_part(part, payload)
	if type(part) ~= "table" then
		return
	end
	local prompt_part = vim.deepcopy(part)
	prompt_part._marker = nil
	if not prompt_part.id then
		prompt_part.id = ascending_id("prt")
	end
	table.insert(payload.parts, prompt_part)
end

---@param message string
---@param opts? table
---@return table payload
---@return table selection
local function build_payload(message, opts)
	opts = opts or {}

	local selection = selectors.send_selection(opts)
	local prompt_message_id = ascending_id("msg")
	local prompt_part_id = ascending_id("prt")
	local payload = {
		messageID = prompt_message_id,
		parts = {
			{ id = prompt_part_id, type = "text", text = message },
		},
		agent = selection.agent,
		model = selection.model,
		variant = selection.variant,
	}

	if type(opts.context) == "table" then
		for _, ctx in ipairs(opts.context) do
			append_payload_part(ctx, payload)
		end
	end

	if type(opts.parts) == "table" then
		for _, part in ipairs(opts.parts) do
			append_payload_part(part, payload)
		end
	end

	return payload, selection
end

---@param session_id string
---@param payload table
local function seed_local_message(session_id, payload)
	local store = sync()
	local info = {
		id = payload.messageID,
		sessionID = session_id,
		role = "user",
		time = {
			created = current_time_ms(),
		},
		agent = payload.agent,
	}

	if payload.model then
		info.model = {
			providerID = payload.model.providerID,
			modelID = payload.model.modelID,
			variant = payload.variant,
		}
		info.providerID = payload.model.providerID
		info.modelID = payload.model.modelID
	end

	store.handle_message_updated(info)
	for _, part in ipairs(payload.parts) do
		local seeded_part = vim.deepcopy(part)
		seeded_part.messageID = payload.messageID
		seeded_part.sessionID = session_id
		store.handle_part_updated(seeded_part)
	end

	emit("sync_changed", {
		kind = "message",
		action = "seeded",
		session_id = session_id,
		message_id = payload.messageID,
	})
end

---@param session_id string
---@param reason string
---@param callback? function
local function sync_session_messages(session_id, reason, callback)
	client().get_messages(session_id, { limit = 100 }, function(fetch_err, messages)
		if fetch_err then
			logger.debug("Session message sync failed", {
				session_id = session_id,
				reason = reason,
				error = error_text(fetch_err),
			})
			if callback then
				callback()
			end
			return
		end

		local message_count, part_count, changed_count = sync().handle_session_messages(session_id, messages)
		session_actions.set_message_cache(session_id, messages, {
			reason = reason,
		})
		session_actions.reconcile_busy_session_idle(session_id, { reason = reason })

		logger.debug("Session messages synced", {
			session_id = session_id,
			reason = reason,
			message_count = message_count,
			part_count = part_count,
			changed_count = changed_count,
		})

		if changed_count > 0 then
			emit("sync_changed", {
				kind = "session_messages",
				action = reason,
				session_id = session_id,
			})
		end
		if callback then
			callback()
		end
	end)
end

---@param session_id string
---@param response table|nil
local function handle_prompt_response(session_id, response)
	if type(response) ~= "table" then
		return
	end

	sync().handle_session_messages(session_id, { response })
	session_actions.reconcile_busy_session_idle(session_id, { reason = "prompt_response" })
	emit("sync_changed", {
		kind = "message",
		action = "prompt_response",
		session_id = session_id,
	})
end

---@param session_id string
---@param err any
local function handle_send_error(session_id, err)
	vim.schedule(function()
		session_actions.set_status("idle", {
			reason = "send_failed",
			session_id = session_id,
		})
		vim.notify("Failed to send message: " .. error_text(err), vim.log.levels.ERROR)
		chat().add_message("system", "Error: Failed to send message", {
			session_id = session_id,
		})
	end)
end

---@param session_id string
---@param payload table
---@param selection table
local function send_async_prompt(session_id, payload, selection)
	logger.debug("Sending async prompt request", {
		route = "/session/:id/prompt_async",
		session_id = session_id,
		message_id = payload.messageID,
	})

	client().send_message_async(session_id, payload, function(err)
		if err then
			logger.debug("Async prompt request rejected", {
				session_id = session_id,
				error = error_text(err),
			})
			handle_send_error(session_id, err)
			return
		end

		logger.debug("Async prompt accepted", {
			session_id = session_id,
			agent = selection.agent,
			model = summarize_model_ref(selection.model),
			variant = selection.variant,
		})
	end)
end

---@param session_id string
---@param payload table
---@param selection table
local function send_prompt(session_id, payload, selection)
	logger.debug("Sending prompt request", {
		route = "/session/:id/message",
		session_id = session_id,
		message_id = payload.messageID,
	})

	client().send_message(session_id, payload, { timeout = 0 }, function(err, response)
		if err then
			logger.debug("Prompt request rejected", {
				session_id = session_id,
				error = error_text(err),
			})
			handle_send_error(session_id, err)
			return
		end

		logger.debug("Prompt request completed", {
			session_id = session_id,
			agent = selection.agent,
			model = summarize_model_ref(selection.model),
			variant = selection.variant,
			has_response = type(response) == "table",
			part_count = type(response) == "table" and type(response.parts) == "table" and #response.parts or nil,
		})

		vim.schedule(function()
			handle_prompt_response(session_id, response)
			sync_session_messages(session_id, "prompt_completed")
			session_actions.set_status("idle", {
				reason = "send_completed",
				session_id = session_id,
			})
		end)
	end)
end

---@param session_id string
---@return number before_message_count
---@return number before_assistant_count
local function message_counts_before_send(session_id)
	local messages = sync().get_messages(session_id)
	return #messages, count_assistant_messages(messages)
end

---@param session_id string
---@param before_message_count number
---@param before_assistant_count number
local function schedule_session_sync_watchdogs(session_id, before_message_count, before_assistant_count)
	vim.defer_fn(function()
		local session_status = state.get_session_status(session_id)
		if session_status.type == "busy" or session_status.type == "retry" then
			sync_session_messages(session_id, "prompt_started")
		end
	end, 500)

	vim.defer_fn(function()
		local session_status = state.get_session_status(session_id)
		if session_status.type ~= "busy" and session_status.type ~= "retry" then
			return
		end

		sync_session_messages(session_id, "prompt_watchdog", function()
			local messages = sync().get_messages(session_id)
			local assistant_count = count_assistant_messages(messages)
			if assistant_count <= before_assistant_count then
				logger.warn("No assistant message observed after prompt request", {
					session_id = session_id,
					wait_ms = 3000,
					status = session_status.type,
					before_message_count = before_message_count,
					after_message_count = #messages,
					before_assistant_count = before_assistant_count,
					after_assistant_count = assistant_count,
				})
			end
		end)
	end, 3000)
end

---@param session_id string
---@param message string
---@param opts? table
local function send_existing_session(session_id, message, opts)
	local payload, selection = build_payload(message, opts)
	logger.debug("Resolved prompt payload", {
		session_id = session_id,
		agent = selection.agent,
		model = summarize_model_ref(selection.model),
		variant = selection.variant,
		message_id = payload.messageID,
		text_length = type(message) == "string" and #message or nil,
		part_count = #payload.parts,
	})

	local before_message_count, before_assistant_count = message_counts_before_send(session_id)
	seed_local_message(session_id, payload)
	session_actions.set_status("streaming", {
		reason = "send_started",
		session_id = session_id,
	})

	local cfg = state.get_config() or {}
	local parallel = cfg.session and cfg.session.parallel or {}
	local use_prompt_async = parallel.enabled ~= false and parallel.use_prompt_async ~= false

	if use_prompt_async then
		send_async_prompt(session_id, payload, selection)
	else
		send_prompt(session_id, payload, selection)
	end

	schedule_session_sync_watchdogs(session_id, before_message_count, before_assistant_count)
end

---@param err any
local function handle_create_session_error(err)
	vim.schedule(function()
		local message = err and error_text(err) or "unknown"
		vim.notify("Failed to create session: " .. tostring(message), vim.log.levels.ERROR)
		chat().add_message("system", "Error: Failed to create session")
	end)
end

---@param message string
---@param opts table
local function create_session_and_send(message, opts)
	local session_opts = vim.empty_dict()
	if type(opts.title) == "string" and opts.title ~= "" then
		session_opts.title = opts.title
	end

	client().create_session(session_opts, function(err, session)
		if err or not session then
			handle_create_session_error(err)
			return
		end

		vim.schedule(function()
			session_actions.remember(session)
			session_actions.set_active(session.id, session.title or "New session", {
				reason = "send_create_session",
				preserve_cache = true,
			})
			send_existing_session(session.id, message, opts)
		end)
	end)
end

---@param message string
---@param opts? table
function M.send(message, opts)
	opts = opts or {}
	local session_id = state.get_session().id
	if session_id then
		send_existing_session(session_id, message, opts)
	else
		create_session_and_send(message, opts)
	end
end

return M
