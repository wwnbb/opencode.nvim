describe("event bus unsubscription", function()
	local bus = require("opencode.events.bus")
	before_each(function() bus.clear(); bus.clear_history() end)
	after_each(function() bus.clear(); bus.clear_history() end)

	it("removes a once-only subscription before its first event", function()
		local calls = 0
		local callback = bus.once("ready", function() calls = calls + 1 end)
		bus.off("ready", callback)
		bus.emit("ready")
		assert.equals(0, calls)
		assert.equals(0, bus.listener_count("ready"))
	end)

	it("removes the matching regular and once listeners while preserving other subscribers", function()
		local removed, regular, once = 0, 0, 0
		local callback = function() removed = removed + 1 end
		bus.on("ready", callback)
		bus.once("ready", callback)
		bus.on("ready", function() regular = regular + 1 end)
		bus.once("ready", function() once = once + 1 end)
		bus.off("ready", callback)
		bus.emit("ready")
		bus.emit("ready")
		assert.equals(0, removed)
		assert.equals(2, regular)
		assert.equals(1, once)
	end)

	it("consumes once listeners before a nested emit and preserves new once listeners", function()
		local calls, next_calls = 0, 0
		bus.once("ready", function()
			calls = calls + 1
			if calls == 1 then bus.emit("ready") end
			bus.once("ready", function() next_calls = next_calls + 1 end)
		end)
		bus.emit("ready")
		assert.equals(1, calls)
		assert.equals(1, bus.listener_count("ready"))
		bus.emit("ready")
		assert.equals(1, next_calls)
		assert.equals(0, bus.listener_count("ready"))
	end)

	it("dispatches a stable snapshot when listeners unsubscribe and subscribe", function()
		local calls = {}
		local first
		first = bus.on("ready", function()
			calls[#calls + 1] = "first"
			bus.off("ready", first)
			bus.on("ready", function() calls[#calls + 1] = "new" end)
		end)
		bus.on("ready", function() calls[#calls + 1] = "second" end)
		bus.emit("ready")
		assert.same({ "first", "second" }, calls)
		bus.emit("ready")
		assert.same({ "first", "second", "second", "new" }, calls)
	end)
end)
