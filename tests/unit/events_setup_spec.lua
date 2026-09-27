describe("opencode event setup", function()
	local saved_modules, events, bus, client, original_on_event, sse_registrations, native_listeners

	before_each(function()
		-- Bridges retain module references and registration flags. Give each test
		-- real, fresh modules, then restore the previous graph after the test.
		saved_modules = {}
		for name, module in pairs(package.loaded) do
			if name == "opencode" or name:match("^opencode%.") then
				saved_modules[name] = module
				package.loaded[name] = nil
			end
		end
		events = require("opencode.events")
		bus = require("opencode.events.bus")
		client = require("opencode.client")
		original_on_event = client.on_event
		sse_registrations = 0
		client.on_event = function(event_type, callback)
			sse_registrations = sse_registrations + 1
			return original_on_event(event_type, callback)
		end
		events.setup()
		native_listeners = bus.listener_count("v2_event")
		assert.is_true(sse_registrations > 0)
		assert.is_true(native_listeners > 0)
	end)

	after_each(function()
		client.on_event = original_on_event
		require("opencode.client.sse").clear_listeners()
		bus.clear()
		bus.clear_history()
		for name in pairs(package.loaded) do
			if name == "opencode" or name:match("^opencode%.") then package.loaded[name] = nil end
		end
		for name, module in pairs(saved_modules) do package.loaded[name] = module end
	end)

	it("does not duplicate SSE or native listeners on repeated setup", function()
		local registrations = sse_registrations
		events.setup()
		assert.equals(registrations, sse_registrations)
		assert.equals(native_listeners, bus.listener_count("v2_event"))
	end)

	it("rebinds native handlers after bus.clear without duplicating SSE listeners", function()
		local registrations = sse_registrations
		bus.clear()
		assert.equals(0, bus.listener_count("v2_event"))
		events.setup()
		assert.equals(registrations, sse_registrations)
		assert.equals(native_listeners, bus.listener_count("v2_event"))
	end)
end)
