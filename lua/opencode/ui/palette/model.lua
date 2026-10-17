-- Model selection and integration authentication.
local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")

local function available_model(directory, provider_id, model_id)
	local sync = require("opencode.sync")
	if sync.get_catalog_location() and sync.get_catalog_location() ~= directory then
		local catalog = sync.get_location_catalog(directory, "providers")
		for _, provider in ipairs(catalog and catalog.data and catalog.data.providers or {}) do
			if provider.id == provider_id then return (provider.models or {})[model_id] end
		end
		return
	end
	return sync.get_model(provider_id, model_id)
end

function M.register(palette)
	palette.register({
		id = "model.switch",
		title = "Switch Model",
		description = "Change the AI model",
		category = "model",
		slash = { name = "models" },
		run = function(context)
			local owner = require("opencode.ui.palette")
			context = owner.capture_context(context)
			if not owner.context_valid(context) then return false end
			if require("opencode.session.lock").is_locked(context.session_id) then vim.notify("Subagent model selection is locked", vim.log.levels.INFO); return false end
			local pending = require("opencode.session.pending")
			local token = pending.token(context.session_id)
			local directory = state.get_session_directory(token.session_id) or vim.fn.getcwd()
			local function current()
				return pending.is_current(token) and owner.context_valid(context)
					and not require("opencode.session.lock").is_locked(token.session_id)
					and (state.get_session_directory(token.session_id) or vim.fn.getcwd()) == directory
			end
			actions.get_config_providers(function(err, response)
				if not current() then return end
				if context.view and require("opencode.ui.chat.state").current() ~= context.view then return end
				if err then
					vim.notify("Failed to list providers: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				local provider_list = response and response.providers or {}
				if #provider_list == 0 then
					vim.notify("No providers available. Connect a provider first.", vim.log.levels.WARN)
					return
				end

				local favorites_set, recent_set = {}, {}
				for rank, fav in ipairs(actions.model_favorites()) do favorites_set[fav.providerID .. "/" .. fav.modelID] = rank end
				for rank, recent in ipairs(actions.model_recent()) do recent_set[recent.providerID .. "/" .. recent.modelID] = rank end
				local function describe(item)
					local details = {}
					if item.free then details[#details + 1] = "Free" end
					if item.model.status == "deprecated" then details[#details + 1] = "Deprecated" end
					item.label = string.format("%s[%s] %s", item.is_favorite and "★ " or item.recent_rank and "Recent · " or "", item.provider, item.model.name or item.value)
					item.description = table.concat(details, " · ")
					item.priority = item.is_favorite and 3 or item.recent_rank and 2 or 1
				end

				local items = {}
				for _, provider in ipairs(provider_list) do
					for model_id, model in pairs(provider.models or {}) do
						local key = provider.id .. "/" .. model_id
						local tiers = model.cost or {}
						local free = #tiers > 0
						for _, tier in ipairs(tiers) do if tier.input ~= 0 then free = false end end
						local item = {
							value = model_id,
							key = key,
							provider = provider.id,
							model = model,
							is_favorite = favorites_set[key] ~= nil, favorite_rank = favorites_set[key], recent_rank = recent_set[key], free = free,
							released = type((model.time or {}).released) == "number" and model.time.released > 0 and model.time.released < math.huge and model.time.released or 0,
						}
						if model.status ~= "deprecated" or item.is_favorite or item.recent_rank then describe(item); items[#items + 1] = item end
					end
				end

				if #items == 0 then
					vim.notify("No models available", vim.log.levels.WARN)
					return
				end

				local width = 60
				for _, item in ipairs(items) do
					local detail_width = item.description ~= "" and vim.fn.strdisplaywidth(item.description) + 2 or 0
					-- Leave room for the menu padding and a favorite star added while open.
					width = math.max(width, vim.fn.strdisplaywidth(item.label) + detail_width + 10)
				end
				require("opencode.ui.menu").open({
					context = context,
					items = items,
					title = " Switch Model ",
					width = width,
					searchable = true,
					sort = function(a, b)
						if a.priority ~= b.priority then return a.priority > b.priority end
						if a.is_favorite then return a.favorite_rank < b.favorite_rank end
						if a.recent_rank then return a.recent_rank < b.recent_rank end
						if a.provider ~= b.provider then return a.provider < b.provider end
						if a.free ~= b.free then return a.free end
						if a.released ~= b.released then return a.released > b.released end
						return a.label < b.label
					end,
					on_select = function(item)
						if not current() or not available_model(directory, item.provider, item.value) then return end
						actions.select_model({ providerID = item.provider, modelID = item.value }, { recent = true, session_id = token.session_id })
					end,
					keymap_scope = "model_menu",
					keys = {
						{
							action = "favorite", label = "favorite",
							handler = function(_ctx, item)
								if not current() or not available_model(directory, item.provider, item.value) then return end
								actions.toggle_model_favorite({ providerID = item.provider, modelID = item.value })
								item.is_favorite = not item.is_favorite
								item.favorite_rank = item.is_favorite and 0 or nil
								describe(item)
								vim.notify(item.is_favorite and "Added to favorites" or "Removed from favorites", vim.log.levels.INFO)
							end,
						},
					},
				})
			end, { directory = directory })
		end,
	})
	for _, source in ipairs({ "recent", "favorite" }) do
		for _, direction in ipairs({ 1, -1 }) do
			palette.register({ id = "model.cycle." .. source .. (direction == 1 and ".next" or ".previous"),
				title = (direction == 1 and "Next " or "Previous ") .. (source == "recent" and "Recent Model" or "Favorite Model"),
				category = "model", run = function(context)
					local owner = require("opencode.ui.palette")
					context = owner.capture_context(context)
					if owner.context_valid(context) then actions.cycle_model(direction, { source = source, session_id = context.session_id }) end
				end })
		end
	end
	palette.register({
		id = "model.variant",
		title = "Select Variant",
		description = "Choose a variant for the current model",
		category = "model",
		slash = { name = "variants", aliases = { "thinking", "effort" } },
		on_select = function(context) return context.run() end,
		run = function(context)
			local owner = require("opencode.ui.palette")
			context = owner.capture_context(context)
			if not owner.context_valid(context) then return false end
			local local_state = require("opencode.local")
			local session_id = context.session_id
			local opts = { session_id = session_id }
			local model = local_state.model.current(opts)
			if require("opencode.session.lock").is_locked(session_id) then
				vim.notify("Subagent model selection is locked", vim.log.levels.INFO)
				return false
			end
			if not model then
				vim.notify("Select a model before choosing a variant", vim.log.levels.WARN)
				return false
			end
			local pending = require("opencode.session.pending")
			local token = pending.token(session_id)
			local directory = state.get_session_directory(session_id) or vim.fn.getcwd()
			local selected = local_state.variant.current(opts) or "default"
			local items = { { label = "Default", value = "default" } }
			for _, variant in ipairs(local_state.variant.list(opts)) do
				if variant ~= "default" then items[#items + 1] = { label = variant, value = variant } end
			end
			for _, item in ipairs(items) do
				if item.value == selected then item.description, item.priority = "Current", 1 end
			end
			require("opencode.ui.menu").open({
				context = context,
				items = items,
				title = " Select Variant ",
				width = 50,
				sort = false,
				on_select = function(item)
					local current = local_state.model.current(opts)
					if not pending.is_current(token) or not owner.context_valid(context)
						or (state.get_session_directory(session_id) or vim.fn.getcwd()) ~= directory
						or not current or current.providerID ~= model.providerID or current.modelID ~= model.modelID then return end
					actions.select_variant(item.value, opts)
				end,
			})
		end,
	})
	require("opencode.ui.palette.integration").register(palette)
end

return M
