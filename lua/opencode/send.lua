-- Send-flow orchestration for OpenCode prompts.

local M = {}

local state = require("opencode.state")
local selectors = require("opencode.selectors")
local session_actions = require("opencode.session")

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

local pending = require("opencode.session.pending")
local requests = require("opencode.protocol.v2.requests")
local projection = require("opencode.protocol.v2.messages")

local function client() return require("opencode.client") end
local function sync() return require("opencode.sync") end
local function emit(name, data) require("opencode.events").emit(name, data) end

local function fetch_catalogs(directory, token, callback)
	local remaining, first_error = 2, nil
	local function received(domain, err, data)
		if not pending.is_current(token) then return end
		first_error = first_error or err
		sync().handle_location_catalog(directory, domain, data, err)
		remaining = remaining - 1
		if remaining == 0 then callback(first_error) end
	end
	client().get_config_providers(function(err, data) received("providers", err, data) end, { directory = directory })
	client().list_agents(function(err, data) received("agents", err, data) end, { directory = directory })
end

local function restore_draft(text, opts)
	local history = require("opencode.ui.input.history")
	local session_id = opts._draft_session_id or opts.session_id
	if session_id == false then session_id = "" end
	if history.get_pending(session_id) == "" and #history.get_pending_parts(session_id) == 0 then
		history.set_pending(text, opts.parts, session_id)
		history.set_pending_mode(opts.mode or "normal", session_id)
		local options = vim.deepcopy(opts)
		options.parts, options._draft_session_id = nil, nil
		options._token, options._catalog_ready, options._catalog_retry, options._catalog_deadline = nil, nil, nil, nil
		history.set_pending_options(options, session_id)
	end
end

local function fail_before_send(message, text, opts)
	restore_draft(text, opts)
	vim.notify("Cannot send message: " .. message, vim.log.levels.ERROR)
	return false
end

local function catalogs_empty(providers, agents)
	if not providers or not providers.data or not agents or not agents.data or #agents.data == 0 then return true end
	for _, provider in ipairs(providers.data.providers or {}) do
		if next(provider.models or {}) ~= nil then return false end
	end
	return true
end

local function resolve_selection(opts)
	local selection = vim.deepcopy(opts._selection or selectors.send_selection(opts))
	if selection.blocked then return nil, selection.error end
	local providers = sync().get_location_catalog(opts.directory, "providers")
	local agents = sync().get_location_catalog(opts.directory, "agents")
	local function get_model(provider_id, model_id)
		if not providers or not providers.data then return sync().get_model(provider_id, model_id) end
		for _, provider in ipairs(providers.data.providers) do
			if provider.id == provider_id then return provider.models[model_id] end
		end
	end
	local function get_agent(id)
		if not agents or not agents.data then return sync().get_agent(id) end
		for _, agent in ipairs(agents.data) do if agent.id == id or agent.name == id then return agent end end
	end
	if opts.model and not get_model(opts.model.providerID, opts.model.id or opts.model.modelID) then
		return nil, "The selected model is unavailable in this location"
	end
	if opts.model then selection.model = opts.model end
	if not selection.model and providers and providers.data and type(providers.data.server_default) == "table" then
		selection.model = providers.data.server_default
	end
	if not selection.model then return nil, "No model is available; select or connect a provider" end
	local agent = selection.agent and get_agent(selection.agent)
	if not agent and not opts.agent and agents and agents.data then
		local configured = ((state.get_config() or {}).session or {}).default_agent
		agent = configured and get_agent(configured)
	end
	if not agent then return nil, "The selected agent is unavailable in this location" end
	selection.agent = agent.id or agent.name
	local model, err = requests.model(selection.model, selection.variant)
	if err then return nil, err end
	local info = get_model(model.providerID, model.id)
	if not info then return nil, "The selected model is unavailable in this location" end
	if model.variant and (not info.variants or not info.variants[model.variant]) then
		return nil, "The selected model variant is unavailable"
	end
	selection.model = model
	return selection
end

local function seed(session_id, payload)
	local native = vim.deepcopy(payload)
	native.type, native.time = "user", { created = current_time_ms() }
	native.delivery, native.resume = nil, nil
	local projected = projection.project(session_id, native)
	projected.info.provisional = true
	sync().handle_session_messages(session_id, { projected })
	emit("sync_changed", { kind = "message", action = "seeded", session_id = session_id, message_id = payload.id })
end

local function submit(session_id, payload, selection, text, opts, known_session)
	local token = pending.token(session_id)
	local previous_status = state.get_session_status(session_id)
	local started = false
	local function begin()
		if started then return end
		started = true
		require("opencode.local").message_agent.set(session_id, payload.id, selection.agent)
		pending.begin({ session_id = session_id, message_id = payload.id, status = "submitting",
			text = text, options = opts, payload = payload, selection = selection, token = token })
		seed(session_id, payload)
		session_actions.set_status("streaming", { session_id = session_id, reason = "send_started" })
	end
	local function prepared_send(done, selection_ready)
		local submitted = false
		local function fail(err)
			if not pending.is_current(token) then done(); return end
			local definite = not submitted or (err.status and err.status >= 400 and err.status < 500)
			local record = pending.update(session_id, payload.id, { status = definite and "failed" or "uncertain", error = err })
			if record and record.status == "failed" then
				require("opencode.local").message_agent.remove(session_id, payload.id)
				restore_draft(text, opts)
				if previous_status.type == "idle" then session_actions.set_session_status(session_id, previous_status, { reason = "send_failed" }) end
			end
			local message = type(err) == "table" and (err.message or err.error) or tostring(err)
			vim.notify("OpenCode prompt " .. (record and record.status or "failed") .. ": " .. tostring(message), vim.log.levels.ERROR)
			emit("local_notice", { role = "system", session_id = session_id, content = "Prompt " .. (record and record.status or "failed") .. ": " .. tostring(message) })
			emit("v2_reconcile", { session_id = session_id })
			done()
		end
		local function prompt()
			if not pending.is_current(token) then done(); return end
			submitted = true
			client().send_message(session_id, payload, function(err, item)
				if not pending.is_current(token) then done(); return end
				if err then fail(err); return end
				-- SSE or a delivery-mode change may already provide newer inbox
				-- evidence than this initial admission response.
				local record = pending.get(session_id, payload.id)
				if not record or not record.inbox then pending.admit(item) end
				-- A delayed HTTP callback must not replace the delivered timestamp or
				-- regress state already confirmed by the event stream.
				emit("sync_changed", { kind = "inbox", action = "accepted", session_id = session_id, message_id = payload.id })
				emit("v2_reconcile", { session_id = session_id })
				done()
			end)
		end
		if selection_ready then prompt()
		else
			require("opencode.session.selection").prepare(session_id, selection, token, function(err)
				if err then fail(err) else prompt() end
			end, known_session)
		end
	end
	-- The server commits a staged revert before it admits the new prompt. Do
	-- the same locally before creating the optimistic row. A late SSE echo
	-- sees no old boundary in sync and cannot cancel the new admission.
	local staged = (state.get_session_record(session_id) or {}).revert
	if type(staged) ~= "table" then begin() end
	pending.serialize(session_id, function(done)
		if not pending.is_current(token) then done(); return end
		local revert = (state.get_session_record(session_id) or {}).revert
		if type(revert) ~= "table" then
			begin()
			prepared_send(done)
			return
		end
		require("opencode.session.selection").prepare(session_id, selection, token, function(prepare_err)
			if not pending.is_current(token) then done(); return end
			if prepare_err then
				fail_before_send(prepare_err.message or tostring(prepare_err), text, opts)
				done()
				return
			end
			local function commit_staged()
				local staged_now = (state.get_session_record(session_id) or {}).revert
				if type(staged_now) ~= "table" then
					begin()
					prepared_send(done, true)
					return
				end
				local boundary = staged_now.messageID
				pending.expect_revert_commit(session_id)
				client().commit_revert(session_id, function(err)
					if not pending.is_current(token) then done(); return end
					if err then
						fail_before_send(err.message or tostring(err), text, opts)
						done()
						return
					end
					if type(boundary) == "string" and not pending.revert_event_seen(session_id, boundary) then
						-- HTTP success is enough to settle local history even if the SSE
						-- committed event reaches us after a fresh prompt is admitted.
						local effect = sync().handle_v2_event({ id = ascending_id("evt"), created = current_time_ms(),
							type = "session.revert.committed", data = { sessionID = session_id, to = boundary } })
						for _, id in ipairs(effect.revert_removed or {}) do
							if pending.get(session_id, id) then pending.update(session_id, id, { status = "cancelled" }) end
						end
						emit("sync_changed", { kind = "message", action = "revert_committed", session_id = session_id })
					end
					local current = (state.get_session_record(session_id) or {}).revert
					if type(current) == "table" and current.messageID == boundary then
						session_actions.remember({ id = session_id, revert = vim.NIL }, { touch = false })
					end
					-- A second undo may have staged a new boundary while this HTTP
					-- request was in flight. Settle it before creating the prompt row.
					commit_staged()
				end)
			end
			commit_staged()
		end)
	end)
	return true
end

-- Both former sync/async modes return admission. Execution ends only through
-- terminal events/reconciliation; a successful POST never sets the session idle.
function M.send(text, opts)
	opts = vim.deepcopy(opts or {})
	local session_id = opts.session_id
	if session_id == nil then session_id = state.get_session().id end
	if session_id == false then session_id = nil end
	opts._draft_session_id = opts._draft_session_id or session_id or ""
	local token = opts._token or pending.token(session_id)
	if not pending.is_current(token) then return false end
	local directory = opts.directory or (session_id and state.get_session_directory(session_id)) or vim.fn.getcwd()
	opts.directory = state.normalize_directory(directory)
	directory = opts.directory
	if opts.mode == "shell" then
		if type(text) ~= "string" or vim.trim(text) == "" then return fail_before_send("Shell command is empty", text, opts) end
		if #(opts.parts or {}) > 0 then return fail_before_send("Shell commands do not support attachments", text, opts) end
		if opts.delivery then return fail_before_send("Shell commands cannot be queued or steered", text, opts) end
		local function run(id)
			if not pending.is_current(token) then return end
			client().run_session_shell(id, text, function(err)
				if not pending.is_current(token) then return end
				if err then
					-- Never repeat shell execution after an uncertain transport failure.
					if err.status and err.status >= 400 and err.status < 500 then restore_draft(text, opts) end
					vim.notify("Shell command: " .. (err.message or "Execution could not be confirmed"), vim.log.levels.ERROR)
				end
				emit("v2_reconcile", { session_id = id })
			end)
		end
		if session_id then run(session_id)
		else
			client().create_session({ location = { directory = directory } }, function(err, info)
				if not pending.is_current(token) then return end
				if err then fail_before_send(err.message or "Session creation failed", text, opts); return end
				session_actions.remember(info)
				if not state.get_session().id then session_actions.set_active(info.id, info.title, { preserve_cache = true }) end
				run(info.id)
			end)
		end
		return true
	end
	local provider_cache = sync().get_location_catalog(directory, "providers")
	local agent_cache = sync().get_location_catalog(directory, "agents")
	if not opts._catalog_ready and sync().get_catalog_location() ~= nil and (opts._catalog_retry or catalogs_empty(provider_cache, agent_cache)) then
		opts._selection = opts._selection or selectors.send_selection(opts)
		opts.session_id, opts._token, opts._catalog_ready = session_id or false, token, true
		opts._catalog_deadline = opts._catalog_deadline or (current_time_ms() + 5000)
		fetch_catalogs(directory, token, function(first_error)
			if first_error then fail_before_send(first_error.message or "Catalog unavailable", text, opts)
			elseif current_time_ms() < opts._catalog_deadline
				and catalogs_empty(sync().get_location_catalog(directory, "providers"), sync().get_location_catalog(directory, "agents")) then
				-- Empty catalogs can mean location plugins are still warming up;
				-- no prompt has been admitted yet.
				opts._catalog_ready, opts._catalog_retry = false, true
				vim.defer_fn(function()
					if pending.is_current(token) then M.send(text, opts) end
				end, 100)
			else M.send(text, opts) end
		end)
		return true
	end
	local selection, selection_err = resolve_selection(opts)
	if not selection then return fail_before_send(selection_err, text, opts) end
	local payload, payload_err = requests.prompt(text, opts, ascending_id("msg"))
	if not payload then return fail_before_send(payload_err, text, opts) end
	if session_id then return submit(session_id, payload, selection, text, opts) end
	local body = { title = opts.title, location = { directory = directory }, agent = selection.agent, model = selection.model }
	client().create_session(body, function(err, info)
		if not pending.is_current(token) then return end
		if err then fail_before_send(err.message or "Session creation failed", text, opts); return end
		session_actions.remember(info)
		if not state.get_session().id then
			session_actions.set_active(info.id, info.title or "New session", { reason = "send_create_session", preserve_cache = true })
		end
		submit(info.id, payload, selection, text, opts, info)
	end)
	return true
end

-- Commands have no caller-supplied prompt ID and return HTTP 204. Freeze their
-- selection, serialize with prompts, and never retry an uncertain admission.
function M.command(session_id, name, text, opts, callback)
	opts = vim.deepcopy(opts or {})
	opts.session_id = session_id
	opts.directory = state.normalize_directory(opts.directory or state.get_session_directory(session_id) or vim.fn.getcwd())
	local token = opts._token or pending.token(session_id)
	if not pending.is_current(token) then return false end
	local providers = sync().get_location_catalog(opts.directory, "providers")
	local agents = sync().get_location_catalog(opts.directory, "agents")
	if not opts._catalog_ready and sync().get_catalog_location() ~= nil and (not providers or not providers.data or not agents or not agents.data) then
		opts._selection = opts._selection or selectors.send_selection(opts)
		opts._token, opts._catalog_ready = token, true
		fetch_catalogs(opts.directory, token, function(failure)
			if failure then callback(failure) else M.command(session_id, name, text, opts, callback) end
		end)
		return true
	end
	local selection, err = resolve_selection(opts)
	if not selection then callback({ code = "invalid_selection", message = err }); return false end
	pending.serialize(session_id, function(done)
		require("opencode.session.selection").prepare(session_id, selection, token, function(prepare_err)
			if not pending.is_current(token) then done(); return end
			if prepare_err then callback(prepare_err); done(); return end
			client().execute_command(session_id, name, text, opts, function(command_err, result)
				if pending.is_current(token) then
					callback(command_err, result)
					emit("v2_reconcile", { session_id = session_id })
				end
				done()
			end)
		end)
	end)
	return true
end

-- Removing an inbox item does not interrupt the currently executing response.
function M.cancel_input(session_id, message_id, callback)
	local token = pending.token(session_id)
	client().cancel_input(session_id, message_id, function(err)
		if not pending.is_current(token) then return end
		if not err then
			pending.update(session_id, message_id, { status = "cancelled" })
			require("opencode.local").message_agent.remove(session_id, message_id)
			sync().handle_message_removed(session_id, message_id)
			emit("sync_changed", { kind = "inbox", action = "cancelled", session_id = session_id, message_id = message_id })
		end
		emit("v2_reconcile", { session_id = session_id })
		if callback then callback(err) end
	end)
end

-- A provisional row can exist before the server has admitted its inbox item.
-- Wait for admission before cancelling; reverting it now would target a turn
-- that does not yet exist in durable history.
function M.cancel_submitting_input(session_id, message_id, callback)
	local token = pending.token(session_id)
	pending.when_admitted(session_id, message_id, function(record)
		if not pending.is_current(token) then return end
		if not record then callback({ message = "This input is no longer pending" }); return end
		if record.status == "accepted" or record.status == "queued" then
			M.cancel_input(session_id, message_id, function(err)
				local current = pending.get(session_id, message_id)
				if err and (err.status == 404 or (current and current.status == "delivered")) then
					callback({ code = "already_delivered", message = "Input was already delivered" })
				else callback(err) end
			end)
		elseif record.status == "delivered" then
			callback({ code = "already_delivered", message = "Input was already delivered" })
		elseif record.status == "failed" or record.status == "cancelled" then
			if record.status == "failed" then sync().handle_message_removed(session_id, message_id) end
			callback(nil)
		else
			callback({ message = "Input admission is uncertain; reconnect before undoing it" })
		end
	end)
end

-- Change the existing inbox item instead of cancelling and resending it. Its
-- ID, attachments and delivery confirmation remain owned by the server.
local function set_input_delivery(session_id, message_id, delivery, callback)
	local record = selectors.pending_input(session_id, message_id)
	local expected = delivery == "steer" and "queued" or "accepted"
	if not record or record.status ~= expected then
		if callback then callback({ message = "This input is no longer " .. (expected == "queued" and "queued" or "steering") }) end
		return false
	end
	if record.delivery_request_pending == delivery and record.delivery_request_token
		and pending.is_current(record.delivery_request_token) then return false end
	-- SSE can confirm one change before its HTTP response. A second request may
	-- then reverse it; the older response must not overwrite newer evidence.
	local request_revision = (record.delivery_request_revision or 0) + 1
	local event_revision = record.delivery_event_revision or 0
	local token = pending.token(session_id)
	pending.update(session_id, message_id, { delivery_request_revision = request_revision,
		delivery_request_pending = delivery, delivery_request_token = token })
	client().set_input_delivery(session_id, message_id, delivery, function(err)
		if not pending.is_current(token) then return end
		local current = pending.get(session_id, message_id)
		if current and current.delivery_request_revision == request_revision then
			pending.update(session_id, message_id, { delivery_request_pending = false })
		end
		if err and err.status == 409 and current and current.inbox and current.inbox.delivery == delivery then
			err = nil
		end
		if not err then
			if current and current.inbox and current.delivery_request_revision == request_revision
				and (current.delivery_event_revision or 0) == event_revision
				and (current.status == "queued" or current.status == "accepted") then
				current.inbox.delivery = delivery
				pending.admit(current.inbox)
				emit("sync_changed", { kind = "inbox", action = delivery == "steer" and "steered" or "queued",
					session_id = session_id, message_id = message_id })
			end
		end
		emit("v2_reconcile", { session_id = session_id })
		if callback then callback(err) end
	end)
	return true
end

function M.steer_input(session_id, message_id, callback)
	return set_input_delivery(session_id, message_id, "steer", callback)
end

function M.queue_input(session_id, message_id, callback)
	return set_input_delivery(session_id, message_id, "queue", callback)
end

-- Editing first removes the inbox item. Only a confirmed cancellation returns
-- a draft, so a delivery race cannot send the same prompt twice.
function M.edit_input(session_id, message_id, callback)
	local record = selectors.pending_input(session_id, message_id)
	if not record then
		callback({ message = "This input is no longer pending" })
		return
	end
	local opts = vim.deepcopy(record.options or {})
	local payload = (record.inbox or {}).payload or record.payload or {}
	local text = record.text or payload.text or ""
	local parts = opts.parts or {}
	if record.text == nil then
		vim.list_extend(parts, require("opencode.protocol.v2.messages").draft(payload).parts)
	end
	opts.parts = nil
	-- Admission retries belong to the original send attempt. In particular its
	-- connection token may have expired while the input waited in the inbox.
	opts._token, opts._catalog_ready, opts._catalog_retry, opts._catalog_deadline = nil, nil, nil, nil
	opts.session_id = session_id
	opts.directory = opts.directory or state.get_session_directory(session_id)
	opts.delivery = (record.inbox or {}).delivery or opts.delivery
	opts._selection = record.selection or opts._selection
	M.cancel_input(session_id, message_id, function(err)
		if err then callback(err); return end
		callback(nil, { text = text, parts = parts, options = opts })
	end)
end

return M
