describe("v2 session snapshot freshness", function()
	it("does not overwrite a rename that arrived after a recovery read began", function()
		local state, sync, bus = require("opencode.state"), require("opencode.sync"), require("opencode.events.bus")
		local client, pending = require("opencode.client"), require("opencode.session.pending")
		local handler = require("opencode.events.handlers.v2")
		state.reset(); sync.clear_all(); pending.clear_all(); bus.clear(); handler.clear()
		state.upsert_session({ id = "s", title = "Original" }); state.set_session("s", "Original")
		local saved, callback = {}
		for _, method in ipairs({ "get_session", "get_messages", "get_inbox" }) do saved[method] = client[method] end
		client.get_session = function(_, cb) callback = cb end
		client.get_messages = function(_, _, cb) cb(nil, {}) end
		client.get_inbox = function(_, cb) cb(nil, {}) end
		local ok, err = pcall(function()
			handler.setup(bus); bus.emit("v2_reconcile", { session_id = "s" })
			assert.is_true(vim.wait(1000, function() return callback ~= nil end, 10))
			bus.emit("v2_event", { id = "evt", created = 200, type = "session.renamed", data = { sessionID = "s", title = "New name" } })
			callback(nil, { id = "s", title = "Old snapshot", time = { updated = 100 } })
			assert.equals("New name", state.get_session_record("s").title)
		end)
		for method, original in pairs(saved) do client[method] = original end
		bus.clear(); handler.clear(); state.reset(); sync.clear_all(); pending.clear_all()
		assert.is_true(ok, err)
	end)
end)
