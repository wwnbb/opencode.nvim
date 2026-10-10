local state, sync = require("opencode.state"), require("opencode.sync")
local choices, pending = require("opencode.session.selection"), require("opencode.session.pending")
local locks, registry = require("opencode.session.lock"), require("opencode.command_registry")
local menu, actions = require("opencode.ui.menu"), require("opencode.actions")

describe("direct variant selection", function()
	local saved, local_state, opened, notifications
	before_each(function()
		saved = { local_state = package.loaded["opencode.local"], input = package.loaded["opencode.ui.input"],
			menu_open = menu.open, notify = vim.notify, command = registry.get("model.variant") }
		package.loaded["opencode.local"] = nil
		package.loaded["opencode.ui.input"] = { is_visible = function() return false end }
		local_state = require("opencode.local")
		state.reset(); sync.clear_all(); choices.clear_all(); pending.clear_all(); locks.clear_all()
		sync.handle_agents({ { id = "build", name = "Build" } })
		sync.handle_providers({ { id = "p", models = {
			one = { variants = { default = {}, fast = {}, high = {} }, variant_order = { "high", "fast", "default" } },
			two = { variants = {} },
		} } })
		state.upsert_session({ id = "s", agent = "build", model = { providerID = "p", id = "one", variant = "fast" } })
		state.set_session("s", "Session")
		opened, notifications = {}, {}
		menu.open = function(opts) opened[#opened + 1] = opts end
		vim.notify = function(message) notifications[#notifications + 1] = message end
		require("opencode.ui.palette.model").register({ register = function(record)
			if record.id == "model.variant" then registry.register(record) end
		end })
	end)
	after_each(function()
		menu.open, vim.notify = saved.menu_open, saved.notify
		package.loaded["opencode.local"], package.loaded["opencode.ui.input"] = saved.local_state, saved.input
		registry.unregister("model.variant")
		if saved.command then registry.register(saved.command) end
		state.reset(); sync.clear_all(); choices.clear_all(); pending.clear_all(); locks.clear_all()
	end)

	it("shares the picker between palette, slash aliases and immediate completion selection", function()
		local command = registry.get("model.variant")
		assert.equals(command, registry.get_slash("variants"))
		assert.equals(command, registry.get_slash("thinking"))
		assert.equals(command, registry.get_slash("effort"))
		assert.is_true(registry.select(command.id, { source = "completion" }))
		assert.equals(1, #opened)
		assert.same({ "default", "high", "fast" }, vim.tbl_map(function(item) return item.value end, opened[1].items))
		assert.is_false(opened[1].sort)
		assert.equals("Current", opened[1].items[3].description)
		assert.equals(1, opened[1].items[3].priority)
		opened[1].on_select(opened[1].items[2])
		assert.equals("high", local_state.variant.current())
		assert.is_true(registry.run(command.id, { source = "palette" }))
		assert.equals("Current", opened[2].items[2].description)
		opened[2].on_select(opened[2].items[1])
		assert.is_nil(local_state.variant.current())
		assert.is_nil(choices.current("s").model.variant)
		assert.equals("fast", state.get_session_record("s").model.variant)
	end)

	it("offers Default for a model without variants and clears the previous draft variant", function()
		assert.is_true(actions.select_variant("high"))
		local_state.model.set({ providerID = "p", modelID = "two", variant = "high" })
		assert.is_nil(local_state.variant.current())
		assert.is_nil(choices.current("s").model.variant)
		registry.run("model.variant")
		assert.equals(1, #opened[1].items)
		assert.equals("Current", opened[1].items[1].description)
	end)

	it("rejects a removed variant from an already open menu and preserves the native selection", function()
		registry.run("model.variant")
		sync.handle_providers({ { id = "p", models = { one = { variants = { fast = {} } } } } })
		opened[1].on_select(opened[1].items[2])
		assert.is_nil(choices.pending_values("s"))
		assert.equals("fast", local_state.variant.current())
		assert.matches("unavailable", notifications[1])
	end)

	it("does not apply an old menu after a model, session or connection change", function()
		local mutations = {
			function() local_state.model.set({ providerID = "p", modelID = "two" }) end,
			function() state.set_session("other", "Other") end,
			function() pending.invalidate() end,
		}
		for _, mutate in ipairs(mutations) do
			state.set_session("s", "Session"); choices.clear_all()
			registry.run("model.variant")
			local picker = opened[#opened]
			mutate()
			picker.on_select(picker.items[2])
			local chosen = choices.pending_values("s")
			assert.is_true(chosen == nil or chosen.variant == nil)
		end
	end)

	it("honors child execution locks even when they appear after the menu opens", function()
		registry.run("model.variant")
		locks.set("s", { model = { providerID = "p", modelID = "one" }, variant = "fast" })
		opened[1].on_select(opened[1].items[2])
		assert.is_nil(choices.pending_values("s"))
		assert.equals("fast", local_state.variant.current())
		assert.is_false(registry.run("model.variant"))
		assert.equals(1, #opened)
	end)

	it("keeps supported explicit model variants without mutating the caller", function()
		local supported = { providerID = "p", modelID = "one", variant = "high" }
		local unsupported = { providerID = "p", modelID = "two", variant = "high" }
		local_state.model.set(supported)
		assert.equals("high", local_state.variant.current())
		local_state.model.set(unsupported)
		assert.is_nil(local_state.variant.current())
		assert.equals("high", unsupported.variant)
	end)
end)
