describe("bundled plugin capability warnings", function()
	it("checks the first active session and rejects an obsolete non-object response", function()
		local state, bus = require("opencode.state"), require("opencode.events.bus")
		local client = require("opencode.client")
		local saved, old_notify = client.review_rpc, vim.notify
		local notices, methods = {}, {}
		state.reset(); bus.clear(); require("opencode.sync").clear_all()
		vim.notify = function(message) notices[#notices + 1] = message end
		client.review_rpc = function(method, _, _, callback)
			methods[#methods + 1] = method
			callback(nil, false)
		end
		local ok, err = pcall(function()
			require("opencode.events.handlers.review_v2").setup(bus)
			bus.emit("connected", {})
			assert.equals(0, #methods)
			state.upsert_session({ id = "first", directory = "/fixture" })
			require("opencode.session").set_active("first", "First session")
			assert.is_true(vim.wait(500, function() return #notices == 1 end, 10))
			assert.same({ "capabilities" }, methods)
			assert.is_truthy(notices[1]:find("scripts/install-tools.sh", 1, true))
			assert.is_truthy(notices[1]:find("2.0.11-2", 1, true))
			bus.emit("session_change", { id = "first" })
			assert.equals(1, #notices)
		end)
		client.review_rpc, vim.notify = saved, old_notify
		bus.clear(); state.reset(); require("opencode.sync").clear_all()
		assert.is_true(ok, err)
	end)
end)
