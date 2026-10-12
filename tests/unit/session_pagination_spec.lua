describe("session picker pagination", function()
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

	it("follows fresh cursors through empty pages and stops cycles", function()
		local calls, result = {}, nil
		client.list_sessions = function(opts, callback)
			calls[#calls + 1] = opts.cursor or "first"
			if not opts.cursor then callback(nil, {}, { cursor = { next = "gap" } })
			elseif opts.cursor == "gap" then callback(nil, {}, { cursor = { next = "last", previous = "gap" } })
			else callback(nil, { { id = "s0" } }, { cursor = { next = "last", previous = "gap" } }) end
		end
		client.get_all_sessions({}, function(err, sessions) assert.is_nil(err); result = sessions end)
		assert.same({ "first", "gap", "last" }, calls)
		assert.same({ { id = "s0" } }, result)
	end)

	it("rejects a final session page arriving after the server connection changes", function()
		local deferred, result, completions = nil, nil, 0
		client.list_sessions = function(_, callback) deferred = callback end
		client.get_all_sessions({}, function(err, sessions)
			completions = completions + 1
			result = { err = err, sessions = sessions }
		end)
		client.setup({ port = 12345 })
		deferred(nil, { { id = "old-server-session" } }, { cursor = {} })
		assert.equals(1, completions)
		assert.equals("stale_connection", result.err.code)
		assert.is_nil(result.sessions)
	end)

	it("rejects a child page arriving after the server connection changes", function()
		local deferred, calls, result, completions = nil, 0, nil, 0
		client.list_sessions = function(opts, callback)
			calls = calls + 1
			assert.equals("parent", opts.parentID)
			if calls == 1 then deferred = callback
			else callback(nil, { { id = "new-server-child" } }, { cursor = {} }) end
		end
		client.get_session_children("parent", function(err, children)
			completions = completions + 1
			result = { err = err, children = children }
		end)
		client.setup({ port = 12345 })
		deferred(nil, { { id = "old-server-child" } }, { cursor = { next = "older" } })
		assert.equals(1, calls)
		assert.equals(1, completions)
		assert.equals("stale_connection", result.err.code)
		assert.is_nil(result.children)
	end)
end)
