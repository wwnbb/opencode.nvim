describe("opencode chunked HTTP decoding", function()
	local decoder = require("opencode.client.http_decoder")
	local prefix = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3;ext=value\r\nabc\r\n2\r\nde\r\n0\r\n"

	local function decode(chunks, complete)
		local body, completions, err = {}, 0, nil
		local d = decoder.new({
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
		return table.concat(body), completions, err
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

	it("rejects incomplete trailers without emitting completion", function()
		local body, count, err = decode({ prefix, "Checksum: abc\r\n" }, false)
		assert.equals("abcde", body)
		assert.equals(0, count)
		assert.equals("Connection closed before chunked response completed", err)
	end)
end)
