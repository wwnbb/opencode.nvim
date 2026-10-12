-- Read-only selectors for derived OpenCode state.
-- This module is the answer layer for questions like "what model will send use?"

local M = {}

local SessionView = require("opencode.session.view")
local navigation = require("opencode.session.navigation")
local session_lock = require("opencode.session.lock")

local function logger()
	local ok, mod = pcall(require, "opencode.logger")
	return ok and mod or nil
end

---@param ref any
---@param source string
---@param sync table|nil
---@return { providerID: string, modelID: string }|nil
local function resolve_model_ref(ref, source, sync)
	local log = logger()
	local model_id = type(ref) == "table" and (ref.id or ref.modelID) or nil
	local reason
	if type(ref) ~= "table" or type(ref.providerID) ~= "string" or type(model_id) ~= "string" then
		reason = "malformed"
	elseif ref.providerID == "" or model_id == "" then
		reason = "empty"
	elseif not sync or not sync.get_model(ref.providerID, model_id) then
		reason = sync and "not_in_sync" or "sync_unavailable"
	end

	if log then
		log.debug(reason and "Model candidate skipped" or "Model candidate accepted", {
			source = source,
			reason = reason,
			model = log.model_summary(ref),
		})
	end
	if reason then return nil end
	return {
		providerID = ref.providerID,
		modelID = model_id,
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

local function current_root_id(state_mod, current)
	return navigation.runtime_session_id(current and current.id, { state = state_mod })
end

local function build_session_view(state_mod, current, session_id, root_id)
	if not session_id or session_id == "" then return nil end
	local record = state_mod.get_session_record(session_id)
	if not record then
		if current.id ~= session_id and not state_mod.is_runtime_session(session_id) then return nil end
		local title = current.id == session_id and current.name or session_id
		record = { id = session_id, title = title, name = title, message_count = 0 }
	end
	if current.id == session_id then
		record.name = current.name or record.name
		if current.message_count ~= nil then record.message_count = current.message_count end
	end
	return SessionView.from_owned_record(record, {
		status = state_mod.get_session_status(session_id),
		pending = state_mod.get_session_pending_counts(session_id),
		cached_messages = state_mod.get_session_message_cache(session_id),
		is_current = current.id == session_id,
		current_root_id = root_id,
	})
end

---@return table|nil
function M.get_current_session_view()
	return M.get_session_view(require("opencode.state").get_session().id)
end

---@param session_id string|nil
---@return table|nil
function M.get_session_view(session_id)
	local state_mod = require("opencode.state")
	local current = state_mod.get_session()
	return build_session_view(state_mod, current, session_id, current_root_id(state_mod, current))
end

---@return string|nil
function M.get_current_runtime_root_id()
	local state_mod = require("opencode.state")
	return current_root_id(state_mod, state_mod.get_session())
end

---@return table[]
function M.get_active_session_views()
	local state_mod = require("opencode.state")
	local current = state_mod.get_session()
	local root_id = current_root_id(state_mod, current)
	local result, seen = {}, {}
	for _, id in ipairs(state_mod.get_runtime_session_order()) do
		if not seen[id] then
			local view = build_session_view(state_mod, current, id, root_id)
			if view then result[#result + 1], seen[id] = view, true end
		end
	end
	return result
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

local function usage_number(value)
	return type(value) == "number" and value == value and value >= 0 and value < math.huge
end

-- Native TokenUsage.Info has five fields; partial/absent usage is unknown.
function M.token_usage(tokens)
	if type(tokens) ~= "table" or type(tokens.cache) ~= "table" then return nil end
	local input, output, reasoning = tokens.input, tokens.output, tokens.reasoning
	local read, write = tokens.cache.read, tokens.cache.write
	if not usage_number(input) or not usage_number(output) or not usage_number(reasoning) or not usage_number(read) or not usage_number(write) then return nil end
	local total = input + output + reasoning + read + write
	if not usage_number(total) then return nil end
	return { input = input, output = output, reasoning = reasoning, cached = read, cache_write = write,
		new = total - read, total = total }
end

-- Mirrors TUI util/session.ts: latest measured step after completed compaction,
-- before the staged revert boundary. Historical usage is never current context.
local function derive_context(state, sync, session_id)
	local messages = sync.get_messages(session_id)
	local record = state.get_session_record(session_id) or {}
	local boundary = type(record.revert) == "table" and record.revert.messageID
	local last = #messages
	if boundary then
		last = nil
		for index, message in ipairs(messages) do if message.id == boundary then last = index - 1; break end end
		if not last then return nil end
	end
	for index = last, 1, -1 do
		local message = messages[index]
		local kind = message.type or message.role
		if kind == "compaction" and message.status == "completed" then return nil end
		if kind == "assistant" and message.tokens ~= nil then
			local usage = M.token_usage(message.tokens)
			if not usage or usage.total <= 0 then return nil end
			local provider_id = (message.model or {}).providerID or message.providerID
			local model_id = (message.model or {}).id or message.modelID
			local model
			if not sync.get_catalog_location() or sync.get_catalog_location() == state.get_session_directory(session_id) then
				model = sync.get_model(provider_id, model_id)
			else
				local catalog = sync.get_location_catalog(state.get_session_directory(session_id), "providers")
				for _, provider in ipairs(catalog and catalog.data and catalog.data.providers or {}) do
					if provider.id == provider_id then model = (provider.models or {})[model_id]; break end
				end
			end
			local limit = model and (model.limit or {}).context
			if not usage_number(limit) or limit == 0 then limit = nil end
			return { tokens = usage.total, percent = limit and math.floor(usage.total / limit * 100 + 0.5) or nil,
				limit = limit, message_id = message.id, model = { providerID = provider_id, modelID = model_id }, breakdown = usage }
		end
	end
end

-- Only the most recently requested session is retained; callers own their copy.
local context_cache
function M.current_context(session_id)
	local state, sync = require("opencode.state"), require("opencode.sync")
	session_id = session_id or (state.get_session() or {}).id
	if not session_id then return nil end
	local signature = table.concat({ session_id, state.get_revision(), sync.get_session_revision(session_id),
		sync.get_history_metadata_generation(session_id), sync.get_catalog_generation() }, "\0")
	if not context_cache or context_cache.state ~= state or context_cache.sync ~= sync or context_cache.signature ~= signature then
		context_cache = { state = state, sync = sync, signature = signature, value = derive_context(state, sync, session_id) }
	end
	return context_cache.value and vim.deepcopy(context_cache.value) or nil
end

-- Authoritative money counters include utility work. Root cost includes known
-- native descendants; an unknown member remains a partial total, never zero.
local function derive_cost(state, session_id)
	local record = session_id and state.get_session_record(session_id)
	if not record then return nil, nil, false end
	if type(record.parentID) == "string" and record.parentID ~= "" then
		return usage_number(record.cost) and record.cost or nil, usage_number(record.cost), true
	end
	local records, total, known, complete = {}, 0, false, true
	for _, id in ipairs(state.get_session_ids()) do records[id] = state.get_session_record(id) end
	local owned = { [session_id] = true }
	for id, member in pairs(records) do
		local parent, path, seen = id, {}, {}
		while parent and owned[parent] == nil and not seen[parent] do
			seen[parent], path[#path + 1] = true, parent
			parent = records[parent] and records[parent].parentID
		end
		local included = owned[parent] == true
		for _, child in ipairs(path) do owned[child] = included end
		if included then
			if usage_number(member.cost) then total, known = total + member.cost, true else complete = false end
		end
	end
	return known and total or nil, complete and known, true
end

local cost_cache
function M.session_cost(session_id)
	local state = require("opencode.state")
	session_id = session_id or (state.get_session() or {}).id
	local revision = state.get_revision()
	if not cost_cache or cost_cache.state ~= state or cost_cache.id ~= session_id or cost_cache.revision ~= revision then
		local value, complete, exists = derive_cost(state, session_id)
		cost_cache = { state = state, id = session_id, revision = revision, value = value, complete = complete, exists = exists }
	end
	if not cost_cache.exists then return nil end
	return cost_cache.value, cost_cache.complete
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
---@return { model: table|nil, agent: string|nil, variant: string|nil, blocked?: boolean, error?: string, sources: table }
function M.send_selection(opts)
	opts = opts or {}
	local sync_ok, sync = pcall(require, "opencode.sync")
	if not sync_ok then
		sync = nil
	end

	local current_session = require("opencode.state").get_session()
	local locked = session_lock.get(opts.session_id or current_session.id)
	if locked then
		local selection = {
			model = nil,
			agent = locked.agent,
			variant = locked.variant,
			sources = {
				agent = "child_lock",
				model = "child_lock",
				variant = "child_lock",
			},
		}
		if locked.pending then
			selection.blocked = true
			selection.error = locked.error or "Subagent execution selection is still resolving"
			return selection
		end
		if type(selection.agent) ~= "string" or selection.agent == "" then
			selection.blocked = true
			selection.error = "Subagent agent could not be determined"
			return selection
		end
		if type(locked.model) ~= "table" or type(locked.model.providerID) ~= "string" or type(locked.model.modelID) ~= "string"
			or locked.model.providerID == "" or locked.model.modelID == ""
		then
			selection.blocked = true
			selection.error = locked.error or "Subagent execution model could not be determined"
			return selection
		end
		selection.model = {
			providerID = locked.model.providerID,
			modelID = locked.model.modelID,
		}
		return selection
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
	local sid = opts.session_id
	if sid == nil then sid = current_session.id end
	local scoped = require("opencode.session.selection").current(sid)
	if scoped then
		if not selection.model and scoped.model then selection.model = scoped.model; selection.sources.model = "session" end
		if not selection.agent and scoped.agent then selection.agent = scoped.agent; selection.sources.agent = "session" end
		if opts.variant == nil then
			if opts.model then selection.variant = opts.model.variant else selection.variant = scoped.variant end
		end
	end

	local local_ok, local_state = pcall(require, "opencode.local")
	local local_opts = { unscoped = sid == false or sid ~= current_session.id }
	if local_ok then
		if not selection.model and local_state.model and type(local_state.model.current) == "function" then
			selection.model = resolve_model_ref(local_state.model.current(local_opts), "local_current", sync)
			if selection.model then
				selection.sources.model = "local_current"
			end
		end
		if not selection.agent and local_state.agent and type(local_state.agent.current) == "function" then
			local agent = local_state.agent.current(local_opts)
			if type(agent) == "table" and type(agent.name) == "string" and agent.name ~= "" then
				selection.agent = agent.id or agent.name
				selection.sources.agent = "local_current"
			end
		end
		if selection.variant == nil and selection.sources.model ~= "session" and not opts.model
			and local_state.variant and type(local_state.variant.current) == "function" then
			selection.variant = local_state.variant.current(local_opts)
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
			selection.agent = configured.id or configured.name
			selection.sources.agent = "plugin_config_default"
		end
	end

	return selection
end

-- Admission is separate from execution; delivered messages need no queue badge.
local PROMPT_LABELS = {
	queued = "Queued", accepted = "Steering pending",
	uncertain = "Delivery unknown · reconnect to check", failed = "Send failed · draft preserved",
}

-- Return both the display label and the actionable record from one snapshot.
function M.prompt_status(session_id, message_id)
	local message = require("opencode.sync").get_message(session_id, message_id)
	if message and message.role == "user" and not message.provisional then return nil end
	local record = require("opencode.session.pending").get(session_id, message_id)
	if not record then return nil end
	local label = PROMPT_LABELS[record.status]
	if record.status == "submitting" then
		local delivery = (record.payload or {}).delivery or "queue"
		label = "Sending · " .. delivery
	end
	if record.delivery_missing and record.status ~= "delivered" and record.status ~= "cancelled" then
		label = PROMPT_LABELS.uncertain
	end
	return label, (record.status == "queued" or record.status == "accepted") and record or nil
end

function M.pending_input(session_id, message_id)
	local _, record = M.prompt_status(session_id, message_id)
	return record
end

return M
