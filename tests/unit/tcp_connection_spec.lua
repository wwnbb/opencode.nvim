describe("TCP timeout ownership", function()
	local tcp = require("opencode.client.tcp_connection")
	local original_wrap, original_resolve, callbacks, connections
	before_each(function()
		original_wrap, original_resolve = vim.schedule_wrap, vim.uv.getaddrinfo
		callbacks, connections = {}, {}
		vim.schedule_wrap = function(callback)
			callbacks[#callbacks + 1] = callback
			return function() end
		end
		vim.uv.getaddrinfo = function() return {} end
	end)
	after_each(function()
		for _, connection in ipairs(connections) do connection.close() end
		vim.schedule_wrap, vim.uv.getaddrinfo = original_wrap, original_resolve
	end)

	it("keeps a connection alive when a queued timeout runs after cancellation", function()
		local errors = {}
		local connection = assert(tcp.open({
			host = "localhost", port = 1234, timeout = 1000,
			on_error = function(reason) errors[#errors + 1] = reason end,
		}))
		connections[#connections + 1] = connection
		local queued = callbacks[1]
		connection.stop_timeout() -- The stream cancels this timer when headers arrive.
		queued()
		assert.is_true(connection.is_active())
		assert.same({}, errors)
	end)

	it("still reports an active timeout exactly once", function()
		local errors = {}
		local connection = assert(tcp.open({
			host = "localhost", port = 1234, timeout = 1000,
			on_error = function(reason, err) errors[#errors + 1] = { reason, err.timeout } end,
		}))
		connections[#connections + 1] = connection
		callbacks[1]()
		callbacks[1]()
		assert.is_false(connection.is_active())
		assert.same({ { "timeout", true } }, errors)
	end)
end)

describe("TCP connection callbacks", function()
	local tcp, uv = require("opencode.client.tcp_connection"), vim.uv
	local connection, stubs, sockets, errors, reads, resolve
	local connect_errors, dns_start_error, read_start_error, write_start_error
	local addresses = { { addr = "::1", port = 1234 }, { addr = "127.0.0.1", port = 1234 }, { addr = "127.0.0.2" } }
	local function open()
		connection = assert(tcp.open({ host = "localhost", port = 1234, data = "request",
			on_read = function(err, data) reads[#reads + 1] = { err, data } end,
			on_error = function(reason, err) errors[#errors + 1] = { reason = reason, message = err.message } end,
		}))
	end
	before_each(function()
		connection, resolve = nil, nil
		stubs, sockets, errors, reads, connect_errors = {}, {}, {}, {}, {}
		dns_start_error, read_start_error, write_start_error = nil, nil, nil
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(uv, "getaddrinfo", function(_, _, _, callback)
			resolve = callback
			if dns_start_error then return nil, dns_start_error end
			return {}
		end)
		stubs[#stubs + 1] = stub(uv, "is_closing", function(socket) return socket.closed end)
		stubs[#stubs + 1] = stub(uv, "close", function(socket)
			socket.closed, socket.close_count = true, (socket.close_count or 0) + 1
		end)
		stubs[#stubs + 1] = stub(uv, "new_tcp", function()
			local socket = { writes = {}, write_callbacks = {} }
			sockets[#sockets + 1] = socket
			local connect_error = connect_errors[#sockets]
			function socket:connect(host, port, callback)
				self.target, self.connect_callback = { addr = host, port = port }, callback
				if connect_error then return nil, connect_error end
				return {}
			end
			function socket:read_start(callback)
				self.read_callback = callback
				if read_start_error then return nil, read_start_error end
				return 0
			end
			function socket:read_stop() end
			function socket:write(data, callback)
				self.writes[#self.writes + 1], self.write_callbacks[#self.write_callbacks + 1] = data, callback
				if write_start_error then return nil, write_start_error end
				return {}
			end
			return socket
		end)
	end)
	after_each(function()
		if connection then connection.close() end
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		for _, socket in ipairs(sockets) do assert.equals(1, socket.close_count) end
	end)

	it("tries the next DNS address after synchronous and asynchronous connect failures", function()
		connect_errors[1] = "EINVAL"
		open(); resolve(nil, addresses)
		assert.is_true(sockets[1].closed)
		sockets[2].connect_callback("ECONNREFUSED")
		assert.is_true(sockets[2].closed)
		sockets[3].connect_callback(nil)
		for index, socket in ipairs(sockets) do
			assert.equals(addresses[index].addr, socket.target.addr)
			assert.equals(1234, socket.target.port)
		end
		assert.equals(3, #sockets)
		assert.same({ "request" }, sockets[3].writes)
		assert.is_true(connection.is_active())
		assert.same({}, errors)
		connection.close()
		assert.is_true(sockets[3].closed)
	end)

	it("closes every socket and reports the final error when all addresses fail", function()
		connect_errors[1] = "EINVAL"
		open(); resolve(nil, { addresses[1], addresses[2] })
		sockets[2].connect_callback("ECONNREFUSED")
		assert.is_true(sockets[1].closed); assert.is_true(sockets[2].closed)
		assert.is_false(connection.is_active())
		assert.same({ { reason = "connect_error", message = "Connect failed: ECONNREFUSED" } }, errors)
	end)

	for _, kind in ipairs({ "start", "callback", "empty" }) do
		it("reports DNS " .. kind .. " failures without opening a socket", function()
			if kind == "start" then dns_start_error = "EINVAL" end
			open()
			if kind == "callback" then resolve("ENOTFOUND") elseif kind == "empty" then resolve(nil, {}) end
			assert.is_false(connection.is_active())
			assert.equals(1, #errors); assert.equals("resolve_error", errors[1].reason)
			assert.same({}, sockets)
		end)
	end

	it("closes the connection without writing when read_start fails", function()
		read_start_error = "EBADF"
		open(); resolve(nil, { addresses[1] }); sockets[1].connect_callback(nil)
		assert.same({}, sockets[1].writes)
		assert.is_true(sockets[1].closed)
		assert.is_false(connection.is_active())
		assert.same({ { reason = "read_start_error", message = "Failed to start read: EBADF" } }, errors)
	end)

	for _, operation in ipairs({ "initial", "send" }) do
		for _, kind in ipairs({ "start", "callback" }) do
			it("handles " .. operation .. " write " .. kind .. " failures once", function()
				open(); resolve(nil, { addresses[1] })
				if operation == "send" then sockets[1].connect_callback(nil) end
				if kind == "start" then write_start_error = "EPIPE" end
				if operation == "initial" then sockets[1].connect_callback(nil)
				else assert.equals(kind ~= "start", connection.send("next")) end
				local callback = sockets[1].write_callbacks[#sockets[1].write_callbacks]
				if kind == "callback" then callback("EPIPE") end
				callback("EPIPE")
				assert.is_true(sockets[1].closed)
				assert.is_false(connection.is_active())
				assert.is_false(connection.send("late"))
				assert.equals(1, #errors)
				assert.equals(kind == "start" and "write_start_error" or "write_error", errors[1].reason)
			end)
		end
	end

	for _, phase in ipairs({ "dns", "connect", "read" }) do
		it("ignores late " .. phase .. " callbacks after close", function()
			open()
			if phase ~= "dns" then resolve(nil, { addresses[1] }) end
			if phase == "read" then sockets[1].connect_callback(nil) end
			connection.close(); connection.close()
			if phase == "dns" then resolve(nil, addresses); assert.same({}, sockets)
			elseif phase == "connect" then
				sockets[1].connect_callback(nil); sockets[1].connect_callback("ECONNREFUSED"); assert.equals(1, #sockets)
			else sockets[1].read_callback(nil, "late"); sockets[1].write_callbacks[1]("EPIPE") end
			assert.is_false(connection.is_active())
			assert.same({}, reads); assert.same({}, errors)
			if sockets[1] then assert.is_true(sockets[1].closed) end
		end)
	end
end)
