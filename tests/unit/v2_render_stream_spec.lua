describe("v2 stream render scheduling", function()
	it("coalesces native deltas into one part update and keeps final replacement authoritative", function()
		local bus, sync, state = require("opencode.events.bus"), require("opencode.sync"), require("opencode.state")
		bus.clear(); sync.clear_all(); state.reset(); state.set_session("s", "Stream")
		local scheduled, timers = {}, {}
		local schedule, defer = vim.schedule, vim.defer_fn
		vim.schedule = function(fn) scheduled[#scheduled + 1] = fn end
		vim.defer_fn = function(fn) timers[#timers + 1] = fn; return { stop = function() end, close = function() end } end
		local ok, failure = pcall(function()
			require("opencode.events.handlers.v2").setup(bus)
			require("opencode.ui.chat.render_coordinator").setup(bus)
			local full, updates, last = 0, 0
			bus.on("chat_render", function() full = full + 1 end)
			bus.on("chat_stream_part_updated", function(data) updates, last = updates + 1, data end)
			local function flush(queue) while #queue > 0 do table.remove(queue, 1)() end end
			local function event(kind, data)
				bus.emit("v2_event", { id = "evt", type = "session." .. kind, created = 10,
					data = vim.tbl_extend("force", { sessionID = "s", assistantMessageID = "m", ordinal = 0 }, data or {}) })
			end
			event("step.started", { started = 1, agent = "build", model = { providerID = "p", id = "m" } })
			event("text.started"); flush(scheduled)
			local baseline = full
			for _ = 1, 400 do event("text.delta", { delta = "a" }) end
			flush(scheduled); assert.equals(baseline, full)
			flush(timers); assert.equals(1, updates); assert.equals(string.rep("a", 400), last.delta)
				assert.equals("text", last.field)
				local code = { "\n`", "``lu", "a\n", "return ", "1" }
				for _, delta in ipairs(code) do event("text.delta", { delta = delta }) end
				flush(scheduled); assert.equals(baseline, full)
				flush(timers); assert.equals(2, updates)
				assert.equals(table.concat(code), last.delta)
				event("text.ended", { text = "AUTHORITATIVE FINAL" }); flush(scheduled)
			assert.equals(baseline + 1, full)
			assert.equals("AUTHORITATIVE FINAL", sync.get_part("m", last.part_id).text)
		end)
		vim.schedule, vim.defer_fn = schedule, defer
		bus.clear(); sync.clear_all(); state.reset(); require("opencode.events.handlers.v2").clear()
		assert.is_true(ok, failure)
	end)
end)
