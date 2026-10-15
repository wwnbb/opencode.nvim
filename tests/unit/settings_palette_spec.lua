local state, actions = require("opencode.state"), require("opencode.actions")
local menu, float = require("opencode.ui.menu"), require("opencode.ui.float")
local palette = require("opencode.ui.palette.settings")

describe("editor feature settings menu", function()
	local originals, menus, popup, calls, provider_options, notifications, providers
	local function find(items, value)
		for _, item in ipairs(items) do if vim.deep_equal(item.value, value) then return item end end
		error("Missing menu choice: " .. vim.inspect(value))
	end
	local function choose(id)
		palette.show()
		local main = menus[#menus]
		main.on_select(find(main.items, id))
		return menus[#menus]
	end
	local function save(value, scope)
		local choices = menus[#menus]
		choices.on_select(find(choices.items, value))
		local scopes = menus[#menus]
		scopes.on_select(find(scopes.items, scope))
	end
	before_each(function()
		state.reset()
		local config = vim.deepcopy(require("opencode.config").defaults)
		config.completion.model, config.completion.variant = { providerID = "p", modelID = "fast" }, "low"
		config.explanation.model, config.explanation.variant = { providerID = "p", modelID = "deep" }, "high"
		state.set_config(config)
		providers = { { id = "p", models = {
			fast = { name = "Fast model", variants = { none = {}, low = {} }, variant_order = { "none", "low" } },
			deep = { name = "Deep model", variants = { high = {} } },
		} } }
		originals = { open = menu.open, input = float.create_input_popup, providers = actions.get_config_providers,
			apply = actions.apply_setting, notify = vim.notify }
		menus, calls, notifications, popup, provider_options = {}, {}, {}, nil, nil
		menu.open = function(opts) menus[#menus + 1] = opts end
		float.create_input_popup = function(opts) popup = opts end
		actions.get_config_providers = function(callback, opts) provider_options = opts; callback(nil, { providers = providers }) end
		actions.apply_setting = function(...) calls[#calls + 1] = { ... }; return true end
		vim.notify = function(message) notifications[#notifications + 1] = message end
	end)
	after_each(function()
		menu.open, float.create_input_popup = originals.open, originals.input
		actions.get_config_providers, actions.apply_setting, vim.notify = originals.providers, originals.apply, originals.notify
		state.reset()
	end)

	it("shows readable values and routes model selection through the existing scope/action flow", function()
		local picker = choose("completion_model")
		assert.equals("Completion model: p/fast", find(menus[1].items, "completion_model").label)
		assert.equals("Explain reasoning: high", find(menus[1].items, "explanation_variant").label)
		assert.equals("Completion max lines: 12", find(menus[1].items, "completion_max_lines").label)
		assert.is_true(picker.searchable)
		assert.same({ directory = vim.fn.getcwd() }, provider_options)
		local model = { providerID = "p", modelID = "deep" }
		assert.equals("p/deep", find(picker.items, model).search_text)
		save(model, "cwd")
		assert.same({ "completion_model", model, "cwd", vim.fn.getcwd() }, calls[1])
		assert.equals("fast", state.get_config().completion.model.modelID)
	end)

	it("uses each feature's model variants and distinguishes Default from inheritance", function()
		local picker = choose("completion_variant")
		assert.same({ "Default", "none", "low", "Inherit default" }, vim.tbl_map(function(item) return item.label end, picker.items))
		assert.equals("Current", find(picker.items, "low").description)
		save(false, "global")
		assert.same({ "completion_variant", false, "global", vim.fn.getcwd() }, calls[1])
		picker = choose("explanation_variant")
		assert.same({ "Default", "high", "Inherit default" }, vim.tbl_map(function(item) return item.label end, picker.items))
		save(nil, "cwd")
		assert.same({ "explanation_variant", nil, "cwd", vim.fn.getcwd() }, calls[2])
	end)

	it("validates custom line limits and supports clearing the override", function()
		choose("completion_max_lines")
		assert.equals("12", popup.default)
		for _, value in ipairs({ "0", "-1", "1.5", "many", "inf" }) do popup.on_submit(value) end
		assert.equals(5, #notifications)
		assert.equals(1, #menus)
		popup.on_submit(" 8 ")
		menus[#menus].on_select(find(menus[#menus].items, "global"))
		assert.same({ "completion_max_lines", 8, "global", vim.fn.getcwd() }, calls[1])
		choose("completion_max_lines"); popup.on_submit(" ")
		menus[#menus].on_select(find(menus[#menus].items, "cwd"))
		assert.same({ "completion_max_lines", nil, "cwd", vim.fn.getcwd() }, calls[2])
	end)

	it("displays unconfigured models and custom options without changing them on a catalog error", function()
		local config = state.get_config()
		config.completion.model, config.completion.variant = nil, nil
		config.completion.options = { body = { reasoning_effort = "none" } }
		state.set_config(config)
		actions.get_config_providers = function(callback) callback({ message = "offline" }) end
		choose("completion_model")
		assert.equals("Completion model: Not configured", find(menus[1].items, "completion_model").label)
		assert.equals("Completion reasoning: Custom options", find(menus[1].items, "completion_variant").label)
		assert.equals(1, #menus)
		assert.equals(0, #calls)
		assert.matches("offline", notifications[1])
		assert.same(config, state.get_config())
	end)
end)
