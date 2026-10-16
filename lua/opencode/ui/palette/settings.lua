local M = {}
local actions = require("opencode.actions")
local settings = require("opencode.settings")
local menu = require("opencode.ui.menu")
local groups = { completion = "Completion", explanation = "Explain" }

local function model_name(model)
	return model and (model.providerID .. "/" .. (model.modelID or model.id)) or "Not configured"
end

local function display(setting)
	if setting.kind == "model" then return model_name(setting.value) end
	if setting.kind == "variant" then
		if setting.value == "none" then return "No reasoning" end
		return setting.value or (setting.custom_options and "Custom options" or "Default")
	end
	return tostring(setting.value)
end

local function choose(setting, cwd, callback)
	if setting.kind == "integer" then
		return require("opencode.ui.float").create_input_popup({ title = " " .. setting.title .. " ",
			prompt = "Positive integer (empty inherits default):", default = tostring(setting.value), on_submit = function(input)
				input = vim.trim(input)
				local value = tonumber(input)
				if input ~= "" and (not value or value < 1 or value == math.huge or value % 1 ~= 0) then
					vim.notify("OpenCode: Max lines must be a positive integer", vim.log.levels.WARN)
					return
				end
				callback(value)
			end })
	end
	local function open(choices)
		local width = 64
		for _, choice in ipairs(choices) do
			local current = vim.deep_equal(choice.value, setting.value)
				or (setting.kind == "variant" and choice.value == false and not setting.value and not setting.custom_options)
			if current then choice.description = "Current" end
			width = math.max(width, vim.fn.strdisplaywidth(choice.label) + 14)
		end
		choices[#choices + 1] = { label = "Inherit default", description = "Remove the chosen scope override" }
		menu.open({ title = " " .. setting.title .. " ", items = choices, width = width,
			searchable = setting.kind == "model", on_select = function(choice)
				callback(choice.value)
			end })
	end
	if setting.kind == "model" or setting.kind == "variant" then
		return actions.get_config_providers(function(err, response)
			if err then
				vim.notify("Failed to list providers: " .. tostring(err.message or err), vim.log.levels.ERROR)
				return
			end
			local choices = {}
			if setting.kind == "model" then
				for _, provider in ipairs(response and response.providers or {}) do
					for id, model in pairs(provider.models or {}) do
						choices[#choices + 1] = { value = { providerID = provider.id, modelID = id },
							label = "[" .. provider.id .. "] " .. (model.name or id), search_text = provider.id .. "/" .. id }
					end
				end
			else
				choices[1] = { value = false, label = "Default" }
				local selected = setting.model
				for _, provider in ipairs(response and response.providers or {}) do
					if selected and provider.id == selected.providerID then
						local model = (provider.models or {})[selected.modelID or selected.id] or {}
						for _, name in ipairs(model.variant_order or vim.fn.sort(vim.tbl_keys(model.variants or {}))) do
							if name ~= "default" then
								choices[#choices + 1] = { value = name, label = name == "none" and "No reasoning" or name }
							end
						end
					end
				end
			end
			open(choices)
		end, { directory = cwd })
	end
	local choices = {}
	for _, value in ipairs(setting.values) do choices[#choices + 1] = { value = value, label = tostring(value) } end
	open(choices)
end

function M.show(context, group)
	context = context or {}
	local cwd = vim.fn.getcwd()
	local items = {}
	local width = 64
	for _, setting in ipairs(settings.list(cwd)) do
		local setting_group = groups[setting.path[1]] and setting.path[1] or nil
		if setting_group == group then
			items[#items + 1] = { value = setting.id, label = setting.title .. ": " .. display(setting),
				description = setting.scope, setting = setting }
			width = math.max(width, vim.fn.strdisplaywidth(items[#items].label) + 12)
		end
	end
	if group then
		items[#items + 1] = { value = "back", label = "Back to Settings", priority = -1 }
	else
		for id, title in pairs(groups) do
			items[#items + 1] = { value = id, label = title, description = "submenu", group = id }
		end
	end
	local title = group and (groups[group] .. " settings") or "Settings"
	return menu.open({ title = " " .. title .. " ", searchable = true, width = width, items = items, on_select = function(item)
		if not item.setting then return M.show(context, item.group) end
		choose(item.setting, cwd, function(value)
			menu.open({ title = " Save preference ", width = 72, items = {
				{ value = "cwd", label = "This directory", description = cwd },
				{ value = "global", label = "All directories", description = "Directory overrides take precedence" },
			}, on_select = function(scope)
				local ok, err = actions.apply_setting(item.value, value, scope.value, cwd)
				if not ok then vim.notify("OpenCode: " .. err, vim.log.levels.WARN) end
				M.show(context, group)
			end })
		end)
	end })
end

function M.register(palette)
	palette.register({ id = "action.settings", title = "Settings", category = "actions",
		description = "Preferences for this directory or all directories", slash = { name = "settings" },
		run = M.show, on_select = function(context) return context.run() end })
end

return M
