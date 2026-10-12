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
		native_listeners = bus.listener_count("server_event")
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
		assert.equals(native_listeners, bus.listener_count("server_event"))
	end)

	it("rebinds native handlers after bus.clear without duplicating SSE listeners", function()
		local registrations = sse_registrations
		bus.clear()
		assert.equals(0, bus.listener_count("server_event"))
		events.setup()
		assert.equals(registrations, sse_registrations)
		assert.equals(native_listeners, bus.listener_count("server_event"))
	end)

	it("invalidates pending operations whenever a connected state is lost", function()
		local state = require("opencode.state")
		local pending = require("opencode.session.pending")
		local sync = require("opencode.sync")
		local replies, disconnected = {}, 0
		for _, method in ipairs({ "get_session_statuses", "list_agents", "list_commands", "list_skills", "get_mcp_status", "get_config" }) do
			client[method] = function() end
		end
		client.get_config_providers = function(callback) replies[#replies + 1] = callback end
		events.on("disconnected", function() disconnected = disconnected + 1 end)
		for index, next_state in ipairs({ "error", "idle", "connecting", "starting" }) do
			state.set_connection("connected")
			local token = pending.token()
			state.set_connection(next_state)
			assert.is_false(pending.is_current(token))
			assert.equals(index, disconnected)
			replies[index](nil, { providers = { { id = "stale", models = {} } } })
			assert.is_nil(sync.get_location_catalog(state.normalize_directory(vim.fn.getcwd()), "providers"))
			state.set_connection("idle")
			assert.equals(index, disconnected)
		end
	end)
end)
