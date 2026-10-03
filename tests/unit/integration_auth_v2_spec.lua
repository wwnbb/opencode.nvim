describe("v2 integration attempt ownership", function()
	local saved, names, calls, updates, timers, defer, auth, owner, pending, credential_calls, endpoint
	before_each(function()
		names = { "opencode.provider.auth", "opencode.provider.state", "opencode.client", "opencode.events" }
		saved, calls, updates, timers, credential_calls = {}, {}, {}, {}, {}
		endpoint = "server-one"
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		pending = require("opencode.session.pending"); pending.clear_all()
		owner = require("opencode.provider.state"); owner.set_identity_getter(function() return endpoint end)
		package.loaded["opencode.client"] = {
			credential = function(operation, id, body, cb)
				credential_calls[#credential_calls + 1] = { cb = cb }
			end,
			integration = function(operation, integration, body, opts, cb)
				calls[#calls + 1] = { operation = operation, integration = integration, body = body, opts = vim.deepcopy(opts), cb = cb }
			end,
		}
		package.loaded["opencode.events"] = { emit = function() end }
		defer = vim.defer_fn
		vim.defer_fn = function(fn)
			local timer = { fn = fn, stop = function(self) self.stopped = true end, close = function() end }
			timers[#timers + 1] = timer; return timer
		end
		auth = require("opencode.provider.auth")
	end)
	after_each(function()
		owner.clear_attempts(); vim.defer_fn = defer; pending.clear_all()
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	end)
	local function started()
		calls[1].cb(nil, { attemptID = "attempt-A", url = "https://example.invalid", instructions = "test", mode = "code", time = { expires = os.time() * 1000 + 60000 } })
	end
	local function begin(opts)
		return auth.start("integration-A", { id = "method-stable", type = "oauth" }, {}, opts or { directory = "/one" }, function(view) updates[#updates + 1] = view end)
	end
	it("freezes location/method and keeps codes out of observable state", function()
		local opts = { directory = "/one" }; local id = begin(opts); opts.directory = "/two"
		assert.equals("method-stable", calls[1].body.methodID)
		started(); auth.complete(id, "test-secret-code")
		assert.equals("/one", calls[2].opts.directory)
		assert.equals("attempt-A", calls[2].opts.attempt_id)
		assert.equals("test-secret-code", calls[2].body.code)
		assert.is_nil(owner.get_attempt(id).code)
		assert.is_nil(vim.inspect(updates):find("test-secret-code", 1, true))
		calls[2].cb(nil); timers[#timers].fn()
		assert.equals("oauth_status", calls[3].operation)
		calls[3].cb(nil, { status = "complete" })
		assert.equals("complete", updates[#updates].status)
	end)
	it("does not poll or discard the replacement timer when a stopped callback runs", function()
		local id = begin(); started()
		local old_timer = timers[1]
		auth.complete(id, "test-secret-code")
		assert.is_true(old_timer.stopped)
		old_timer.fn()
		assert.equals(2, #calls)
		assert.equals("submitting", owner.get_attempt(id).status)

		calls[2].cb(nil)
		local replacement = timers[2]
		old_timer.fn()
		assert.equals(2, #calls)
		assert.equals(replacement, owner.get_attempt(id).timer)
		assert.is_nil(replacement.stopped)
		replacement.fn()
		assert.equals("oauth_status", calls[3].operation)
		calls[3].cb(nil, { status = "complete" })
		assert.equals("complete", updates[#updates].status)
	end)
	it("cancels an attempt that was closed while creation was in flight", function()
		local id = begin(); auth.cancel(id)
		assert.equals(1, #calls)
		started()
		assert.equals("oauth_cancel", calls[2].operation)
		calls[2].cb(nil)
		assert.equals("cancelled", updates[#updates].status)
		assert.is_nil(owner.get_attempt(id))
	end)
	it("ignores stale callbacks after server generation changes", function()
		begin(); pending.invalidate(); started()
		assert.equals(0, #updates); assert.equals(0, #timers)
	end)
	it("does not reopen an attempt when an outstanding poll finishes after cancel", function()
		local id = begin(); started(); timers[1].fn()
		auth.cancel(id)
		calls[2].cb(nil, { status = "complete" })
		assert.equals("cancelling", updates[#updates].status)
		calls[3].cb(nil)
		assert.equals("cancelled", updates[#updates].status)
	end)
	it("bounds polling at expiry and discards untrusted failure messages", function()
		begin(); started(); timers[1].fn()
		calls[2].cb(nil, { status = "failed", message = "secret token echoed" })
		assert.equals("Authorization failed", updates[#updates].error)
		assert.is_nil(vim.inspect(updates):find("secret token", 1, true))
		owner.clear_attempts(); calls, timers = {}, {}; local id = begin(); started()
		owner.get_attempt(id).expires = 0; timers[1].fn()
		assert.equals("expired", updates[#updates].status)
		assert.equals("oauth_cancel", calls[2].operation)
	end)

	local function change(callback)
		auth.credential("update", "integration-A", "credential-A", { label = "Renamed" }, { directory = "/one" }, callback or function() end)
	end
	local credential_key = "integration-A\0credential-A"
	for _, phase in ipairs({ "write", "confirmation" }) do
		it("reconnects during credential " .. phase .. " without retaining or releasing another request's lock", function()
			local stale_error
			change(function(err) stale_error = err end)
			local stale_callback = credential_calls[1].cb
			if phase == "confirmation" then stale_callback(nil); stale_callback = calls[1].cb end
			pending.invalidate()
			change()
			assert.equals(2, #credential_calls)
			stale_callback(nil, { connections = {} })
			assert.equals("Server connection changed", stale_error.message)
			assert.is_true(owner.is_pending(credential_key))
			change()
			assert.equals(2, #credential_calls)
			credential_calls[2].cb(nil)
			calls[#calls].cb(nil, { connections = {} })
			assert.is_false(owner.is_pending(credential_key))
		end)
	end
	it("keeps a replacement credential lock when an old endpoint responds", function()
		change()
		endpoint = "server-two"; pending.invalidate()
		change()
		assert.equals(2, #credential_calls)
		credential_calls[1].cb(nil)
		assert.is_true(owner.is_pending(credential_key))
		change()
		assert.equals(2, #credential_calls)
	end)
	it("blocks duplicate credential changes until server confirmation completes", function()
		local confirmed
		change(function(err, result) assert.is_nil(err); confirmed = result end)
		change()
		assert.equals(1, #credential_calls)
		credential_calls[1].cb(nil)
		assert.equals("get", calls[1].operation)
		assert.is_true(owner.is_pending(credential_key))
		change()
		assert.equals(1, #credential_calls)
		local result = { connections = { { id = "credential-A", label = "Renamed" } } }
		calls[1].cb(nil, result)
		assert.equals(result, confirmed)
		assert.is_false(owner.is_pending(credential_key))
		change()
		assert.equals(2, #credential_calls)
	end)
	it("releases credential locks on write and confirmation failures", function()
		for _, phase in ipairs({ "write", "confirmation" }) do
			local received
			change(function(err) received = err end)
			local done = credential_calls[#credential_calls].cb
			if phase == "confirmation" then done(nil); done = calls[#calls].cb end
			local err = { message = "Request failed" }; done(err)
			assert.equals(err, received)
			assert.is_false(owner.is_pending(credential_key))
		end
		assert.equals(2, #credential_calls)
	end)
end)
