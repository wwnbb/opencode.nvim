describe("SSE connection recovery", function()
	local transport = require("opencode.client.transport")
	local saved_open, saved_sse, saved_timer, saved_closing, saved_now
	local sse, streams, timers, now, received

	local function drain()
		local done = false
		vim.schedule(function() done = true end)
		assert.is_true(vim.wait(1000, function() return done end))
	end
	local function advance(ms)
		now = now + ms
		for _, timer in ipairs(vim.list_slice(timers)) do
			if not timer.closed and timer.due <= now then
				timer.due = timer.repeat_ms > 0 and now + timer.repeat_ms or math.huge
				timer.fire()
			end
		end
		drain()
	end
	local function stream() return streams[#streams] end
	local function headers()
		stream().on_headers(200, { ["content-type"] = "text/event-stream" })
	end
	local function connect()
		headers()
		stream().on_data('data: {"type":"server.connected","data":{}}\n\n')
		assert.is_true(sse.is_connected())
	end

	before_each(function()
		saved_open, saved_sse = transport.open_stream, package.loaded["opencode.client.sse"]
		saved_timer, saved_closing, saved_now = vim.uv.new_timer, vim.uv.is_closing, vim.uv.now
		streams, timers, received, now = {}, {}, {}, 0
		vim.uv.now = function() return now end
		vim.uv.is_closing = function(timer) return timer.closed end
		vim.uv.new_timer = function()
			local timer = { closed = false }
			function timer:start(delay, repeat_ms, callback)
				self.delay, self.due, self.repeat_ms, self.fire = delay, now + delay, repeat_ms, callback
			end
			function timer:stop() self.due = math.huge end
			function timer:close() self.closed = true end
			timers[#timers + 1] = timer
			return timer
		end
		transport.open_stream = function(opts)
			streams[#streams + 1] = opts
			return { close = function() opts.on_close("closed") end }
		end
		package.loaded["opencode.client.sse"] = nil
		sse = require("opencode.client.sse")
		sse.setup({ port = 4096 })
		sse.on("*", function(kind, data) received[#received + 1] = { kind = kind, data = data } end)
		assert.is_true(sse.connect())
	end)
	after_each(function()
		sse.clear_listeners(); sse.disconnect()
		for _, timer in ipairs(timers) do assert.is_true(timer.closed) end
		transport.open_stream, package.loaded["opencode.client.sse"] = saved_open, saved_sse
		vim.uv.new_timer, vim.uv.is_closing, vim.uv.now = saved_timer, saved_closing, saved_now
	end)

	it("times out headers without server.connected even when comments keep arriving", function()
		headers()
		assert.is_false(sse.is_connected())
		assert.equals(0, #received)
		advance(9000)
		stream().on_data(": heartbeat\n\n")
		advance(1000)
		assert.is_false(sse.status().has_stream)
		assert.matches("waiting for server.connected", received[1].data)
		advance(5000)
		assert.equals(2, #streams)
	end)

	it("keeps an idle connection alive on heartbeat bytes then recovers after sleep", function()
		connect()
		for _ = 1, 4 do
			advance(15000)
			stream().on_data(": heart") -- Activity counts before a complete frame or accepted event.
			stream().on_data("beat\n\n")
		end
		assert.is_true(sse.is_connected())
		advance(45000)
		assert.is_false(sse.status().has_stream)
		assert.equals("SSE read-idle timeout", received[#received - 1].data)
		advance(5000)
		connect()
		assert.equals(2, #streams)
	end)

	it("retries past five outages with capped backoff and resets only on native connection", function()
		local expected = { 5000, 10000, 20000, 30000, 30000, 30000, 30000, 30000 }
		for attempt, delay in ipairs(expected) do
			stream().on_close("read_error")
			assert.equals(attempt, sse.status().reconnect_count)
			assert.equals(delay, timers[#timers].delay)
			advance(delay)
			assert.equals(attempt + 1, #streams)
		end
		headers()
		assert.equals(8, sse.status().reconnect_count)
		stream().on_data('data: {"type":"server.connected","data":{}}\n\n')
		assert.equals(0, sse.status().reconnect_count)
		stream().on_close("eof")
		assert.equals(5000, timers[#timers].delay)
	end)

	for _, status in ipairs({ 401, 403, 404, 204 }) do
		it("stops automatic retry for HTTP " .. status .. " until explicitly reconnected", function()
			stream().on_headers(status, { ["content-type"] = "text/event-stream" })
			advance(60000)
			assert.equals(1, #streams)
			assert.is_false(sse.status().has_stream)
			assert.equals(0, sse.status().reconnect_count)
			assert.is_true(sse.connect())
			connect()
		end)
	end
	for _, status in ipairs({ 408, 429, 500, 503 }) do
		it("retries temporary HTTP " .. status, function()
			stream().on_headers(status, {})
			advance(5000)
			assert.equals(2, #streams)
			connect()
		end)
	end
	it("stops retry for invalid stream content type and endpoint path", function()
		stream().on_headers(200, { ["content-type"] = "text/html" })
		advance(60000)
		assert.equals(1, #streams)
		sse.setup({ endpoint = "/invalid\npath" })
		assert.is_false(sse.connect())
		advance(60000)
		assert.equals(1, #streams)
	end)

	it("honors an explicitly bounded reconnect budget", function()
		sse.setup({ max_reconnects = 2 })
		for _, delay in ipairs({ 5000, 10000 }) do stream().on_close("eof"); advance(delay) end
		stream().on_close("eof")
		advance(60000)
		assert.equals(3, #streams)
		assert.matches("gave up after 2 attempts", received[#received].data)
	end)

	it("cancels reconnect and watchdog callbacks when disconnected or reconfigured", function()
		connect()
		local old_watchdog, old_stream = timers[#timers], stream()
		old_watchdog.fire() -- Callback is already queued, then the endpoint changes.
		sse.setup({ port = 4097 })
		assert.is_true(sse.connect())
		connect()
		drain()
		old_stream.on_close("stale close")
		old_stream.on_data(": heartbeat\n\n")
		assert.is_true(sse.is_connected())
		assert.equals(4097, stream().port)
		stream().on_close("eof")
		local reconnect = timers[#timers]
		reconnect.fire()
		sse.disconnect()
		drain(); advance(60000)
		assert.equals(2, #streams)
		assert.is_false(sse.status().has_stream)
		assert.equals(0, sse.status().reconnect_count)
	end)

	it("does not emit native connection after a local listener replaces its stream", function()
		sse.on("connected", function() sse.disconnect(); assert.is_true(sse.connect()) end)
		headers()
		stream().on_data('data: {"type":"server.connected","data":{}}\n\n')
		for _, event in ipairs(received) do assert.is_not.equals("server.connected", event.kind) end
		assert.equals(2, #streams)
		assert.is_false(sse.is_connected())
	end)
	it("resolves managed credentials on each retry and discards cancelled discovery", function()
		sse.disconnect()
		local callbacks, guards, cancelled = {}, {}, 0
		sse.setup({ resolve_endpoint = function(callback, guard)
			callbacks[#callbacks + 1], guards[#guards + 1] = callback, guard
			return { cancel = function() cancelled = cancelled + 1 end }
		end })
		assert.is_true(sse.connect()); assert.equals(1, #streams)
		callbacks[1](nil, { url = "https://host/proxy", auth = { username = "opencode", password = "first" } })
		assert.equals(2, #streams); assert.equals("https://host/proxy", stream().url)
		stream().on_close("eof"); advance(5000)
		assert.equals(2, #callbacks); assert.is_true(guards[2]())
		sse.disconnect(); assert.equals(1, cancelled); assert.is_false(guards[2]())
		callbacks[2](nil, { url = "https://stale" }); assert.equals(2, #streams)
		assert.is_true(sse.connect())
		callbacks[3](nil, { url = "https://new/proxy", auth = { username = "opencode", password = "second" } })
		assert.equals("https://new/proxy", stream().url); assert.is_truthy(stream().headers.Authorization)
	end)
	it("retries unavailable managed discovery but stops for auth and invalid configuration", function()
		sse.disconnect()
		local callbacks = {}
		sse.setup({ resolve_endpoint = function(callback) callbacks[#callbacks + 1] = callback end })
		sse.connect(); callbacks[1]({ message = "Unavailable", retryable = true }); advance(5000)
		assert.equals(2, #callbacks)
		callbacks[2]({ message = "Authentication failed", retryable = false }); advance(60000)
		assert.equals(2, #callbacks); assert.equals(1, #streams)
	end)
end)
