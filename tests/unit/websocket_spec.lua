describe("native WebSocket transport", function()
	local websocket, stubs, wire, sent, messages, errors, closed, stopped
	local tcp = require("opencode.client.tcp_connection")
	local function server_frame(opcode, data, fin)
		local length = #data
		return string.char((fin == false and 0 or 128) + opcode, length < 126 and length or 126)
			.. (length >= 126 and string.char(math.floor(length / 256), length % 256) or "") .. data
	end
	local function open(overrides)
		local socket, err = websocket.open(vim.tbl_extend("force", { host = "127.0.0.1", port = 4096, path = "/api/pty/connect",
			on_message = function(opcode, data) messages[#messages + 1] = { opcode, data } end,
			on_error = function(error) errors[#errors + 1] = error end,
			on_close = function(reason) closed[#closed + 1] = reason end }, overrides or {}))
		assert.is_nil(err); return socket
	end
	local function upgrade(extra)
		wire.on_read(nil, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n" .. (extra or ""))
	end
	local function payload(frame)
		local length, offset = bit.band(frame:byte(2), 127), 3
		if length == 126 then length, offset = frame:byte(3) * 256 + frame:byte(4), 5
		elseif length == 127 then length, offset = frame:byte(7) * 16777216 + frame:byte(8) * 65536 + frame:byte(9) * 256 + frame:byte(10), 11 end
		local result = {}
		for index = 1, length do result[index] = string.char(bit.bxor(frame:byte(offset + 3 + index), frame:byte(offset + (index - 1) % 4))) end
		return table.concat(result)
	end
	before_each(function()
		wire = nil
		stubs, sent, messages, errors, closed, stopped = {}, {}, {}, {}, {}, 0
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(vim, "schedule", function(fn) fn() end)
		stubs[#stubs + 1] = stub(vim.uv or vim.loop, "random", function(size) return size == 16 and "the sample nonce" or "\1\2\3\4" end)
		stubs[#stubs + 1] = stub(tcp, "open", function(opts)
			wire = opts
			return { close = function() end, stop_timeout = function() stopped = stopped + 1 end, send = function(data) sent[#sent + 1] = data; return true end }
		end)
		package.loaded["opencode.client.websocket"] = nil
		websocket = require("opencode.client.websocket")
	end)
	after_each(function()
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		package.loaded["opencode.client.websocket"] = nil
	end)
	it("verifies the RFC handshake SHA-1 and decodes output split across network chunks", function()
		local socket = open()
		assert.truthy(wire.data:find("Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==", 1, true))
		upgrade(); assert.equals(1, stopped)
		local frame = server_frame(2, "Привет\27[31m")
		wire.on_read(nil, frame:sub(1, 5)); assert.equals(0, #messages)
		wire.on_read(nil, frame:sub(6)); assert.same({ { 2, "Привет\27[31m" } }, messages)
		assert.is_true(socket.is_active())
	end)
	it("rejects malformed paths before resolving the endpoint or opening a channel", function()
		for _, path in ipairs({ false, 12, {}, "", "/bad\r\npath" }) do
			local socket, err = websocket.open({ host = "localhost", port = 4096, path = path })
			assert.is_nil(socket); assert.equals("Invalid WebSocket path", err.message)
		end
		local socket, err = websocket.open({ host = "localhost", port = 4096 })
		assert.is_nil(socket); assert.equals("Invalid WebSocket path", err.message)
		assert.is_nil(wire)
	end)
	it("masks every client binary frame and handles extended input lengths", function()
		local socket = open(); upgrade()
		for _, text in ipairs({ "input\r", string.rep("x", 200), string.rep("y", 65536) }) do
			assert.is_true(socket.send(text))
			assert.equals(130, sent[#sent]:byte(1)); assert.equals(128, bit.band(sent[#sent]:byte(2), 128))
			assert.equals(text, payload(sent[#sent]))
		end
	end)
	it("assembles fragmented messages while responding to ping without interrupting replay", function()
		open(); upgrade(server_frame(2, "part one", false) .. server_frame(9, "ping") .. server_frame(0, " / part two"))
		assert.same({ { 2, "part one / part two" } }, messages)
		assert.equals(138, sent[1]:byte(1)); assert.equals("ping", payload(sent[1]))
	end)
	it("rejects a forged handshake and an unavailable upgrade without parsing response bodies", function()
		open(); wire.on_read(nil, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Accept: forged\r\n\r\n")
		assert.equals("websocket_protocol", errors[1].code)
		open(); wire.on_read(nil, "HTTP/1.1 403 Forbidden\r\nContent-Type: text/html\r\n\r\nsecret server page")
		assert.equals(403, errors[2].status)
		assert.is_nil(errors[2].message:find("secret", 1, true))
	end)
	it("rejects masks, invalid continuations, fragmented control and oversized replay frames", function()
		for _, bad in ipairs({ "\130\129", server_frame(0, "orphan"), server_frame(9, "ping", false), "\130\127\0\0\0\0\0\128\0\1" }) do
			local socket = open(); upgrade(); wire.on_read(nil, bad)
			assert.is_false(socket.is_active())
		end
		assert.equals(4, #errors)
	end)
	it("closes once, masks the close reply and ignores late bytes after detach", function()
		local socket = open(); upgrade(server_frame(8, "\3\232"))
		assert.equals(136, sent[1]:byte(1)); assert.equals("\3\232", payload(sent[1]))
		socket.close(); wire.on_read(nil, server_frame(2, "late"))
		assert.equals(1, #closed); assert.equals(0, #messages)
	end)
	it("uses the shared verified TLS channel, URL base path and Basic auth", function()
		stubs[#stubs + 1] = require("luassert.stub")(require("opencode.client.tls_connection"), "open", function(opts)
			wire = opts; return { close = function() end, stop_timeout = function() end, send = function() return true end }
		end)
		open({ url = "https://example.test/prefix", auth = { username = "user", password = "public-test-only" }, tls = { ca_file = "/test/ca" } })
		assert.equals("example.test", wire.host); assert.equals(443, wire.port)
		assert.same({ ca_file = "/test/ca" }, wire.tls)
		assert.truthy(wire.data:find("GET /prefix/api/pty/connect HTTP/1.1", 1, true))
		assert.truthy(wire.data:find("Authorization: Basic ", 1, true))
		assert.is_nil(wire.data:find("public-test-only", 1, true))
	end)
end)
