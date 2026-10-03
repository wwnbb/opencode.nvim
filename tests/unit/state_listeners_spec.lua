describe("state listener dispatch", function()
	local state = require("opencode.state")
	before_each(function() state.clear_listeners(); state.reset() end)
	after_each(function() state.clear_listeners(); state.reset() end)

	it("snapshots named and wildcard listeners before callbacks mutate subscriptions", function()
		local calls, wildcard_calls = {}, 0
		local first
		first = function()
			calls[#calls + 1] = "first"
			state.off("danger_mode", first)
			state.on("danger_mode", function() calls[#calls + 1] = "new" end)
			state.on("*", function() wildcard_calls = wildcard_calls + 1 end)
		end
		state.on("danger_mode", first)
		state.on("danger_mode", function() calls[#calls + 1] = "second" end)
		state.set_danger_mode(true)
		assert.same({ "first", "second" }, calls)
		assert.equals(0, wildcard_calls)
		state.set_danger_mode(false)
		assert.same({ "first", "second", "second", "new" }, calls)
		assert.equals(1, wildcard_calls)
	end)

	it("delivers reset once using the wildcard callback signature", function()
		local calls = {}
		state.on("*", function(key, new, old)
			calls[#calls + 1] = { key = key, new = new, old = old }
		end)
		state.reset()
		assert.equals(1, #calls)
		assert.equals("*", calls[1].key)
		assert.is_table(calls[1].new)
		assert.is_table(calls[1].old)
	end)
end)

describe("local preference listener dispatch", function()
	local saved_local, local_state, sync, original_provider
	before_each(function()
		saved_local = package.loaded["opencode.local"]
		package.loaded["opencode.local"] = nil
		local_state = require("opencode.local")
		sync = require("opencode.sync")
		original_provider = sync.get_provider
		sync.get_provider = function() return { models = { one = {} } } end
	end)
	after_each(function()
		sync.get_provider = original_provider
		package.loaded["opencode.local"] = saved_local
	end)

	it("snapshots listeners that unsubscribe and subscribe during a change", function()
		local calls = {}
		local first
		first = function()
			calls[#calls + 1] = "first"
			local_state.off(first)
			local_state.on(function() calls[#calls + 1] = "new" end)
		end
		local_state.on(first)
		local_state.on(function() calls[#calls + 1] = "second" end)
		local model = { providerID = "p", modelID = "one" }
		local_state.model.toggle_favorite(model)
		assert.same({ "first", "second" }, calls)
		local_state.model.toggle_favorite(model)
		assert.same({ "first", "second", "second", "new" }, calls)
	end)
end)
