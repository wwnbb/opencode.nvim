describe("provider attempt cleanup", function()
	local owner, original

	before_each(function()
		original = package.loaded["opencode.provider.state"]
		package.loaded["opencode.provider.state"] = nil
		owner = require("opencode.provider.state")
		owner.set_identity_getter(function() return "server-one" end)
	end)

	after_each(function()
		owner.clear_attempts()
		package.loaded["opencode.provider.state"] = original
	end)

	it("preserves attempts started by a cleanup listener", function()
		local replacement, update
		local stopped, closed = 0, 0
		local record = owner.begin_attempt("old", "oauth", "/one", function(view)
			update = view
			replacement = owner.begin_attempt("new", "oauth", "/one")
		end)
		record.timer = {
			stop = function() stopped = stopped + 1 end,
			close = function() closed = closed + 1 end,
		}

		owner.clear_attempts()

		assert.equals("cancelled", update.status)
		assert.equals("Server connection changed", update.error)
		assert.equals(1, stopped)
		assert.equals(1, closed)
		assert.is_nil(record.timer)
		assert.is_nil(owner.get_attempt(record.id))
		assert.equals(replacement, owner.get_attempt(replacement.id))
		assert.is_true(owner.attempt_current(replacement))
	end)

	it("detaches attempts before a listener clears them again", function()
		local notifications = 0
		local registered, listener
		local record
		record = owner.begin_attempt("old", "oauth", "/one", function()
			notifications = notifications + 1
			registered, listener = owner.get_attempt(record.id), record.listener
			if notifications == 1 then owner.clear_attempts() end
		end)

		owner.clear_attempts()

		assert.equals(1, notifications)
		assert.is_nil(registered)
		assert.is_nil(listener)
	end)
end)

describe("pending provider credential marks", function()
	local provider_state, original_state_module

	before_each(function()
		provider_state = require("opencode.provider.state")
		provider_state.set_identity_getter(nil)
		provider_state.clear_all()
		original_state_module = package.loaded["opencode.state"]
	end)

	after_each(function()
		provider_state.set_identity_getter(nil)
		provider_state.clear_all()
		package.loaded["opencode.state"] = original_state_module
	end)

	it("scopes marks to the server endpoint and ignores pid changes", function()
		local server = { host = "localhost", port = 5000, pid = 111 }
		package.loaded["opencode.state"] = { get_server_info = function() return server end }
		provider_state.mark("provider-a")
		server.pid = 222
		assert.is_true(provider_state.is_pending("provider-a"))
		server.port = 6000
		assert.is_false(provider_state.is_pending("provider-a"))
		provider_state.mark("provider-b")
		assert.is_true(provider_state.is_pending("provider-b"))
	end)

	it("prunes pending providers only on their own endpoint", function()
		local endpoint = "localhost:5000"
		provider_state.set_identity_getter(function() return endpoint end)
		provider_state.mark("provider-a")
		local connected = { ["provider-a"] = true, ["provider-b"] = true }
		provider_state.prune_connected(connected)
		assert.is_nil(connected["provider-a"])
		assert.is_true(connected["provider-b"])
		endpoint = "localhost:6000"
		local other = { ["provider-a"] = true }
		provider_state.prune_connected(other)
		assert.is_true(other["provider-a"])
	end)

	it("is not cleared by transient cleanup", function()
		provider_state.set_identity_getter(function() return "localhost:5000" end)
		provider_state.mark("provider-a")
		require("opencode.cleanup").clear_transient({ reset_state = false, clear_chat = false })
		assert.is_true(provider_state.is_pending("provider-a"))
	end)
end)
