-- Model selection and integration authentication.
local M = {}
local actions = require("opencode.actions")

function M.register(palette)
	palette.register({
		id = "model.switch",
		title = "Switch Model",
		description = "Change the AI model",
		category = "model",
		keybind = "<leader>om",
		action = function()
				-- Use /config/providers (like TUI) to get providers with models
				actions.get_config_providers(function(err, response)
						if err then
							vim.schedule(function()
							vim.notify(
								"Failed to list providers: " .. tostring(err.message or err),
								vim.log.levels.ERROR
							)
						end)
						return
					end
					vim.schedule(function()
						-- Response is { providers: Provider[], default: { providerID: modelID } }
						local provider_list = response and response.providers or {}
						if #provider_list == 0 then
							vim.notify("No providers available. Connect a provider first.", vim.log.levels.WARN)
							return
						end

							-- All providers from /config/providers are connected
						local connected_set = {}
						for _, p in ipairs(provider_list) do
							connected_set[p.id] = true
						end

						-- Flatten models from all providers
						-- provider.models is a map {model_id: model}, not an array
						-- Connected providers' models get higher priority
						local items = {}

						-- Get favorites to mark them with stars
							local favorites_set = {}
							for _, fav in ipairs(actions.model_favorites()) do
								favorites_set[fav.providerID .. "/" .. fav.modelID] = true
							end

						for _, provider in ipairs(provider_list) do
							if provider.models then
								local is_connected = connected_set[provider.id] or false
								for model_id, model in pairs(provider.models) do
									local is_favorite = favorites_set[provider.id .. "/" .. model_id]
									table.insert(items, {
										label = string.format(
											"%s[%s] %s",
											is_favorite and "★ " or "",
											provider.id,
											model.name or model_id
										),
										value = model_id,
										key = provider.id .. "/" .. model_id,
										provider = provider.id,
										model = model,
										description = is_connected and "Connected" or nil,
										priority = (is_favorite and 2 or 0) + (is_connected and 1 or 0),
										is_favorite = is_favorite,
									})
								end
							end
						end

						if #items == 0 then
							vim.notify("No models available", vim.log.levels.WARN)
							return
						end

						local menu = require("opencode.ui.menu")
						menu.open({
							items = items,
							title = " Switch Model ",
							width = 60,
							searchable = true,
							on_select = function(item)
								actions.select_model({
									providerID = item.provider,
									modelID = item.value,
								}, { recent = true })
							end,
							keys = {
								{
									key = "f",
									label = "f:fav",
									handler = function(_ctx, item)
										actions.toggle_model_favorite({
											providerID = item.provider,
											modelID = item.value,
										})
										item.is_favorite = not item.is_favorite
										item.label = string.format(
											"%s[%s] %s",
											item.is_favorite and "★ " or "",
											item.provider,
											item.model.name or item.value
										)
										item.priority = (item.is_favorite and 2 or 0)
											+ (item.description == "Connected" and 1 or 0)
										vim.notify(
											item.is_favorite and "Added to favorites" or "Removed from favorites",
											vim.log.levels.INFO
										)
									end,
								},
							},
						})
						end)
					end)
			end,
		})
	require("opencode.ui.palette.integration").register(palette)
end

return M
