describe("model cycling", function()
	local state, sync = require("opencode.state"), require("opencode.sync")
	local choices = require("opencode.session.selection")
	local saved_local, local_state
	local function model(id) return { providerID = "p", modelID = id } end
	local function reset()
		package.loaded["opencode.local"] = nil
		local_state = require("opencode.local")
		state.reset(); sync.clear_all(); choices.clear_all()
		sync.handle_agents({ { id = "build", name = "Build" } })
		sync.handle_providers({ { id = "p", models = { outside = {}, first = {}, second = {}, third = {} } } })
		state.upsert_session({ id = "s", agent = "build", model = { providerID = "p", id = "outside" } })
		state.set_session("s", "Session")
	end
	before_each(function() saved_local = package.loaded["opencode.local"]; reset() end)
	after_each(function()
		state.reset(); sync.clear_all(); choices.clear_all()
		package.loaded["opencode.local"] = saved_local
	end)

	it("enters favorites and recents at the correct end, including a single model", function()
		for _, source in ipairs({ "favorite", "recent" }) do
			for _, ids in ipairs({ { "first" }, { "first", "second", "third" } }) do
				for _, direction in ipairs({ 1, -1 }) do
					reset()
					for i = #ids, 1, -1 do
						if source == "favorite" then local_state.model.toggle_favorite(model(ids[i]))
						else local_state.model.set(model(ids[i]), { recent = true, silent = true }) end
					end
					choices.clear_all() -- Restore the native model outside the cycling list.
					local_state.model.cycle(direction, { silent = true })
					assert.equals(direction == 1 and ids[1] or ids[#ids], local_state.model.current().modelID)
				end
			end
		end
	end)

	it("can choose a favorite when no current model exists", function()
		state.reset()
		local_state.model.toggle_favorite(model("first"))
		assert.is_nil(local_state.model.current())
		local_state.model.cycle(1, { silent = true })
		assert.equals("first", local_state.model.current().modelID)
	end)

	it("wraps in both directions and preserves the variant for an already selected single model", function()
		local_state.model.toggle_favorite(model("third"))
		local_state.model.toggle_favorite(model("second"))
		local_state.model.toggle_favorite(model("first"))
		local_state.model.set(model("third"), { silent = true })
		local_state.model.cycle(1, { silent = true })
		assert.equals("first", local_state.model.current().modelID)
		local_state.model.cycle(-1, { silent = true })
		assert.equals("third", local_state.model.current().modelID)
		local_state.model.toggle_favorite(model("first"))
		local_state.model.toggle_favorite(model("second"))
		local_state.variant.set("fast")
		local_state.model.cycle(1, { silent = true })
		assert.equals("third", local_state.model.current().modelID)
		assert.equals("fast", choices.current("s").variant)
	end)
end)
