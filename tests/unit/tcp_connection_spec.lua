describe("TCP timeout ownership", function()
	local tcp = require("opencode.client.tcp_connection")
	local original_wrap, original_resolve, callbacks, connections
	before_each(function()
		original_wrap, original_resolve = vim.schedule_wrap, vim.uv.getaddrinfo
		callbacks, connections = {}, {}
		vim.schedule_wrap = function(callback)
			callbacks[#callbacks + 1] = callback
			return function() end
		end
		vim.uv.getaddrinfo = function() return {} end
	end)
	after_each(function()
		for _, connection in ipairs(connections) do connection.close() end
		vim.schedule_wrap, vim.uv.getaddrinfo = original_wrap, original_resolve
	end)

	it("keeps a connection alive when a queued timeout runs after cancellation", function()
		local errors = {}
		local connection = assert(tcp.open({
			host = "localhost", port = 1234, timeout = 1000,
			on_error = function(reason) errors[#errors + 1] = reason end,
		}))
		connections[#connections + 1] = connection
		local queued = callbacks[1]
		connection.stop_timeout() -- The stream cancels this timer when headers arrive.
		queued()
		assert.is_true(connection.is_active())
		assert.same({}, errors)
	end)

	it("still reports an active timeout exactly once", function()
		local errors = {}
		local connection = assert(tcp.open({
			host = "localhost", port = 1234, timeout = 1000,
			on_error = function(reason, err) errors[#errors + 1] = { reason, err.timeout } end,
		}))
		connections[#connections + 1] = connection
		callbacks[1]()
		callbacks[1]()
		assert.is_false(connection.is_active())
		assert.same({ { "timeout", true } }, errors)
	end)
end)
