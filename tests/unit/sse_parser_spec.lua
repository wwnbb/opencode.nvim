describe("opencode SSE parser", function()
	local transport = require("opencode.client.transport")
	local original_open, original_sse, sse, stream, received

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
		it("reads named events and IDs using " .. vim.inspect(separator), function()
			local frame = "event" .. separator .. "custom\r\nid" .. separator .. "event-123\r\ndata: {\"value\":1}\r\n\r\n"
			-- Split every byte, including CRLF and field names, across transport callbacks.
			for index = 1, #frame do stream.on_data(frame:sub(index, index)) end
			assert.same({ { kind = "custom", id = "event-123", data = { value = 1 } } }, received)
		end)
	end

	it("keeps fields after data in the same event and preserves multiline whitespace", function()
		stream.on_data(": comment\ndata: first\ndata:  second\nevent: custom\nid: last\n")
		assert.equals(0, #received)
		stream.on_data("\n")
		assert.same({ { kind = "custom", id = "last", data = "first\n second" } }, received)
	end)

	it("supports empty fields and ignores invalid IDs without splitting events", function()
		stream.on_data("event: custom\nevent\nid: valid\nid: bad\0id\ndata\ndata: tail\n\n")
		assert.same({ { kind = "message", id = "valid", data = "\ntail" } }, received)
		stream.on_data("id: old\nid:\ndata: next\n\n")
		assert.same({ kind = "message", data = "next" }, received[2])
	end)

	it("uses frame IDs to deduplicate wrapped global events", function()
		local payload = vim.json.encode({ directory = "global", payload = { type = "custom", properties = { value = 1 } } })
		local frame = "id: unique\ndata: " .. payload .. "\n\n"
		stream.on_data(frame .. frame)
		assert.equals(1, #received)
		assert.equals("custom", received[1].kind)
		assert.equals("unique", received[1].id)
	end)

	it("resets unfinished fields when connecting a new stream", function()
		stream.on_data("event: abandoned\nid: old\n")
		sse.disconnect()
		assert.is_true(sse.connect())
		received = {}
		stream.on_data("data: next\n\n")
		assert.same({ { kind = "message", data = "next" } }, received)
	end)
end)
