local coordinator = require("opencode.ui.chat.render_coordinator")
local state = require("opencode.state")
local sync = require("opencode.sync")

describe("coalesced transcript render scopes", function()
	after_each(function() state.reset(); sync.clear_all() end)

	it("retains every affected session and force in either event order", function()
		for _, first in ipairs({ "current", "foreign" }) do
			local second = first == "current" and "foreign" or "current"
			local source = { session_id = first, force = true, kind = "message" }
			local original = vim.deepcopy(source)
			local merged = coordinator.merge_requests(nil, source)
			merged = coordinator.merge_requests(merged, { sessionID = second, force = false })
			merged = coordinator.merge_requests(merged, { sessionId = "third" })
			assert.same({ current = true, foreign = true, third = true }, merged._render_sessions)
			assert.is_true(merged.force)
			assert.same(original, source)
			state.set_session("current", "Current")
			assert.is_true(coordinator.request_relevant(merged))
		end
	end)

	it("preserves a global invalidation before or after scoped updates", function()
		for _, global_first in ipairs({ true, false }) do
			local scoped, global = { session_id = "foreign" }, { force = true }
			local merged = coordinator.merge_requests(nil, global_first and global or scoped)
			merged = coordinator.merge_requests(merged, global_first and scoped or global)
			assert.is_true(merged._render_global)
			state.set_session("unrelated", "Unrelated")
			assert.is_true(coordinator.request_relevant(merged))
		end
	end)

	it("rechecks selection after the request and retains scope through two queues", function()
		state.set_session("first", "First")
		local request = coordinator.merge_requests(nil, { session_id = "second" })
		assert.is_false(coordinator.request_relevant(request))
		local queued = coordinator.merge_requests(nil, request)
		queued = coordinator.merge_requests(queued, { session_id = "third" })
		assert.is_nil(queued._render_global)
		assert.same({ second = true }, request._render_sessions)
		state.set_session("second", "Second")
		assert.is_true(coordinator.request_relevant(queued))
		state.set_session("fourth", "Fourth")
		assert.is_false(coordinator.request_relevant(queued))
	end)

	it("still emits scoped bus requests while preserving their combined payload", function()
		local bus = require("opencode.events.bus")
		bus.clear()
		local original_schedule, scheduled, received = vim.schedule, {}, {}
		vim.schedule = function(fn) scheduled[#scheduled + 1] = fn end
		local ok, err = xpcall(function()
			coordinator.setup(bus)
			bus.on("chat_render", function(data) received[#received + 1] = data end)
			for _, id in ipairs({ "foreign", "current", "third" }) do
				bus.emit("sync_changed", { kind = "message", session_id = id, force = id == "current" })
			end
			while #scheduled > 0 do table.remove(scheduled, 1)() end
			assert.equals(1, #received)
			assert.same({ foreign = true, current = true, third = true }, received[1]._render_sessions)
			assert.is_true(received[1].force)
		end, debug.traceback)
		vim.schedule = original_schedule
		bus.clear()
		assert.is_true(ok, err)
	end)

	it("resolves each distinct foreign scope only once", function()
		local util = require("opencode.events.util")
		local original, calls = util.render_target_session_id, {}
		util.render_target_session_id = function(_, session_id)
			calls[session_id] = (calls[session_id] or 0) + 1
		end
		local ok, err = xpcall(function()
			local request = coordinator.merge_requests(nil, { session_id = "foreign" })
			request = coordinator.merge_requests(request, { sessionID = "another" })
			assert.is_false(coordinator.request_relevant(request))
			assert.same({ foreign = 1, another = 1 }, calls)
		end, debug.traceback)
		util.render_target_session_id = original
		assert.is_true(ok, err)
	end)
end)
