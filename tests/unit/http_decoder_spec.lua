describe("opencode HTTP response decoding", function()
	local decoder = require("opencode.client.http_decoder")
	local prefix = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=value\r\nabc\r\n2\r\nde\r\n0\r\n"

	local function decode(chunks, complete)
		local body, headers, completions, err = {}, {}, 0, nil
		local d = decoder.new({
			on_headers = function(status) table.insert(headers, status) end,
			on_body = function(chunk) table.insert(body, chunk) end,
			on_complete = function() completions = completions + 1 end,
			on_error = function(error) err = error.message end,
		})
		for _, chunk in ipairs(chunks) do d:push(chunk) end
		if complete then
			assert.equals(1, completions) -- Must finish even when the connection stays open.
			assert.is_nil(err)
		end
		d:finish_eof()
		return table.concat(body), completions, err, headers, d:headers_parsed()
	end

	for _, ending in ipairs({ "\r\n", "Checksum: abc\r\nOther: value\r\n\r\n" }) do
		it("accepts every split point with trailers " .. vim.inspect(ending), function()
			local response = prefix .. ending
			for split = 1, #response - 1 do
				local body, count = decode({ response:sub(1, split), response:sub(split + 1) }, true)
				assert.equals("abcde", body)
				assert.equals(1, count)
			end
			local bytes = {}
			for index = 1, #response do bytes[index] = response:sub(index, index) end
			assert.equals("abcde", decode(bytes, true))
		end)
	end

	it("rejects malformed trailer fields without completing the response", function()
		for _, line in ipairs({ "Missing-Colon", ": value", "Bad Name: value", "Bad : value",
			"X-Trace: before\rafter", "X-Trace: before\0after", "X-Trace: before" .. string.char(127) .. "after",
			"Checksum: valid\r\n\tbad\0continuation", "Checksum: valid\r\n\tbad" .. string.char(127) }) do
			local response = prefix .. line .. "\r\n\r\n"
			for split = 0, #response do
				local body, count, err = decode({ response:sub(1, split), response:sub(split + 1) }, false)
				assert.equals("abcde", body)
				assert.equals(0, count)
				assert.matches("Invalid HTTP trailer", err)
			end
		end
	end)

	it("unfolds response fields and keeps valid trailers separate from framing headers", function()
		for _, ending in ipairs({ "\r\n", "\n" }) do
			local response = table.concat({ "HTTP/1.1 200 OK", "X-Note: First", "\t猫 last",
				"Content-Length:", " 2", "", "OK" }, ending)
			for split = 0, #response do
				local fields, body, completed, err = nil, {}, 0, nil
				local d = decoder.new({
					on_headers = function(_, headers) fields = headers end,
					on_body = function(chunk) body[#body + 1] = chunk end,
					on_complete = function() completed = completed + 1 end,
					on_error = function(error) err = error.message end,
				})
				d:push(response:sub(1, split)); d:push(response:sub(split + 1)); d:finish_eof()
				assert.is_nil(err)
				assert.equals(1, completed)
				assert.equals("OK", table.concat(body))
				assert.same({ ["x-note"] = "First 猫 last", ["content-length"] = "2" }, fields)
			end
		end

		local response = prefix .. "Checksum: First\r\n\t猫 last\r\nContent-Length: 999\r\n\r\n"
		local fields, body, completed = nil, {}, 0
		local d = decoder.new({
			on_headers = function(_, headers) fields = headers end,
			on_body = function(chunk) body[#body + 1] = chunk end,
			on_complete = function() completed = completed + 1 end,
			on_error = function(err) error(err.message) end,
		})
		for i = 1, #response do d:push(response:sub(i, i)) end
		d:finish_eof()
		assert.equals(1, completed)
		assert.equals("abcde", table.concat(body))
		assert.same({ ["transfer-encoding"] = "chunked" }, fields)
	end)

	it("preserves large binary chunks and validates their terminator before delivery", function()
		local payload = string.rep("猫\r\n\0x", 16384)
		for _, ending in ipairs({ "\r\n0\r\n\r\n", "!!", "" }) do
			local body, completions, err = {}, 0, nil
			local d = decoder.new({
				on_body = function(chunk) body[#body + 1] = chunk end,
				on_complete = function() completions = completions + 1 end,
				on_error = function(error) err = error.message end,
			})
			d:push("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" .. string.format("%X\r\n", #payload))
			for offset = 1, #payload, 257 do d:push(payload:sub(offset, offset + 256)) end
			assert.same({}, body, "a chunk must not be delivered before its terminator is validated")
			d:push(ending)
			d:finish_eof()
			if ending:sub(1, 2) == "\r\n" then
				assert.same({ payload }, body)
				assert.equals(1, completions)
				assert.is_nil(err)
			else
				assert.same({}, body)
				assert.equals(0, completions)
				assert.is_string(err)
			end
		end
	end)

	it("rejects malformed status codes and protocol versions", function()
		for _, line in ipairs({ "HTTP/1.1 2000 OK", "HTTP/1.1 200OK", "HTTP/1.1 1000 Continue",
			"HTTP/11.0 200 OK", "HTTP/1.00 200 OK", "HTTP/00.1 200 OK" }) do
			local response = line .. "\r\nContent-Length: 2\r\n\r\nOK"
			for split = 0, #response do
				local body, count, err, headers = decode({ response:sub(1, split), response:sub(split + 1) }, false)
				assert.equals("", body)
				assert.equals(0, count)
				assert.equals("Invalid HTTP status line: " .. line, err)
				assert.same({}, headers)
			end
		end
	end)

	it("accepts a status without a reason and a reason containing digits", function()
		for _, line in ipairs({ "HTTP/1.1 200", "HTTP/1.1 200 ", "HTTP/1.1 200 0K" }) do
			local body, count, err, headers = decode({ line .. "\r\nContent-Length: 2\r\n\r\nOK" }, true)
			assert.equals("OK", body)
			assert.equals(1, count)
			assert.is_nil(err)
			assert.same({ 200 }, headers)
		end
	end)

	it("rejects malformed header lines before publishing headers or body", function()
		local invalid = {
			"Content-Length : 2", " Content-Length: 2", "Content-Length\t: 2",
			"Content Length: 2", ": value", "Missing-Colon", "X-Trace: first\rContent-Length: 2",
		}
		for byte = 0, 31 do
			if byte ~= 9 and byte ~= 10 then invalid[#invalid + 1] = "X-Trace: before" .. string.char(byte) .. "after" end
		end
		invalid[#invalid + 1] = "X-Trace: before" .. string.char(127) .. "after"
		for _, line in ipairs(invalid) do
			local response = "HTTP/1.1 200 OK\r\n" .. line .. "\r\n\r\nOK"
			for split = 0, #response do
				local body, count, err, headers, parsed = decode({ response:sub(1, split), response:sub(split + 1) }, false)
				assert.equals("", body)
				assert.equals(0, count)
				assert.matches("Invalid HTTP header", err)
				assert.same({}, headers)
				assert.is_false(parsed)
			end
		end
	end)

	it("accepts token field names and trims only optional spaces and tabs", function()
		for _, ending in ipairs({ "\r\n", "\n" }) do
			local seen
			local d = decoder.new({ on_headers = function(_, headers) seen = headers end })
			d:push(table.concat({
				"HTTP/1.1 200 OK", "X-HTTP_Test!: \tПривет\t middle \t", "Empty:",
				"Content-Length: \t0 \t", "", "",
			}, ending))
			assert.same({ ["x-http_test!"] = "Привет\t middle", empty = "", ["content-length"] = "0" }, seen)
			assert.is_true(d:headers_parsed())
		end
	end)

	it("rejects incomplete trailers without emitting completion", function()
		local body, count, err = decode({ prefix, "Checksum: abc\r\n" }, false)
		assert.equals("abcde", body)
		assert.equals(0, count)
		assert.equals("Connection closed before chunked response completed", err)
	end)

	it("rejects malformed chunk sizes rather than accepting their hexadecimal prefix", function()
		for _, size in ipairs({ "3oops", "3 x", "0x3", "20000000000001", string.rep("f", 400) }) do
			local body, count, err = decode({ "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
				.. size .. "\r\nabc\r\n0\r\n\r\n" }, false)
			assert.equals("", body)
			assert.equals(0, count)
			assert.equals("Failed to decode chunked response: Invalid chunk size", err)
		end
	end)

	it("rejects invalid explicit body lengths rather than using close framing", function()
		for _, length in ipairs({ "-1", "1.5", "0x2", "invalid", "2, 3", "2,", "9007199254740993", string.rep("9", 400) }) do
			local body, count, err = decode({ "HTTP/1.1 200 OK\r\nContent-Length: " .. length .. "\r\n\r\nOK" }, false)
			assert.equals("", body)
			assert.equals(0, count)
			assert.equals("Invalid Content-Length", err)
		end
		for _, length in ipairs({ "2 \t", "2, 2", "02, 2" }) do
			local body, count, err = decode({ "HTTP/1.1 200 OK\r\nContent-Length: " .. length .. "\r\n\r\nOK" }, true)
			assert.equals("OK", body)
			assert.equals(1, count)
			assert.is_nil(err)
		end
	end)

	it("uses the final transfer coding and ignores content length when transfer encoding is present", function()
		for _, encoding in ipairs({ "unchunked", "chunked, gzip", "gzip" }) do
			local body, count, err = decode({ "HTTP/1.1 200 OK\r\nTransfer-Encoding: " .. encoding
				.. "\r\nContent-Length: 2\r\n\r\nOKTAIL" }, false)
			assert.equals("OKTAIL", body)
			assert.equals(1, count)
			assert.is_nil(err)
		end
	end)

	it("rejects HTTP/1.0 transfer encoding before publishing headers while preserving valid version framing", function()
		for _, response in ipairs({
			"HTTP/1.0 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nOK\r\n0\r\n\r\n",
			"HTTP/1.0 200 OK\r\nTransfer-Encoding: gzip\r\nContent-Length: 2\r\n\r\nOK",
			"HTTP/1.0 200 OK\r\nTransfer-Encoding:\r\nContent-Length: 2\r\n\r\nOK",
			"HTTP/1.0 204 No Content\r\nTransfer-Encoding: chunked\r\n\r\n",
			"HTTP/1.0 100 Continue\r\nTransfer-Encoding: chunked\r\n\r\n"
				.. "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK",
		}) do
			for split = 0, #response do
				local body, count, err, headers, parsed = decode({ response:sub(1, split), response:sub(split + 1) }, false)
				assert.equals("", body)
				assert.equals(0, count)
				assert.equals("Transfer-Encoding is invalid in HTTP/1.0", err)
				assert.same({}, headers)
				assert.is_false(parsed)
			end
		end
		for _, response in ipairs({
			"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nOK",
			"HTTP/1.0 200 OK\r\n\r\nOK",
			"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nOK\r\n0\r\n\r\n",
			"HTTP/1.9 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nOK\r\n0\r\n\r\n",
		}) do
			local body, count, err, headers = decode({ response }, false)
			assert.equals("OK", body)
			assert.equals(1, count)
			assert.is_nil(err)
			assert.same({ 200 }, headers)
		end
	end)

	it("waits for final headers after split or coalesced informational responses", function()
		local response = "HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\n"
			.. "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
		for split = 0, #response do
			local body, count, err, headers = decode({ response:sub(1, split), response:sub(split + 1) }, true)
			assert.equals("OK", body)
			assert.equals(1, count)
			assert.is_nil(err)
			assert.same({ 200 }, headers)
		end
		local bytes = {}
		for index = 1, #response do bytes[index] = response:sub(index, index) end
		local body, _, _, headers = decode(bytes, true)
		assert.equals("OK", body)
		assert.same({ 200 }, headers)
	end)

	it("rejects EOF after informational headers without a final response", function()
		local body, count, err, headers, headers_parsed = decode({ "HTTP/1.1 100 Continue\r\n\r\n" }, false)
		assert.equals("", body)
		assert.equals(0, count)
		assert.equals("Connection closed before response headers", err)
		assert.same({}, headers)
		assert.is_false(headers_parsed)
	end)

	it("terminates HTTP decoding at a 101 protocol switch", function()
		local body, count, err, headers = decode({
			"HTTP/1.1 101 Switching Protocols\r\nConnection: upgrade\r\nUpgrade: websocket\r\n\r\n",
			"upgraded protocol bytes",
		}, true)
		assert.equals("", body)
		assert.equals(1, count)
		assert.is_nil(err)
		assert.same({ 101 }, headers)
	end)
end)
