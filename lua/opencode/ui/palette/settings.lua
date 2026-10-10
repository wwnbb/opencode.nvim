local M = {}
local actions = require("opencode.actions")
local settings = require("opencode.settings")
local menu = require("opencode.ui.menu")

function M.show(context)
	context = context or {}
	local cwd = vim.fn.getcwd()
	local items = {}
	for _, setting in ipairs(settings.list(cwd)) do
		items[#items + 1] = { value = setting.id, label = setting.title .. ": " .. tostring(setting.value),
			description = setting.scope, setting = setting }
	end
	return menu.open({ title = " Settings ", searchable = true, width = 64, items = items, on_select = function(item)
		local choices = {}
		for _, value in ipairs(item.setting.values) do
			choices[#choices + 1] = { value = value, label = tostring(value) .. (value == item.setting.value and " (current)" or "") }
		end
		choices[#choices + 1] = { value = "inherit", label = "Inherit default", description = "Remove the chosen scope override" }
		menu.open({ title = " " .. item.setting.title .. " ", items = choices, width = 50, on_select = function(choice)
			menu.open({ title = " Save display preference ", width = 72, items = {
				{ value = "cwd", label = "This directory", description = cwd },
				{ value = "global", label = "All directories", description = "Directory overrides take precedence" },
			}, on_select = function(scope)
				local value = choice.value
				if value == "inherit" then value = nil end
				local ok, err = actions.apply_setting(item.value, value, scope.value, cwd)
				if not ok then vim.notify("OpenCode: " .. err, vim.log.levels.WARN) end
				M.show(context)
			end })
		end })
	end })
end

function M.register(palette)
	palette.register({ id = "action.settings", title = "Settings", category = "actions",
		description = "Display preferences for this directory or all directories", slash = { name = "settings" },
		run = M.show, on_select = function(context) return context.run() end })
end

return M
