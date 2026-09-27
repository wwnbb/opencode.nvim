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
end)
