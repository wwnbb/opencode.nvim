-- Read-only selectors for derived OpenCode state.
-- This module is the answer layer for questions like "what model will send use?"

local M = {}

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
