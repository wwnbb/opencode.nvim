describe("opencode runtime status", function()
	local client = require("opencode.client")
	local transport = require("opencode.client.transport")
	local original_request, original_schedule, requests
	local plugins = { { id = "test-plugin", source = { type = "local", path = "/test/plugin" }, state = { status = "active" } } }

	before_each(function()
		original_request, original_schedule = transport.request, vim.schedule
		requests = {}
		vim.schedule = function(callback) callback() end
		transport.request = function(opts, callback)
			local path = opts.path:match("^[^?]+")
			requests[#requests + 1] = path
			local body
			if path == "/api/info" then
				body = { version = "2.0.11", pid = 1, urls = {}, paths = { tmp = "/tmp" } }
			elseif path == "/api/plugin" then
				body = { location = { directory = "/test" }, data = plugins }
			else
				assert.equals("/api/mcp", path)
				body = { location = { directory = "/test" }, data = {} }
			end
			callback(nil, { status = 200, headers = { ["content-type"] = "application/json" }, body = vim.json.encode(body) })
		end
	end)

	after_each(function()
		transport.request, vim.schedule = original_request, original_schedule
	end)

	it("returns all runtime catalogs exactly once with synchronous HTTP callbacks", function()
		local callbacks, result = 0, nil
		client.get_status(function(err, status)
			assert.is_nil(err)
			assert.equals(3, #requests)
			callbacks, result = callbacks + 1, status
		end, { directory = "/test" })
		assert.equals(1, callbacks)
		assert.equals("2.0.11", result.version)
		assert.same(plugins, result.plugins)
		assert.same({}, result.mcp)
		assert.same({}, result.errors)
	end)
end)
