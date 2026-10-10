describe("shared endpoint and verified TLS", function()
	local endpoint = require("opencode.client.endpoint")
	it("joins HTTP(S) base paths consistently and parses IPv6", function()
		local value = assert(endpoint.resolve({ url = "https://example.test:8443/proxy/" }))
		assert.equals("https", value.scheme); assert.equals(8443, value.port)
		assert.equals("/proxy/api/event", endpoint.join(value, "/api/event"))
		assert.equals("https://example.test:8443/proxy/api/info", endpoint.url(value, "/api/info"))
		value = assert(endpoint.resolve({ url = "https://[::1]/prefix" }))
		assert.equals("::1", value.host); assert.equals(443, value.port)
		assert.equals("https://[::1]:443/prefix/api", endpoint.url(value, "/api"))
		assert.equals(4096, assert(endpoint.resolve({ host = "localhost", port = 4096 })).port)
	end)
	it("rejects userinfo, unsupported schemes and request injection", function()
		for _, url in ipairs({ "ftp://host", "https://user:secret@host", "https://host?q=1", "https://host#f", "https://host/a\r\nHeader:x", "https://host/\1", "https://host:abc", "https://host:65536" }) do
			local value, err = endpoint.resolve({ url = url }); assert.is_nil(value, url); assert.is_false(err.retryable)
			assert.is_nil(err.message:find("secret", 1, true))
		end
	end)
	local original_system, original_executable, original_timer, original_module
	local tls, argv, options, exit, process, writes, killed, timers, errors, received
	before_each(function()
		original_system, original_executable, original_timer = vim.system, vim.fn.executable, vim.uv.new_timer
		original_module = package.loaded["opencode.client.tls_connection"]
		writes, killed, timers, errors, received = {}, 0, {}, {}, {}
		vim.fn.executable = function() return 1 end
		vim.uv.new_timer = function()
			local timer = {}; timers[#timers + 1] = timer
			function timer:start(_, _, callback) self.callback = callback end
			function timer:is_closing() return self.closed or false end
			function timer:stop() self.stopped = true end
			function timer:close() self.closed = true end
			return timer
		end
		process = { write = function(_, data) writes[#writes + 1] = data or "EOF" end, kill = function() killed = killed + 1 end }
		vim.system = function(args, opts, callback) argv, options, exit = args, opts, callback; return process end
		package.loaded["opencode.client.tls_connection"] = nil
		tls = require("opencode.client.tls_connection")
	end)
	after_each(function()
		vim.system, vim.fn.executable, vim.uv.new_timer = original_system, original_executable, original_timer
		package.loaded["opencode.client.tls_connection"] = original_module
	end)
	local function open(extra)
		return tls.open(vim.tbl_extend("force", { host = "example.test", port = 443, timeout = 100,
			data = "Authorization: Basic private-test-value\r\n\r\n",
			on_read = function(_, data) received[#received + 1] = data or "EOF" end,
			on_error = function(_, err) errors[#errors + 1] = err end }, extra or {}))
	end
	it("verifies certificates and hostname while sending credentials over stdin only", function()
		local connection = assert(open({ tls = { ca_file = "/tmp/private-ca.pem" } }))
		assert.is_true(vim.tbl_contains(argv, "-verify_return_error")); assert.is_true(vim.tbl_contains(argv, "-verify_hostname"))
		assert.is_true(vim.tbl_contains(argv, "/tmp/private-ca.pem")); assert.is_nil(table.concat(argv, " "):find("private-test-value", 1, true))
		assert.matches("private%-test%-value", writes[1]); assert.is_true(options.stdin)
		options.stdout(nil, "one"); connection.send("two"); assert.equals("two", writes[2])
		assert.same({ "one" }, received); connection.close(); connection.close(); assert.equals(1, killed)
		assert.is_true(timers[1].closed); options.stdout(nil, "stale"); exit({ code = 1 }); assert.equals(1, #received); assert.equals(0, #errors)
	end)
	it("uses IP verification and supports long-lived connections without a deadline", function()
		local connection = assert(open({ host = "::1", timeout = 0 }))
		assert.is_true(vim.tbl_contains(argv, "-verify_ip")); assert.is_true(vim.tbl_contains(argv, "[::1]:443"))
		assert.equals(0, #timers); exit({ code = 0 }); assert.same({ "EOF" }, received); assert.is_false(connection.is_active())
	end)
	it("treats bad certificates as terminal and avoids leaking subprocess diagnostics", function()
		open(); options.stderr(nil, "certificate verify failed private-test-value"); exit({ code = 1 })
		assert.equals("tls_verification_failed", errors[1].code); assert.is_false(errors[1].retryable)
		assert.is_nil(errors[1].message:find("private-test-value", 1, true))
	end)
	it("keeps network failures retryable and cancels expired callbacks", function()
		local connection = assert(open()); options.stderr(nil, "connection refused"); exit({ code = 1 })
		assert.is_true(errors[1].retryable); assert.is_false(connection.is_active()); assert.is_true(timers[1].closed)
		connection = assert(open()); local timer = timers[2]; connection.stop_timeout(); timer.callback()
		vim.wait(10, function() return false end); assert.is_true(connection.is_active()); connection.close()
	end)
	it("reports unsupported TLS runtime before any process is started", function()
		vim.fn.executable = function() return 0 end
		local connection, err = open(); assert.is_nil(connection); assert.equals("tls_unavailable", err.code); assert.is_false(err.retryable)
	end)
end)
