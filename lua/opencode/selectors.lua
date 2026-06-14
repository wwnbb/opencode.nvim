-- Read-only selectors for derived OpenCode state.
-- This module is the answer layer for questions like "what model will send use?"

local M = {}

local SessionView = require("opencode.session.view")
local navigation = require("opencode.session.navigation")

local function logger()
	local ok, mod = pcall(require, "opencode.logger")
	return ok and mod or nil
end

---@param value any
---@return string
local function value_kind(value)
	if value == nil then
		return "nil"
	end
	if value == vim.NIL then
		return "vim.NIL"
	end
	return type(value)
end

---@param model any
---@return table
local function model_summary(model)
	if type(model) ~= "table" then
		return {
			kind = value_kind(model),
		}
	end
	return {
		kind = "table",
		providerID = model.providerID,
		modelID = model.modelID,
		variant = model.variant,
	}
end

---@param ref any
---@param source string
---@param sync table|nil
---@return { providerID: string, modelID: string }|nil
local function resolve_model_ref(ref, source, sync)
	local log = logger()
	if type(ref) ~= "table" or type(ref.providerID) ~= "string" or type(ref.modelID) ~= "string" then
		if log then
			log.debug("Model candidate skipped", {
				source = source,
				reason = "malformed",
				model = model_summary(ref),
			})
		end
		return nil
	end

	if ref.providerID == "" or ref.modelID == "" then
		if log then
			log.debug("Model candidate skipped", {
				source = source,
				reason = "empty",
				model = model_summary(ref),
			})
		end
		return nil
	end

	if not sync or not sync.get_model(ref.providerID, ref.modelID) then
		if log then
			log.debug("Model candidate skipped", {
				source = source,
				reason = sync and "not_in_sync" or "sync_unavailable",
				model = model_summary(ref),
			})
		end
		return nil
	end

	if log then
		log.debug("Model candidate accepted", {
			source = source,
			model = model_summary(ref),
		})
	end
	return {
		providerID = ref.providerID,
		modelID = ref.modelID,
	}
end

---@return table
function M.current_session()
	return require("opencode.state").get_session()
end

---@return string
function M.current_status()
	return require("opencode.state").get_status()
end

local function sessions_snapshot(state_mod)
	local snapshot = state_mod.get_full_state()
	return snapshot.sessions or {}, snapshot.session or {}
end

local function runtime_lookup(sessions)
	local lookup = {}
	for _, id in ipairs(sessions.runtime_order or {}) do
		if type(id) == "string" and id ~= "" then
			lookup[id] = true
		end
	end
	return lookup
end

local function current_root_id(state_mod, current)
	return navigation.runtime_session_id(current and current.id, { state = state_mod })
end

local function record_for_session(sessions, current, runtime_ids, session_id)
	if not session_id or session_id == "" then
		return nil
	end
	local record = sessions.by_id and sessions.by_id[session_id] or nil
	if record then
		record = vim.deepcopy(record)
	elseif current and current.id == session_id then
		record = {
			id = current.id,
			title = current.name,
			name = current.name,
			message_count = current.message_count,
			messageCount = current.message_count,
		}
	elseif runtime_ids[session_id] then
		record = {
			id = session_id,
			title = session_id,
			name = session_id,
			message_count = 0,
			messageCount = 0,
		}
	else
		return nil
	end

	if current and current.id == session_id then
		record.name = current.name or record.name
		if current.message_count ~= nil then
			record.message_count = current.message_count
			record.messageCount = current.message_count
		end
	end
	return record
end

local function view_for_record(record, sessions, current, runtime_ids, root_id)
	if type(record) ~= "table" or not record.id then
		return nil
	end
	return SessionView.from_record(record, {
		status = sessions.status and sessions.status[record.id] or nil,
		pending = sessions.pending and sessions.pending[record.id] or nil,
		cached_messages = sessions.message_cache and sessions.message_cache[record.id] or nil,
		is_current = current and current.id == record.id,
		is_runtime = runtime_ids[record.id] == true,
		current_root_id = root_id,
	})
end

local function build_session_view(session_id)
	local state_mod = require("opencode.state")
	local sessions, current = sessions_snapshot(state_mod)
	local runtime_ids = runtime_lookup(sessions)
	local root_id = current_root_id(state_mod, current)
	local record = record_for_session(sessions, current, runtime_ids, session_id)
	return view_for_record(record, sessions, current, runtime_ids, root_id)
end

---@return table|nil
function M.get_current_session_view()
	local current = require("opencode.state").get_session()
	if not current.id then
		return nil
	end
	return build_session_view(current.id)
end

---@param session_id string|nil
---@return table|nil
function M.get_session_view(session_id)
	return build_session_view(session_id)
end

---@return string|nil
function M.get_current_runtime_root_id()
	local state_mod = require("opencode.state")
	local current = state_mod.get_session()
	return current_root_id(state_mod, current)
end

---@return table[]
function M.get_active_session_views()
	local state_mod = require("opencode.state")
	local sessions, current = sessions_snapshot(state_mod)
	local runtime_ids = runtime_lookup(sessions)
	local root_id = current_root_id(state_mod, current)
	local result = {}
	local seen = {}

	for _, id in ipairs(sessions.runtime_order or {}) do
		if not seen[id] then
			local record = record_for_session(sessions, current, runtime_ids, id)
			local view = view_for_record(record, sessions, current, runtime_ids, root_id)
			if view then
				table.insert(result, view)
				seen[id] = true
			end
		end
	end

	return result
end

---@return table[]
function M.get_recent_session_views()
	local state_mod = require("opencode.state")
	local sessions, current = sessions_snapshot(state_mod)
	local runtime_ids = runtime_lookup(sessions)
	local root_id = current_root_id(state_mod, current)
	local result = {}
	local seen = {}

	local function add(id, allow_fallback)
		if not id or id == "" or seen[id] then
			return
		end
		local record = allow_fallback and record_for_session(sessions, current, runtime_ids, id)
			or (sessions.by_id and sessions.by_id[id] and vim.deepcopy(sessions.by_id[id]) or nil)
		local view = view_for_record(record, sessions, current, runtime_ids, root_id)
		if view then
			table.insert(result, view)
			seen[id] = true
		end
	end

	for _, id in ipairs(sessions.recent_order or {}) do
		add(id, false)
	end
	if current.id and runtime_ids[current.id] and not seen[current.id] then
		local record = record_for_session(sessions, current, runtime_ids, current.id)
		local view = view_for_record(record, sessions, current, runtime_ids, root_id)
		if view then
			table.insert(result, 1, view)
		end
	end

	return result
end

---@return table
function M.get_active_session_counts()
	local counts = { running = 0, waiting = 0, error = 0, total = 0 }
	for _, view in ipairs(M.get_active_session_views()) do
		counts.total = counts.total + 1
		if view:is_busy() then
			counts.running = counts.running + 1
		end
		if view:is_waiting() then
			counts.waiting = counts.waiting + 1
		end
		if view:is_error() then
			counts.error = counts.error + 1
		end
	end
	return counts
end

---@return table|nil
function M.current_agent()
	local ok, local_state = pcall(require, "opencode.local")
	if not ok or not local_state.agent or type(local_state.agent.current) ~= "function" then
		return nil
	end
	return local_state.agent.current()
end

---@return table|nil
function M.current_model()
	local ok, local_state = pcall(require, "opencode.local")
	if not ok or not local_state.model or type(local_state.model.parsed) ~= "function" then
		return nil
	end
	return local_state.model.parsed()
end

---@return string|nil
function M.current_variant()
	local ok, local_state = pcall(require, "opencode.local")
	if not ok or not local_state.variant or type(local_state.variant.current) ~= "function" then
		return nil
	end
	return local_state.variant.current()
end

---@return table
function M.changes_stats()
	local ok, changes = pcall(require, "opencode.artifact.changes")
	if not ok or type(changes.get_pending) ~= "function" then
		return {
			total_files = 0,
			total_additions = 0,
			total_deletions = 0,
		}
	end

	local total_additions = 0
	local total_deletions = 0
	local pending = changes.get_pending()
	for _, change in ipairs(pending) do
		local stats = change.stats or {}
		total_additions = total_additions + (stats.added or stats.additions or 0)
		total_deletions = total_deletions + (stats.removed or stats.deletions or 0)
	end

	return {
		total_files = #pending,
		total_additions = total_additions,
		total_deletions = total_deletions,
	}
end

---@param opts? table { model?: table, agent?: string, variant?: string }
---@return { model: table|nil, agent: string|nil, variant: string|nil, sources: table }
function M.send_selection(opts)
	opts = opts or {}
	local sync_ok, sync = pcall(require, "opencode.sync")
	if not sync_ok then
		sync = nil
	end

	local config = require("opencode.state").get_config() or {}
	local session_config = config.session or {}
	local selection = {
		model = nil,
		agent = nil,
		variant = opts.variant,
		sources = {},
	}

	if opts.model then
		selection.model = resolve_model_ref(opts.model, "opts", sync)
		if selection.model then
			selection.sources.model = "opts"
		end
	end

	if type(opts.agent) == "string" and opts.agent ~= "" then
		selection.agent = opts.agent
		selection.sources.agent = "opts"
	end

	local local_ok, local_state = pcall(require, "opencode.local")
	if local_ok then
		if not selection.model and local_state.model and type(local_state.model.current) == "function" then
			selection.model = resolve_model_ref(local_state.model.current(), "local_current", sync)
			if selection.model then
				selection.sources.model = "local_current"
			end
		end
		if not selection.agent and local_state.agent and type(local_state.agent.current) == "function" then
			local agent = local_state.agent.current()
			if type(agent) == "table" and type(agent.name) == "string" and agent.name ~= "" then
				selection.agent = agent.name
				selection.sources.agent = "local_current"
			end
		end
		if selection.variant == nil and local_state.variant and type(local_state.variant.current) == "function" then
			selection.variant = local_state.variant.current()
			if selection.variant ~= nil then
				selection.sources.variant = "local_current"
			end
		end
	end

	if not selection.model then
		selection.model = resolve_model_ref(session_config.default_model, "plugin_config_default", sync)
		if selection.model then
			selection.sources.model = "plugin_config_default"
		end
	end

	if not selection.agent and sync and type(session_config.default_agent) == "string" then
		local configured = sync.get_agent(session_config.default_agent)
		if configured and sync.is_visible_agent(configured) then
			selection.agent = configured.name
			selection.sources.agent = "plugin_config_default"
		end
	end

	return selection
end

return M
