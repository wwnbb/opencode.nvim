describe("v2 complete history pagination", function()
	local saved, client, requests, deferred
	local names = { "opencode.client", "opencode.client.v2" }
	before_each(function()
		saved, requests, deferred = {}, {}, nil
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		package.loaded["opencode.client.v2"] = { request = function(_, args, callback)
			requests[#requests + 1] = args
			local cursor = args.query.cursor
			local data = {}
			if not cursor then
				for i = 102, 3, -1 do data[#data + 1] = { id = string.format("msg_%03d", i), type = "user", text = tostring(i) } end
				callback(nil, data, { cursor = { previous = "newer", next = "older" } })
			elseif cursor == "newer" then deferred = callback
			else
				for i = 3, 1, -1 do data[#data + 1] = { id = string.format("msg_%03d", i), type = "user", text = tostring(i) } end
				callback(nil, data, { cursor = { previous = "newer", next = vim.NIL } })
			end
		end }
		client = require("opencode.client")
	end)
	after_each(function() for _, name in ipairs(names) do package.loaded[name] = saved[name] end end)
	it("walks opaque cursors, deduplicates overlapping pages and retains more than 100 messages", function()
		local result
		client.get_all_messages("s", function(err, data, meta) assert.is_nil(err); assert.is_true(meta.complete); result = data end)
		assert.is_nil(result)
		deferred(nil, {}, { cursor = { next = "older" } })
		assert.equals(3, #requests)
		assert.equals(102, #result)
		assert.equals("msg_001", result[1].info.id)
		assert.equals("msg_102", result[#result].info.id)
	end)
	it("does not continue pagination on a different server", function()
		local result
		client.get_all_messages("s", function(err) result = err end)
		client.setup({ port = 12345 })
		deferred(nil, {}, { cursor = { next = "older" } })
		assert.equals("stale_connection", result.code)
		assert.equals(2, #requests)
	end)
end)
