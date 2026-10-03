-- Model selection and integration authentication.
local M = {}
local actions = require("opencode.actions")
local state = require("opencode.state")

function M.register(palette)
	palette.register({
		id = "model.switch",
		title = "Switch Model",
		description = "Change the AI model",
		category = "model",
		keybind = "<leader>om",
		slash = { name = "models" },
		run = function()
			local pending = require("opencode.session.pending")
			local token = pending.token(state.get_session().id)
			local directory = state.get_session_directory(token.session_id) or vim.fn.getcwd()
			local function current()
				return pending.is_current(token) and state.get_session().id == token.session_id
					and (state.get_session_directory(token.session_id) or vim.fn.getcwd()) == directory
			end
			actions.get_config_providers(function(err, response)
				if not current() then return end
				if err then
					vim.notify("Failed to list providers: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				local provider_list = response and response.providers or {}
				if #provider_list == 0 then
					vim.notify("No providers available. Connect a provider first.", vim.log.levels.WARN)
					return
				end

				local favorites_set = {}
				for _, fav in ipairs(actions.model_favorites()) do
					favorites_set[fav.providerID .. "/" .. fav.modelID] = true
				end

				local items = {}
				for _, provider in ipairs(provider_list) do
					for model_id, model in pairs(provider.models or {}) do
						local is_favorite = favorites_set[provider.id .. "/" .. model_id]
						table.insert(items, {
							label = string.format("%s[%s] %s", is_favorite and "★ " or "", provider.id, model.name or model_id),
							value = model_id,
							key = provider.id .. "/" .. model_id,
							provider = provider.id,
							model = model,
							description = "Connected",
							priority = (is_favorite and 2 or 0) + 1,
							is_favorite = is_favorite,
						})
					end
				end

				if #items == 0 then
					vim.notify("No models available", vim.log.levels.WARN)
					return
				end

				require("opencode.ui.menu").open({
					items = items,
					title = " Switch Model ",
					width = 60,
					searchable = true,
					on_select = function(item)
						if not current() then return end
						actions.select_model({ providerID = item.provider, modelID = item.value }, { recent = true })
					end,
					keys = {
						{
							key = "f",
							label = "f:fav",
							handler = function(_ctx, item)
								actions.toggle_model_favorite({ providerID = item.provider, modelID = item.value })
								item.is_favorite = not item.is_favorite
								item.label = string.format("%s[%s] %s", item.is_favorite and "★ " or "", item.provider, item.model.name or item.value)
								item.priority = (item.is_favorite and 2 or 0) + 1
								vim.notify(item.is_favorite and "Added to favorites" or "Removed from favorites", vim.log.levels.INFO)
							end,
						},
					},
				})
			end)
		end,
	})
	require("opencode.ui.palette.integration").register(palette)
end

return M
