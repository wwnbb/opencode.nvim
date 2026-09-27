describe("opencode message history action", function()
	local actions = require("opencode.actions")
	local lifecycle = require("opencode.lifecycle")
	local transport = require("opencode.client.transport")
	local state = require("opencode.state")
	local sync = require("opencode.sync")
	local pending = require("opencode.session.pending")
	local events = require("opencode.events")
	local original_request, original_ensure_connected, requests

	before_each(function()
		state.reset()
		sync.clear_all()
		pending.clear_all()
		events.clear_history()
		original_request, original_ensure_connected = transport.request, lifecycle.ensure_connected
		requests = {}
		lifecycle.ensure_connected = function(callback) callback() end
		transport.request = function(opts, callback)
			requests[#requests + 1] = opts.path
			local body
			if opts.path:match("^/api/session/history/message%?") then
				body = { data = {}, cursor = { next = vim.NIL, previous = vim.NIL } }
			else
				assert.equals("/api/session/active", opts.path)
				body = { data = vim.empty_dict() }
			end
			callback(nil, { status = 200, headers = { ["content-type"] = "application/json" }, body = vim.json.encode(body) })
		end
	end)

	after_each(function()
		transport.request, lifecycle.ensure_connected = original_request, original_ensure_connected
		state.reset()
		sync.clear_all()
		pending.clear_all()
		events.clear_history()
	end)

	for _, case in ipairs({ { name = "defaults to 100 messages", limit = 100 }, { name = "honors an explicit limit", limit = 25, opts = { limit = 25 } } }) do
		it(case.name, function()
			local callbacks = 0
			actions.load_session_messages("history", case.opts, function(err, messages)
				assert.is_nil(err)
				assert.same({}, messages)
				callbacks = callbacks + 1
			end)
			assert.is_true(vim.wait(500, function() return callbacks == 1 end, 10))
			assert.equals("/api/session/history/message?limit=" .. case.limit, requests[1])
		end)
	end
end)
