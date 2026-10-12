describe("SSE transport callback ordering", function()
	local tcp = require("opencode.client.tcp_connection")
	local original_open, original_sse, sse, connections, received
	local connected_frame = 'data: {"type":"server.connected","data":{}}\n\n'
	local delta_frame = 'data: {"type":"session.text.delta","data":{"sessionID":"s","delta":"queued"}}\n\n'

	local function drain()
		local done = false
		vim.schedule(function() done = true end)
		assert.is_true(vim.wait(1000, function() return done end))
	end

	local function establish()
		assert.is_true(sse.connect())
		connections[#connections].opts.on_read(nil,
			"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" .. connected_frame)
		drain()
		assert.is_true(sse.is_connected())
		received = {}
		return connections[#connections]
	end

	before_each(function()
		original_open, original_sse = tcp.open, package.loaded["opencode.client.sse"]
		connections, received = {}, {}
		tcp.open = function(opts)
			local connection = { opts = opts, closed = false }
			function connection.close() connection.closed = true end
			function connection.stop_timeout() end
			connections[#connections + 1] = connection
			return connection
		end
		package.loaded["opencode.client.sse"] = nil
		sse = require("opencode.client.sse")
		sse.setup({ host = "127.0.0.1", port = 4096, reconnect = false })
		sse.on("*", function(kind, data) received[#received + 1] = { kind = kind, data = data } end)
	end)

	after_each(function()
		sse.clear_listeners()
		sse.disconnect()
		drain()
		tcp.open, package.loaded["opencode.client.sse"] = original_open, original_sse
	end)

	for _, response in ipairs({ { "200 OK", "text/html" }, { "403 Forbidden", "text/event-stream" } }) do
		it("drops queued body after rejecting " .. response[1] .. " with " .. response[2], function()
			assert.is_true(sse.connect())
			connections[1].opts.on_read(nil, "HTTP/1.1 " .. response[1]
				.. "\r\nContent-Type: " .. response[2] .. "\r\nContent-Length: " .. #delta_frame
				.. "\r\n\r\n" .. delta_frame)
			drain()
			assert.equals(2, #received)
			assert.equals("error", received[1].kind)
			assert.matches("SSE handshake failed", received[1].data)
			assert.equals("disconnected", received[2].kind)
			assert.is_false(sse.status().has_stream)
		end)
	end

	it("delivers a valid finite body after TCP closes before callbacks run", function()
		assert.is_true(sse.connect())
		local body = connected_frame .. delta_frame
		connections[1].opts.on_read(nil, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: "
			.. #body .. "\r\n\r\n" .. body)
		assert.is_true(connections[1].closed)
		assert.same({}, received)
		drain()
		assert.equals(4, #received)
		assert.equals("connected", received[1].kind)
		assert.equals("server.connected", received[2].kind)
		assert.equals("session.text.delta", received[3].kind)
		assert.equals("queued", received[3].data.delta)
		assert.equals("disconnected", received[4].kind)
		assert.is_false(sse.is_connected())
	end)

	it("disconnects immediately once and discards already queued data", function()
		local connection = establish()
		connection.opts.on_read(nil, delta_frame)
		sse.disconnect()
		assert.is_false(sse.is_connected())
		assert.is_false(sse.status().has_stream)
		assert.is_true(connection.closed)
		assert.equals(1, #received)
		assert.equals("disconnected", received[1].kind)
		sse.disconnect()
		drain()
		assert.equals(1, #received)
	end)

	it("preserves a replacement opened by a disconnected listener", function()
		local old = establish()
		sse.on("disconnected", function() assert.is_true(sse.connect()) end)
		sse.disconnect()
		assert.equals(2, #connections)
		assert.is_true(sse.status().has_stream)
		assert.is_true(old.closed)
		local replacement = connections[2]
		replacement.opts.on_read(nil, "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" .. connected_frame)
		drain()
		assert.is_true(sse.is_connected())
		assert.is_false(replacement.closed)
		assert.equals(3, #received)
		assert.equals("disconnected", received[1].kind)
		assert.equals("connected", received[2].kind)
		assert.equals("server.connected", received[3].kind)
	end)

	it("rejects invalid host and port without opening TCP or scheduling retries", function()
		for _, invalid in ipairs({ { host = "bad host" }, { port = -1 }, { port = 65536 } }) do
			sse.setup(vim.tbl_extend("force", { host = "127.0.0.1", port = 4096, reconnect = true }, invalid))
			local ok, err = sse.connect()
			assert.is_false(ok)
			assert.is_string(err)
			assert.equals(0, sse.status().reconnect_count)
			assert.is_false(sse.status().has_stream)
		end
		drain()
		assert.same({}, connections)
		assert.equals(3, #received)
		for _, event in ipairs(received) do assert.equals("error", event.kind) end
	end)
end)
