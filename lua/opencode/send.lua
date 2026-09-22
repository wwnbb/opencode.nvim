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

local pending = require("opencode.session.pending")
local requests = require("opencode.protocol.v2.requests")
local projection = require("opencode.protocol.v2.messages")

local function client() return require("opencode.client") end
local function sync() return require("opencode.sync") end
local function emit(name, data) require("opencode.events").emit(name, data) end

local function restore_draft(text, opts)
	local history = require("opencode.ui.input.history")
	if history.get_pending() == "" then history.set_pending(text, opts.parts) end
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
	pending.begin({ session_id = session_id, message_id = payload.id, status = "submitting",
		text = text, options = opts, payload = payload, selection = selection, token = token })
	seed(session_id, payload)
	session_actions.set_status("streaming", { session_id = session_id, reason = "send_started" })
	pending.serialize(session_id, function(done)
		local submitted = false
		local function fail(err)
			if not pending.is_current(token) then done(); return end
			local definite = not submitted or (err.status and err.status >= 400 and err.status < 500)
			local record = pending.update(session_id, payload.id, { status = definite and "failed" or "uncertain", error = err })
			if record and record.status == "failed" then
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
				pending.admit(item)
				-- A delayed HTTP callback must not replace the delivered timestamp or
				-- regress state already confirmed by the event stream.
				emit("sync_changed", { kind = "inbox", action = "accepted", session_id = session_id, message_id = payload.id })
				emit("v2_reconcile", { session_id = session_id })
				done()
			end)
		end
		require("opencode.session.selection").prepare(session_id, selection, token, function(err)
			if err then fail(err) else prompt() end
		end, known_session)
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
	local token = opts._token or pending.token(session_id)
	if not pending.is_current(token) then return false end
	local directory = opts.directory or (session_id and state.get_session_directory(session_id)) or vim.fn.getcwd()
	opts.directory = state.normalize_directory(directory)
	directory = opts.directory
	local provider_cache = sync().get_location_catalog(directory, "providers")
	local agent_cache = sync().get_location_catalog(directory, "agents")
	if not opts._catalog_ready and sync().get_catalog_location() ~= nil and (opts._catalog_retry or catalogs_empty(provider_cache, agent_cache)) then
		opts._selection = opts._selection or selectors.send_selection(opts)
		opts.session_id, opts._token, opts._catalog_ready = session_id or false, token, true
		opts._catalog_deadline = opts._catalog_deadline or (current_time_ms() + 5000)
		local remaining, first_error = 2, nil
		local function received(domain, err, data)
			if not pending.is_current(token) then return end
			first_error = first_error or err
			sync().handle_location_catalog(directory, domain, data, err)
			remaining = remaining - 1
			if remaining == 0 then
				if first_error then fail_before_send(first_error.message or "Catalog unavailable", text, opts)
				elseif current_time_ms() < opts._catalog_deadline
					and catalogs_empty(sync().get_location_catalog(directory, "providers"), sync().get_location_catalog(directory, "agents")) then
					-- 2.0.11 can return empty catalogs while a newly visited
					-- location loads its plugins. No prompt has been admitted yet.
					opts._catalog_ready, opts._catalog_retry = false, true
					vim.defer_fn(function()
						if pending.is_current(token) then M.send(text, opts) end
					end, 100)
				else M.send(text, opts) end
			end
		end
		client().get_config_providers(function(err, data) received("providers", err, data) end, { directory = directory })
		client().list_agents(function(err, data) received("agents", err, data) end, { directory = directory })
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
		local remaining, failure = 2, nil
		local function received(domain, err, data)
			if not pending.is_current(token) then return end
			failure = failure or err
			sync().handle_location_catalog(opts.directory, domain, data, err)
			remaining = remaining - 1
			if remaining == 0 then
				if failure then callback(failure) else M.command(session_id, name, text, opts, callback) end
			end
		end
		client().get_config_providers(function(err, data) received("providers", err, data) end, { directory = opts.directory })
		client().list_agents(function(err, data) received("agents", err, data) end, { directory = opts.directory })
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
			sync().handle_message_removed(session_id, message_id)
			emit("sync_changed", { kind = "inbox", action = "cancelled", session_id = session_id, message_id = message_id })
		end
		emit("v2_reconcile", { session_id = session_id })
		if callback then callback(err) end
	end)
end

return M
