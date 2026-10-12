local bus, handler = require("opencode.events.bus"), require("opencode.events.handlers.server")
local client, pending = require("opencode.client"), require("opencode.session.pending")
local state, sync = require("opencode.state"), require("opencode.sync")

describe("server recovery scheduling", function()
	local saved, defer, timers, history, inbox, metadata
	local function commit(id)
		bus.emit("server_event", { id = id, created = 10, type = "session.revert.committed",
			data = { sessionID = "s", to = "message" } })
	end
	local function finish(index)
		history[index](nil, {})
		inbox[index](nil, {})
	end
	before_each(function()
		bus.clear(); handler.clear(); state.reset(); sync.clear_all(); pending.clear_all()
		saved, timers, history, inbox, metadata = {}, {}, {}, {}, 0
		for _, method in ipairs({ "get_session", "get_messages", "get_inbox" }) do saved[method] = client[method] end
		defer = vim.defer_fn
		vim.defer_fn = function(callback)
			timers[#timers + 1] = callback
			return { stop = function() end, close = function() end }
		end
		client.get_session = function(_, callback)
			metadata = metadata + 1
			callback(nil, { id = "s", title = "Session" })
		end
		client.get_messages = function(_, _, callback) history[#history + 1] = callback end
		client.get_inbox = function(_, callback) inbox[#inbox + 1] = callback end
		handler.setup(bus)
	end)
	after_each(function()
		vim.defer_fn = defer
		for method, original in pairs(saved) do client[method] = original end
		bus.clear(); handler.clear(); state.reset(); sync.clear_all(); pending.clear_all()
	end)

	it("reads each endpoint once for a committed revert", function()
		commit("evt_first")
		assert.equals(1, #timers)
		table.remove(timers, 1)()
		assert.equals(1, metadata)
		assert.equals(1, #history)
		assert.equals(1, #inbox)
		finish(1)
		assert.equals(0, #timers)
	end)

	it("repeats recovery when another event arrives during the reads", function()
		commit("evt_first")
		table.remove(timers, 1)()
		commit("evt_second")
		assert.equals(0, #timers)
		finish(1)
		assert.equals(1, #timers)
		table.remove(timers, 1)()
		assert.equals(2, metadata)
		assert.equals(2, #history)
		assert.equals(2, #inbox)
		finish(2)
		assert.equals(0, #timers)
	end)
end)
