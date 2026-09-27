describe("v2 integration attempt ownership", function()
	local saved, names, calls, updates, timers, defer, auth, owner, pending
	before_each(function()
		names = { "opencode.provider.auth", "opencode.provider.state", "opencode.client", "opencode.events" }
		saved, calls, updates, timers = {}, {}, {}, {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		pending = require("opencode.session.pending"); pending.clear_all()
		owner = require("opencode.provider.state"); owner.set_identity_getter(function() return "server-one" end)
		package.loaded["opencode.client"] = {
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
end)
