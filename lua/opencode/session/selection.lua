-- Serialized callers use this coordinator before prompt/command admission.
local M = {}
local choices = {}

-- Explicit local choices are scoped to the session in which they were made.
-- Existing sessions otherwise retain their native selection, including changes
-- made by another frontend. Preferences remain defaults for a new session.
function M.choose(session_id, key, value)
	if not session_id or require("opencode.session.lock").is_locked(session_id) then return end
	local pending = require("opencode.session.pending")
	local entry = choices[session_id]
	if not entry or not pending.is_current(entry.token) then entry = { token = pending.token(session_id), values = {} }; choices[session_id] = entry end
	entry.values[key] = value == nil and vim.NIL or vim.deepcopy(value)
	-- A draft variant belongs to the model selected when it was chosen.
	-- The replacement model supplies its own explicit variant or its default.
	if key == "model" then entry.values.variant = nil end
end

function M.current(session_id)
	if not session_id then return nil end
	local info = require("opencode.state").get_session_record(session_id) or {}
	local values = { agent = type(info.agent) == "string" and info.agent or nil, model = type(info.model) == "table" and vim.deepcopy(info.model) or nil }
	if values.model then values.variant = values.model.variant end
	local entry = choices[session_id]
	if entry and not require("opencode.session.pending").is_current(entry.token) then choices[session_id] = nil; entry = nil end
	if entry then
		for key, value in pairs(entry.values) do values[key] = value ~= vim.NIL and vim.deepcopy(value) or nil end
		if entry.values.model and entry.values.variant == nil then values.variant = entry.values.model.variant end
	end
	if values.model then
		values.model.modelID = values.model.id or values.model.modelID
		values.model.variant = values.variant
	end
	return values
end

function M.clear_all() choices = {} end
function M.clear_session(session_id) choices[session_id] = nil end

function M.prepare(session_id, selection, token, callback, known_session)
	local client = require("opencode.client")
	local pending = require("opencode.session.pending")
	local state = require("opencode.state")
	local snapshot = state.get_session_record(session_id)
	local completed = false
	local function finish(err)
		if completed then return end
		completed = true
		if not err then
			local entry = choices[session_id]
			if entry and require("opencode.session.pending").is_current(entry.token) then
				local selected = M.current(session_id)
				local selected_model = selected.model and require("opencode.protocol.v2.requests").model(selected.model, selected.variant)
				if selected.agent == selection.agent and vim.deep_equal(selected_model, selection.model) then choices[session_id] = nil end
			end
		end
		callback(err)
	end
	local function current()
		if pending.is_current(token) then return true end
		finish({ code = "cancelled", message = "Session operation was cancelled" })
		return false
	end
	local function received(err, info)
		if not current() then return end
		if err then finish(err); return end
		if vim.deep_equal(snapshot, state.get_session_record(session_id)) then
			require("opencode.session").remember(info, { touch = false })
		end
		local agent_changed = info.agent ~= selection.agent
		local function model()
			if not current() then return end
			local native_model = require("opencode.protocol.v2.requests").model(info.model)
			if not agent_changed and vim.deep_equal(native_model, selection.model) then finish(); return end
			client.switch_model(session_id, selection.model, function(model_err)
				if not current() then return end
				if not model_err then
					require("opencode.session").remember({ id = session_id, agent = selection.agent, model = selection.model }, { touch = false })
				end
				finish(model_err)
			end)
		end
		if agent_changed then
			client.switch_agent(session_id, selection.agent, function(agent_err)
				if not current() then return end
				if agent_err then finish(agent_err) else model() end
			end)
		else model() end
	end
	if known_session then received(nil, known_session) else client.get_session(session_id, received) end
end
return M
