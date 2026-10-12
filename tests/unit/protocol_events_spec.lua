describe("native event envelope decoding", function()
	local decode = require("opencode.protocol.events").decode

	it("rejects malformed locations", function()
		for _, location in ipairs({ 42, true, false, "invalid", vim.NIL }) do
			local decoded, err = decode({ type = "provider.updated", data = {}, location = location })
			assert.is_nil(decoded)
			assert.equals("Invalid v2 event location", err)
		end
	end)

	it("accepts absent and object locations", function()
		local decoded, err = decode({ type = "server.connected", data = {} })
		assert.is_nil(err)
		assert.is_nil(decoded.payload._directory)
		for _, location in ipairs({ {}, { directory = "/project" } }) do
			decoded, err = decode({ type = "provider.updated", data = {}, location = location })
			assert.is_nil(err)
			assert.equals(location.directory, decoded.payload._directory)
			assert.same(location, decoded.payload._envelope.location)
		end
	end)

	it("keeps payload, raw envelope and source independent", function()
		local source = {
			type = "provider.updated", data = { nested = { value = "original" } },
			location = { directory = "/project" },
		}
		local payload = decode(source).payload
		payload.nested.value = "listener"
		assert.equals("original", source.data.nested.value)
		assert.equals("original", payload._envelope.data.nested.value)
		payload._envelope.data.nested.value = "reducer"
		payload._envelope.location.directory = "/other"
		assert.equals("listener", payload.nested.value)
		assert.equals("original", source.data.nested.value)
		assert.equals("/project", source.location.directory)
		assert.is_nil(source.data._envelope)
		assert.is_nil(payload._envelope.data._envelope)
	end)
end)
