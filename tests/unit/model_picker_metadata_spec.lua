local state, sync, actions = require("opencode.state"), require("opencode.sync"), require("opencode.actions")
local menu, pending, locks = require("opencode.ui.menu"), require("opencode.session.pending"), require("opencode.session.lock")

describe("model picker native metadata and groups", function()
	local saved, commands, picker, selected, favorites, recents
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all(); locks.clear_all()
		state.set_session("s", "Session")
		state.upsert_session({ id = "s", directory = "/project" }, { touch = false })
		local models = {
			fav = { name = "Favorite", cost_tiers = { { input = 0 } }, time = { released = 1776988800000 }, status = "deprecated" },
			recent = { name = "Recent", cost_tiers = { { input = 0 }, { input = 1 } }, time = { released = 1776988800000 } },
			free = { name = "Free model", cost_tiers = { { input = 0 } }, time = { released = 1776988800000 } },
			old = { name = "Old", cost_tiers = {}, time = { released = 1704067200000 } },
			hidden = { name = "Deprecated", status = "deprecated", time = { released = 0 } },
		}
		local providers = { { id = "p", models = models } }
		sync.handle_providers(providers)
		saved = { open = menu.open, providers = actions.get_config_providers, favorite = actions.model_favorites, recent = actions.model_recent,
			select = actions.select_model, toggle = actions.toggle_model_favorite, cycle = actions.cycle_model }
		favorites, recents, commands, selected = { { providerID = "p", modelID = "fav" } }, { { providerID = "p", modelID = "recent" } }, {}, {}
		menu.open = function(opts) picker = opts end
		actions.get_config_providers = function(callback) callback(nil, { providers = providers }) end
		actions.model_favorites = function() return favorites end
		actions.model_recent = function() return recents end
		actions.select_model = function(model) selected[#selected + 1] = model end
		actions.toggle_model_favorite = function() end
		require("opencode.ui.palette.model").register({ register = function(command) commands[command.id] = command end })
	end)
	after_each(function()
		menu.open, actions.get_config_providers = saved.open, saved.providers
		actions.model_favorites, actions.model_recent, actions.select_model, actions.toggle_model_favorite, actions.cycle_model = saved.favorite, saved.recent, saved.select, saved.toggle, saved.cycle
		state.reset(); sync.clear_all(); pending.clear_all(); locks.clear_all()
	end)
	it("orders Favorites, Recent and remaining models with Free/released/deprecated metadata from the catalog", function()
		commands["model.switch"].run()
		table.sort(picker.items, picker.sort)
		assert.same({ "fav", "recent", "free", "old" }, vim.tbl_map(function(item) return item.value end, picker.items))
		assert.equals("Favorites · Free · 2026-04-24 · Deprecated", picker.items[1].description)
		assert.equals("Recent · 2026-04-24", picker.items[2].description)
		assert.matches("Recent ·", picker.items[2].label)
		assert.equals("Connected · Free · 2026-04-24", picker.items[3].description)
		assert.equals("Connected · 2024-01-01", picker.items[4].description)
		picker.on_select(picker.items[2]); assert.same({ { providerID = "p", modelID = "recent" } }, selected)
	end)
	it("registers separate recent/favorite cycles and does not select from a stale or child-locked model picker", function()
		local cycles = {}
		actions.cycle_model = function(direction, opts) cycles[#cycles + 1] = { direction, opts.source } end
		commands["model.cycle.recent.next"].run(); commands["model.cycle.favorite.previous"].run()
		assert.same({ { 1, "recent" }, { -1, "favorite" } }, cycles)
		commands["model.switch"].run()
		pending.invalidate(); picker.on_select(picker.items[1]); assert.equals(0, #selected)
		commands["model.switch"].run()
		locks.set("s", { agent = "child", model = { providerID = "p", modelID = "fav" } })
		picker.on_select(picker.items[1]); assert.equals(0, #selected)
		assert.is_false(commands["model.switch"].run())
	end)
	it("ignores a model removed from the catalog after the list opened", function()
		commands["model.switch"].run()
		local item = picker.items[1]
		sync.handle_providers({ { id = "p", models = {} } })
		picker.on_select(item); assert.equals(0, #selected)
	end)
end)
