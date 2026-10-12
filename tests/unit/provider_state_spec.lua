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
		assert.is_nil(record.listener)
		assert.is_nil(owner.get_attempt(record.id))
		assert.equals(replacement, owner.get_attempt(replacement.id))
		assert.is_true(owner.attempt_current(replacement))
		assert.equals("starting", replacement.status)
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
