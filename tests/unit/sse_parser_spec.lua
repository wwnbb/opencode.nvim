describe("opencode native v2 SSE parser", function()
	local transport = require("opencode.client.transport")
	local original_open, original_sse, sse, stream, received

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
		sse.disconnect()
		sse.clear_listeners()
		transport.open_stream = original_open
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
		local frame = "data: " .. vim.json.encode(envelope("unique", "once")) .. "\n\n"
		stream.on_data(frame .. frame)
		assert.equals(1, #received)
		sse.disconnect()
		assert.is_true(sse.connect())
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

	it("resets unfinished fields when connecting a new stream", function()
		stream.on_data("event: abandoned\nid: old\n")
		sse.disconnect()
		assert.is_true(sse.connect())
		received = {}
		stream.on_data("data: " .. vim.json.encode(envelope(nil, "next")) .. "\n\n")
		assert.equals("session.text.delta", received[1].kind)
		assert.is_nil(received[1].id)
	end)
end)
