describe("v2 session picker pagination", function()
	local client = require("opencode.client")
	local original
	before_each(function() original = client.list_sessions end)
	after_each(function() client.list_sessions = original end)
	it("retains filters, follows both opaque cursors and deduplicates pages", function()
		local calls = {}
		client.list_sessions = function(opts, cb)
			calls[#calls + 1] = vim.deepcopy(opts)
			assert.is_true(opts.roots); assert.equals("/project α", opts.directory)
			if not opts.cursor then cb(nil, { { id = "s2" }, { id = "s1" } }, { cursor = { previous = "new", next = "old" } })
			elseif opts.cursor == "new" then cb(nil, {}, { cursor = { next = "old" } })
			else cb(nil, { { id = "s1" }, { id = "s0" } }, { cursor = { previous = "new" } }) end
		end
		local result
		client.get_all_sessions({ roots = true, directory = "/project α" }, function(err, data) assert.is_nil(err); result = data end)
		assert.equals(3, #calls)
		assert.same({ { id = "s2" }, { id = "s1" }, { id = "s0" } }, result)
	end)
end)
