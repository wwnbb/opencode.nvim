describe("opencode native v2 SSE parser", function()
	local transport = require("opencode.client.transport")
	local original_open, original_sse, original_timer, original_is_closing, sse, stream, received

	local function envelope(id, value)
		return {
			id = id,
			created = 1,
			type = "session.text.delta",
			location = { directory = vim.fn.getcwd() },
			data = { sessionID = "sse-session", delta = value },
		}
	end

	before_each(function()
		original_open = transport.open_stream
		original_timer = vim.uv.new_timer
		original_is_closing = vim.uv.is_closing
		original_sse = package.loaded["opencode.client.sse"]
		package.loaded["opencode.client.sse"] = nil
		transport.open_stream = function(opts)
			stream = opts
			return { close = function() opts.on_close("closed") end }
		end
		sse = require("opencode.client.sse")
		sse.setup({ reconnect = false })
		received = {}
		sse.on("*", function(kind, data, id)
			table.insert(received, { kind = kind, data = data, id = id })
		end)
		assert.is_true(sse.connect())
	end)

	after_each(function()
		sse.clear_listeners()
		sse.disconnect()
		transport.open_stream = original_open
		vim.uv.new_timer = original_timer
		vim.uv.is_closing = original_is_closing
		package.loaded["opencode.client.sse"] = original_sse
	end)

	for _, separator in ipairs({ ":", ": " }) do
		it("reads native envelopes split at every byte using " .. vim.inspect(separator), function()
			local frame = "event" .. separator .. "message\r\nid" .. separator .. "frame-123\r\ndata: "
				.. vim.json.encode(envelope("event-123", "chunk")) .. "\r\n\r\n"
			for index = 1, #frame do stream.on_data(frame:sub(index, index)) end
			assert.equals(1, #received)
			assert.equals("session.text.delta", received[1].kind)
			assert.equals("event-123", received[1].id)
			assert.equals("chunk", received[1].data.delta)
			assert.equals("event-123", received[1].data._v2_envelope.id)
		end)
	end

	it("joins multiline JSON data and retains later fields", function()
		local frame = ': comment\ndata: {"type":"session.text.delta",\ndata:  "data":{"sessionID":"sse-session","delta":"two"}}\nid: frame-last\n'
		stream.on_data(frame)
		assert.equals(0, #received)
		stream.on_data("\n")
		assert.equals("session.text.delta", received[1].kind)
		assert.equals("frame-last", received[1].id)
		assert.equals("two", received[1].data.delta)
	end)

	it("ignores invalid frame IDs and empty fields", function()
		local frame = "event: ignored\nevent\nid: valid\nid: bad\0id\ndata: "
			.. vim.json.encode(envelope("event-valid", "first")) .. "\n\n"
		stream.on_data(frame)
		assert.equals("event-valid", received[1].id)
		stream.on_data("id: old\nid:\ndata: " .. vim.json.encode(envelope(nil, "next")) .. "\n\n")
		assert.equals("session.text.delta", received[2].kind)
		assert.is_nil(received[2].id)
	end)

	it("deduplicates native event IDs across reconnects", function()
		local named = {}
		sse.on("session.text.delta", function(data, id)
			named[#named + 1] = { data = data, id = id }
		end)
		local frame = "data: " .. vim.json.encode(envelope("unique", "once")) .. "\n\n"
		stream.on_data(frame .. frame)
		assert.equals(1, #received)
		assert.equals(1, #named)
		assert.equals("unique", named[1].id)
		assert.equals("once", named[1].data.delta)
		assert.equals("session.text.delta", named[1].data._v2_envelope.type)
		assert.equals(vim.fn.getcwd(), named[1].data._directory)
		sse.setup({ reconnect_delay = 10 })
		assert.is_true(sse.status().has_stream)
		stream.on_data(frame)
		assert.equals(1, #received)
		sse.disconnect()
		assert.is_true(sse.connect())
		stream.on_data(frame)
		assert.equals(1, #received)
		assert.equals(1, #named)
	end)

	it("does not deduplicate event IDs belonging to different servers", function()
		local frame = "data: " .. vim.json.encode(envelope("server-local-id", "first")) .. "\n\n"
		stream.on_data(frame)
		assert.equals(1, #received)
		local old_stream = stream
		sse.setup({ port = 4999 })
		assert.is_false(sse.status().has_stream)
		assert.is_true(sse.connect())
		assert.equals(4999, stream.port)
		received = {}
		old_stream.on_data(frame)
		assert.equals(0, #received)
		stream.on_data(frame)
		assert.equals(1, #received)
	end)

	it("rejects old properties and syncEvent envelopes", function()
		stream.on_data('data: {"payload":{"type":"message.updated","properties":{}}}\n\n')
		stream.on_data('data: {"payload":{"type":"sync","syncEvent":{}}}\n\n')
		stream.on_data('data: {"type":"message.updated","properties":{}}\n\n')
		assert.equals(3, #received)
		assert.equals("error", received[1].kind)
		assert.equals("error", received[2].kind)
		assert.equals("error", received[3].kind)
	end)

	it("dispatches a stable named and wildcard listener snapshot", function()
		local calls, late_wildcards = {}, 0
		local first
		first = function()
			calls[#calls + 1] = "first"
			sse.off("session.text.delta", first)
			sse.on("session.text.delta", function() calls[#calls + 1] = "new" end)
			sse.on("*", function() late_wildcards = late_wildcards + 1 end)
		end
		sse.on("session.text.delta", first)
		sse.on("session.text.delta", function() calls[#calls + 1] = "second" end)
		sse.emit("message", envelope("snapshot-1", "one"))
		assert.same({ "first", "second" }, calls)
		assert.equals(0, late_wildcards)
		sse.emit("message", envelope("snapshot-2", "two"))
		assert.same({ "first", "second", "second", "new" }, calls)
		assert.equals(1, late_wildcards)
	end)

	it("resets unfinished fields when connecting a new stream", function()
		stream.on_data("event: abandoned\nid: old\n")
		sse.disconnect()
		assert.is_true(sse.connect())
		received = {}
		stream.on_data("data: " .. vim.json.encode(envelope(nil, "next")) .. "\n\n")
		assert.equals("session.text.delta", received[1].kind)
		assert.is_nil(received[1].id)
	end)

	it("discards an event closed before its blank-line delimiter", function()
		local frame = "data: " .. vim.json.encode(envelope("interrupted", "partial")) .. "\n"
		stream.on_data(frame)
		stream.on_close("eof")
		assert.equals(1, #received)
		assert.equals("disconnected", received[1].kind)
		assert.is_true(sse.connect())
		received = {}
		stream.on_data(frame .. "\n")
		assert.equals(1, #received)
		assert.equals("partial", received[1].data.delta)
	end)

	it("rejects responses that are not a successful event stream", function()
		for _, response in ipairs({
			{ 200, {} }, { 200, { ["content-type"] = "text/html" } },
			{ 200, { ["content-type"] = "application/json" } },
			{ 200, { ["content-type"] = "text/event-streaming" } },
			{ 201, { ["content-type"] = "text/event-stream" } },
			{ 204, { ["content-type"] = "text/event-stream" } },
			{ 206, { ["content-type"] = "text/event-stream" } },
			{ 500, { ["content-type"] = "text/event-stream" } },
		}) do
			assert.is_true(sse.connect())
			received = {}
			local rejected = stream
			rejected.on_headers(response[1], response[2])
			assert.is_false(sse.is_connected())
			assert.is_false(sse.status().has_stream)
			assert.equals("error", received[1].kind)
			assert.matches("SSE handshake failed", received[1].data)
			assert.equals("disconnected", received[2].kind)
			rejected.on_data("data: " .. vim.json.encode(envelope("rejected", "ignored")) .. "\n\n")
			assert.equals(2, #received)
		end
	end)

	it("keeps a replacement stream opened by a handshake-error listener", function()
		local rejected = stream
		sse.on("error", function()
			sse.disconnect()
			assert.is_true(sse.connect())
		end)
		rejected.on_headers(200, { ["content-type"] = "text/html" })
		assert.is_not.equals(rejected, stream)
		assert.is_true(sse.status().has_stream)
		stream.on_headers(200, { ["content-type"] = "text/event-stream" })
		assert.is_true(sse.is_connected())
	end)

	it("accepts event-stream media types with parameters and mixed case", function()
		for _, headers in ipairs({
			{ ["content-type"] = "text/event-stream" },
			{ ["Content-Type"] = "Text/Event-Stream; charset=utf-8" },
			{ ["content-type"] = " text/event-stream ; charset=UTF-8" },
		}) do
			sse.disconnect()
			assert.is_true(sse.connect())
			received = {}
			stream.on_headers(200, headers)
			assert.is_true(sse.is_connected())
			assert.equals("connected", received[1].kind)
			stream.on_data("data: " .. vim.json.encode(envelope(nil, "accepted")) .. "\n\n")
			assert.equals("accepted", received[2].data.delta)
		end
	end)

	it("does not schedule reconnect after a close listener opens a replacement", function()
		local timers = {}
		vim.uv.new_timer = function()
			local timer = original_timer()
			timers[#timers + 1] = timer
			return timer
		end
		sse.setup({ reconnect = true, reconnect_delay = 60000 })
		local old_stream = stream
		sse.on("disconnected", function() assert.is_true(sse.connect()) end)
		old_stream.on_close("eof")
		assert.is_not.equals(old_stream, stream)
		assert.is_true(sse.status().has_stream)
		assert.equals(0, #timers)
		assert.equals(0, sse.status().reconnect_count)
		stream.on_headers(200, { ["content-type"] = "text/event-stream" })
		assert.is_true(sse.is_connected())
	end)

	it("cancels a pending reconnect timer when connecting immediately", function()
		local timer
		vim.uv.new_timer = function()
			timer = original_timer()
			return timer
		end
		sse.setup({ reconnect = true, reconnect_delay = 60000 })
		stream.on_close("eof")
		assert.is_not_nil(timer)
		assert.is_false(vim.uv.is_closing(timer))
		assert.is_true(sse.connect())
		assert.is_true(vim.uv.is_closing(timer))
		stream.on_headers(200, { ["content-type"] = "text/event-stream" })
		assert.is_true(sse.is_connected())
	end)

	it("ignores a queued reconnect callback after its timer has been replaced", function()
		local timers, opens = {}, 0
		vim.uv.new_timer = function()
			local timer = { closed = false }
			function timer:start(_, _, callback) self.fire = callback end
			function timer:stop() end
			function timer:close() self.closed = true end
			timers[#timers + 1] = timer
			return timer
		end
		vim.uv.is_closing = function(timer) return timer.closed end
		local open = transport.open_stream
		transport.open_stream = function(opts)
			opens = opens + 1
			return open(opts)
		end
		sse.setup({ reconnect = true })
		stream.on_close("eof")
		local old_timer = timers[1]
		old_timer.fire() -- The libuv callback has queued work on Neovim's main loop.
		sse.disconnect()
		assert.is_true(sse.connect())
		stream.on_close("eof")
		local new_timer = timers[2]
		local drained = false
		vim.schedule(function() drained = true end)
		assert.is_true(vim.wait(1000, function() return drained end))
		assert.equals(1, opens)
		assert.is_false(new_timer.closed)
		assert.is_false(sse.status().has_stream)

		new_timer.fire()
		assert.is_true(vim.wait(1000, function() return opens == 2 end))
		assert.is_true(new_timer.closed)
		assert.is_true(sse.status().has_stream)
	end)

	it("ignores queued callbacks from a disconnected stream", function()
		local old_stream = stream
		sse.disconnect()
		old_stream.on_headers(200, {})
		assert.is_false(sse.status().connected)
		assert.is_true(sse.connect())
		received = {}
		old_stream.on_headers(500, {})
		old_stream.on_error({ message = "old error" })
		old_stream.on_data("data: " .. vim.json.encode(envelope("queued", "old")) .. "\n\n")
		old_stream.on_close("old close")
		assert.equals(0, #received)
		stream.on_headers(200, { ["content-type"] = "text/event-stream" })
		assert.is_true(sse.is_connected())
		stream.on_data("data: " .. vim.json.encode(envelope("queued", "new")) .. "\n\n")
		assert.equals("new", received[2].data.delta)
	end)
end)
