-- opencode.nvim - Model and provider palette commands

local M = {}

local actions = require("opencode.actions")
local float_context = require("opencode.ui.float_context")

local hl_ns = vim.api.nvim_create_namespace("opencode_palette")

local show_provider_models
local show_oauth_auto_dialog

-- Helper: Connect provider with specific auth method
-- This handles API key input or OAuth flow
---@param provider table Provider info
---@param method table Auth method { type, label }
---@param method_index number 0-indexed method index for API
local function connect_provider_with_method(provider, method, method_index)
	local float = require("opencode.ui.float")

	-- Ensure we're focused on the chat window before showing input
	local chat = require("opencode.ui.chat")
	if chat.focus then
		chat.focus()
	end

	if method.type == "api" then
		-- API key authentication - prompt for key
		float.create_input_popup({
			title = " " .. (method.label or "API Key") .. " ",
			prompt = "Enter API key for " .. (provider.name or provider.id) .. ":",
			refocus_chat = true,
			on_submit = function(api_key)
				if not api_key or api_key == "" then
					vim.notify("API key cannot be empty", vim.log.levels.WARN)
					return
				end

					actions.set_provider_auth(provider.id, { type = "api", key = api_key }, function(err)
						vim.schedule(function()
						if err then
							vim.notify("Failed to set API key: " .. tostring(err.message or err), vim.log.levels.ERROR)
							return
						end

						-- Dispose and reconnect to refresh provider list
							actions.dispose_server(function()
								vim.notify("Connected to " .. (provider.name or provider.id), vim.log.levels.INFO)

							-- Now show model selection for this provider
							show_provider_models(provider)
						end)
					end)
				end)
			end,
		})
	elseif method.type == "oauth" then
		-- OAuth authentication - initiate OAuth flow
			actions.oauth_authorize(provider.id, method_index, function(err, authorization)
				vim.schedule(function()
				if err then
					vim.notify("Failed to start OAuth: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end

				if not authorization then
					vim.notify("No authorization response", vim.log.levels.ERROR)
					return
				end

				if authorization.method == "code" then
					-- Code-based OAuth: open URL and prompt for code
					if authorization.url then
						vim.ui.open(authorization.url)
					end

					float.create_input_popup({
						title = " " .. (method.label or "OAuth") .. " ",
						prompt = authorization.instructions or "Enter authorization code:",
						refocus_chat = true,
						on_submit = function(code)
							if not code or code == "" then
								vim.notify("Authorization code cannot be empty", vim.log.levels.WARN)
								return
							end

								actions.oauth_callback(provider.id, method_index, code, function(cb_err)
									vim.schedule(function()
									if cb_err then
										vim.notify(
											"OAuth failed: " .. tostring(cb_err.message or cb_err),
											vim.log.levels.ERROR
										)
										return
									end

										actions.dispose_server(function()
										vim.notify(
											"Connected to " .. (provider.name or provider.id),
											vim.log.levels.INFO
										)
										show_provider_models(provider)
									end)
								end)
							end)
						end,
					})
				elseif authorization.method == "auto" then
					-- Auto OAuth: show dialog with URL and device code, then wait for callback
					-- Extract device code from instructions (format like "XXXX-XXXX" or "XXXX-XXXXX")
					local device_code = nil
					if authorization.instructions then
						device_code = authorization.instructions:match(
							"[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]?"
						)
					end

					-- Show the authorization dialog
					show_oauth_auto_dialog({
						provider = provider,
						method = method,
						method_index = method_index,
						authorization = authorization,
						device_code = device_code,
					})
				end
			end)
		end)
	else
		vim.notify("Unknown auth method: " .. tostring(method.type), vim.log.levels.ERROR)
	end
end

-- Helper: Show model selection for a specific provider after connection
---@param provider table Provider info
show_provider_models = function(provider)
	local menu = require("opencode.ui.menu")

	-- Ensure we're focused on the chat window
	local chat = require("opencode.ui.chat")
	if chat.focus then
		chat.focus()
	end

	-- Refresh provider list to get updated models
	actions.list_providers(function(err, response)
		vim.schedule(function()
			if err then
				vim.notify("Failed to refresh providers", vim.log.levels.WARN)
				return
			end

			-- Find the provider in the refreshed list
			local updated_provider = nil
			for _, p in ipairs(response.all or {}) do
				if p.id == provider.id then
					updated_provider = p
					break
				end
			end

			if not updated_provider or not updated_provider.models then
				vim.notify("Provider has no models available", vim.log.levels.WARN)
				return
			end

			-- Build model items
			local items = {}
			for model_id, model in pairs(updated_provider.models) do
				-- Only show "Free" for opencode provider models with zero cost
				local is_free = provider.id == "opencode" and model.cost and model.cost.input == 0
				table.insert(items, {
					label = model.name or model_id,
					value = model_id,
					model = model,
					description = is_free and "Free" or nil,
				})
			end

			-- Sort alphabetically
			table.sort(items, function(a, b)
				return a.label < b.label
			end)

			menu.open({
				items = items,
				title = " Select model from " .. (provider.name or provider.id) .. " ",
				width = 50,
				searchable = true,
				on_select = function(item)
					actions.select_model({
						providerID = provider.id,
						modelID = item.value,
					}, { recent = true })
				end,
			})
		end)
	end)
end

-- Helper: Show OAuth auto dialog for device code flow (GitHub Copilot, etc.)
-- Shows URL, device code, and waits for user to complete auth in browser
---@param opts table { provider, method, method_index, authorization, device_code }
show_oauth_auto_dialog = function(opts)
	local float = require("opencode.ui.float")
	local Popup = require("nui.popup")
	local event = require("nui.utils.autocmd").event

	-- Ensure we're focused on the chat window
	local chat = require("opencode.ui.chat")
	if chat.focus then
		chat.focus()
	end

	local provider = opts.provider
	local method = opts.method
	local method_index = opts.method_index
	local authorization = opts.authorization
	local device_code = opts.device_code

	-- Get the chat window for positioning
	local target_win = vim.api.nvim_get_current_win()

	-- Calculate popup size relative to chat window
	-- Account for border (2 chars total width for border)
	local width = 55
	local height = 10

	local win_width = vim.api.nvim_win_get_width(target_win)
	local win_height = vim.api.nvim_win_get_height(target_win)
	local total_width = width + 2 -- border adds 2 to total width
	local row = math.floor((win_height - height) / 2)
	local col = math.max(0, math.floor((win_width - total_width) / 2))

	-- Create popup relative to chat window
	local popup = Popup({
		relative = { type = "win", winid = target_win },
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " " .. (method.label or "OAuth") .. " ",
				top_align = "center",
			},
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
	})

	popup:mount()

	local bufnr = popup.bufnr
	local is_closed = false

	-- Build content lines
	local lines = {
		"",
		"  Open the following URL in your browser:",
		"",
		"  " .. (authorization.url or ""),
		"",
	}

	if device_code then
		table.insert(lines, "  Enter this code: " .. device_code)
		table.insert(lines, "")
	end

	if authorization.instructions and not device_code then
		table.insert(lines, "  " .. authorization.instructions)
		table.insert(lines, "")
	end

	table.insert(lines, "  Waiting for authorization...")
	table.insert(lines, "")
	table.insert(lines, "  Press 'o' to open URL | 'c' to copy code | 'q' to cancel")

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- Apply highlights
	local function hl_line(line_nr, hl_group)
		local lt = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1] or ""
		vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, { end_col = #lt, hl_group = hl_group })
	end
	hl_line(1, "Comment") -- "Open the following..."
	hl_line(3, "String") -- URL
	if device_code then
		hl_line(5, "WarningMsg") -- Device code line
	end

	vim.bo[bufnr].modifiable = false

	-- Close function
	local function close()
		if is_closed then
			return
		end
		is_closed = true
		pcall(function()
			popup:unmount()
		end)
		float_context.focus_chat_if_visible()
	end

	-- Setup keymaps
	local keymap_opts = { buffer = bufnr, noremap = true, silent = true }

	-- Open URL
	vim.keymap.set("n", "o", function()
		if authorization.url then
			vim.ui.open(authorization.url)
		end
	end, keymap_opts)

	-- Copy code
	vim.keymap.set("n", "c", function()
		local code_to_copy = device_code or authorization.url or ""
		vim.fn.setreg("+", code_to_copy)
		vim.fn.setreg("*", code_to_copy)
		vim.notify("Copied to clipboard: " .. code_to_copy, vim.log.levels.INFO)
	end, keymap_opts)

	-- Cancel
	vim.keymap.set("n", "q", close, keymap_opts)
	vim.keymap.set("n", "<Esc>", close, keymap_opts)

	-- Auto-open URL in browser
	if authorization.url then
		vim.ui.open(authorization.url)
	end

	-- Start polling for OAuth completion in the background
	actions.oauth_callback(provider.id, method_index, nil, function(cb_err)
		vim.schedule(function()
			if is_closed then
				return
			end

			close()

			if cb_err then
				vim.notify("OAuth failed: " .. tostring(cb_err.message or cb_err), vim.log.levels.ERROR)
				return
			end

				actions.dispose_server(function()
				vim.notify("Connected to " .. (provider.name or provider.id), vim.log.levels.INFO)
				show_provider_models(provider)
			end)
		end)
	end)

	-- Close on buffer leave
	popup:on(event.BufLeave, function()
		vim.defer_fn(close, 100)
	end)

	return {
		close = close,
		popup = popup,
	}
end

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
	palette.register({
		id = "provider.connect",
		title = "Connect Provider",
		description = "Connect a new AI provider",
		category = "model",
		keybind = "<leader>op",
		action = function()
				-- Fetch both providers and auth methods
				actions.list_providers(function(err, response)
						if err then
						vim.schedule(function()
							vim.notify(
								"Failed to list providers: " .. tostring(err.message or err),
								vim.log.levels.ERROR
							)
						end)
						return
					end

						actions.get_provider_auth(function(auth_err, auth_methods)
							vim.schedule(function()
								if auth_err then
									vim.notify(
										"Failed to list provider auth methods: " .. tostring(auth_err.message or auth_err),
										vim.log.levels.ERROR
									)
									return
								end
							-- Response is { all: [...], default: {...}, connected: [...] }
							local provider_list = response and response.all or {}
							if #provider_list == 0 then
								vim.notify("No providers available", vim.log.levels.WARN)
								return
							end

							-- Auth methods is a map { provider_id: [{type, label}] }
							auth_methods = auth_methods or {}

							-- Build connected lookup set
							local connected_set = {}
							if response.connected then
								for _, cid in ipairs(response.connected) do
									connected_set[cid] = true
								end
							end

							-- Provider priority for sorting (like TUI)
							local provider_priority = {
								opencode = 0,
								anthropic = 1,
								["github-copilot"] = 2,
								openai = 3,
								google = 4,
							}

							-- Build items with priority for popular providers
							local items = {}
							for _, provider in ipairs(provider_list) do
								local is_connected = connected_set[provider.id] or false
								local priority = provider_priority[provider.id] or 99

								-- Add descriptions for popular providers (like TUI)
								local description = nil
								if provider.id == "opencode" then
									description = "(Recommended)"
								elseif provider.id == "anthropic" then
									description = "(Claude Max or API key)"
								elseif provider.id == "openai" then
									description = "(ChatGPT Plus/Pro or API key)"
								elseif is_connected then
									description = "Connected"
								end

								table.insert(items, {
									label = provider.name or provider.id,
									value = provider.id,
									provider = provider,
									description = description,
									priority = 100 - priority, -- Higher = better
									auth_methods = auth_methods[provider.id] or { { type = "api", label = "API key" } },
								})
							end

							-- Sort by priority
							table.sort(items, function(a, b)
								return a.priority > b.priority
							end)

							local menu = require("opencode.ui.menu")
							menu.open({
								items = items,
								title = " Connect a provider ",
								width = 55,
								searchable = true,
								on_select = function(item)
									local methods = item.auth_methods
									if #methods == 1 then
										connect_provider_with_method(item.provider, methods[1], 0)
										return
									end

									local method_items = {}
									for i, method in ipairs(methods) do
										table.insert(method_items, {
											label = method.label or method.type,
											value = i - 1, -- 0-indexed for API
											method = method,
										})
									end

									menu.open({
										items = method_items,
										title = " Select auth method ",
										searchable = false,
										sort = false,
										on_select = function(method_item)
											connect_provider_with_method(
												item.provider,
												method_item.method,
												method_item.value
											)
										end,
									})
								end,
							})
							end)
						end)
					end)
			end,
		})
	palette.register({
		id = "provider.disconnect",
		title = "Disconnect Provider",
		description = "Remove authentication from a provider",
		category = "model",
		action = function()
				actions.list_providers(function(err, response)
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
						-- Only show connected providers
						local connected_set = {}
						if response.connected then
							for _, cid in ipairs(response.connected) do
								connected_set[cid] = true
							end
						end

						local provider_list = response and response.all or {}
						local items = {}

						for _, provider in ipairs(provider_list) do
							if connected_set[provider.id] then
								table.insert(items, {
									label = provider.name or provider.id,
									value = provider.id,
									provider = provider,
									description = "Connected",
								})
							end
						end

						if #items == 0 then
							vim.notify("No connected providers to disconnect", vim.log.levels.INFO)
							return
						end

						local menu = require("opencode.ui.menu")
						menu.open({
							items = items,
							title = " Disconnect Provider ",
							width = 50,
							searchable = true,
							on_select = function(item)
								vim.ui.select({ "Yes", "No" }, {
									prompt = "Disconnect from " .. (item.provider.name or item.provider.id) .. "?",
								}, function(choice)
									if choice == "Yes" then
										actions.remove_provider_auth(item.provider.id, function(remove_err)
											vim.schedule(function()
												if remove_err then
													vim.notify(
														"Failed to disconnect: "
															.. tostring(remove_err.message or remove_err),
														vim.log.levels.ERROR
													)
													return
												end

												-- Remove all models from this provider from recent/favorite lists
												actions.remove_provider_models(item.provider.id)

												-- Dispose to refresh state
												actions.dispose_server(function()
													vim.notify(
														"Disconnected from " .. (item.provider.name or item.provider.id),
														vim.log.levels.INFO
													)
												end)
											end)
										end)
									end
								end)
							end,
						})
						end)
					end)
			end,
		enabled = function()
			-- Only enable if there are connected providers
			-- This is a simple check - could be made more accurate with async check
			return true
		end,
	})
end

return M
