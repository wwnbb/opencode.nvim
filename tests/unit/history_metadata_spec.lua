local sync = require("opencode.sync")
local project = require("opencode.protocol.v2.messages")
local metadata = require("opencode.ui.chat.history_metadata")
local throughput = require("opencode.ui.chat.throughput")

describe("derived history metadata", function()
	local original, calls
	before_each(function()
		sync.clear_all(); metadata.clear()
		original, calls = throughput.by_message, 0
		throughput.by_message = function(...)
			calls = calls + 1
			return original(...)
		end
	end)
	after_each(function()
		throughput.by_message = original
		sync.clear_all(); metadata.clear()
	end)
	local function put(message)
		sync.handle_session_messages("history-cache", { project.project("history-cache", message) })
	end
	local function get(filter, enabled)
		local messages = sync.get_messages("history-cache")
		if filter then messages = vim.tbl_filter(function(m) return m.id < filter end, messages) end
		return metadata.get("history-cache", messages, filter, enabled)
	end
	it("reuses scalar derivations across content deltas and refreshes metadata", function()
		put({ id = "u", type = "user", text = "hello", time = { created = 0 } })
		local assistant = { id = "z", type = "assistant", agent = "build",
			time = { created = 100, streamed = 1100 }, tokens = { output = 100, reasoning = 0 },
			content = { { type = "text", text = "answer" } } }
		put(assistant)
		local first = get()
		assert.equals(0, first.created("u")); assert.equals("build", first.agent("u"))
		assert.equals(100, first.rate("z")); assert.equals(1, calls)
		sync.handle_v2_event({ id = "delta", created = 2, type = "session.text.delta",
			data = { sessionID = "history-cache", assistantMessageID = "z", ordinal = 0, delta = "!" } })
		assert.equals(100, get().rate("z")); assert.equals(1, calls)
		local equal = vim.deepcopy(sync.get_message("history-cache", "z"))
		sync.handle_message_updated(equal)
		assert.equals("build", get().agent("u")); assert.equals(1, calls)
		assistant.tokens.output = 200; assistant.agent = "explore"; put(assistant)
		assert.equals(200, get().rate("z")); assert.equals("explore", get().agent("u"))
		assert.equals(2, calls)
		assert.equals(100, first.rate("z")); assert.equals("build", first.agent("u"))
		first.agent = function() return "mutated" end
		assert.equals("explore", get().agent("u")); assert.equals(2, calls)
	end)
	it("keys revert and TPS options, and forgets cleared owners", function()
		put({ id = "a", type = "user", text = "hello", time = { created = 0 } })
		put({ id = "b", type = "assistant", agent = "build", time = { created = 100, streamed = 1100 },
			tokens = { output = 50 }, content = {} })
		assert.equals(50, get().rate("b")); assert.equals(1, calls)
		assert.is_nil(get("b").rate("b")); assert.is_nil(get("b").agent("a")); assert.equals(2, calls)
		assert.is_nil(get(nil, false).rate("b")); assert.equals(2, calls)
		assert.equals(50, get().rate("b")); assert.equals(3, calls)
		metadata.clear_session("history-cache")
		assert.equals(50, get().rate("b")); assert.equals(4, calls)
		sync.clear_session_messages("history-cache")
		put({ id = "a", type = "user", text = "new", time = { created = 9 } })
		assert.equals(9, get().created("a")); assert.is_nil(get().rate("b")); assert.equals(5, calls)
	end)
	it("matches cold derivation after each history, ordering and timing change", function()
		local a = { id = "b", type = "assistant", agent = "build", time = { created = 100, streamed = 1100 },
			tokens = { output = 100 }, content = {} }
		local b = { id = "d", type = "assistant", agent = "explore", time = { created = 2200, streamed = 6200 },
			tokens = { output = 100 }, content = {} }
		local filter
		local trace = {
			function() put({ id = "a", type = "user", text = "start", time = { created = 0 } }) end,
			function() put(a) end,
			function() put({ id = "c", type = "user", text = "steer", time = { created = 2000 } }) end,
			function() put(b) end,
			function() put({ id = "idle", type = "idle", time = { created = 10000 } }) end,
			function() put({ id = "switch", type = "agent-switched", agent = "plan", time = { created = 1500 } }) end,
			function() b.time.streamed = nil; put(b) end,
			function() b.time.streamed = 3200; b.tokens.reasoning = 50; put(b) end,
			function() a.time.created = 3000; put(a) end,
			function() filter = "d" end,
			function() filter = nil; sync.handle_message_removed("history-cache", "b") end,
			function() sync.clear_session_messages("history-cache") end,
			function() put({ id = "a", type = "user", text = "reload", time = { created = 11 } }); put(a) end,
		}
		for _, apply in ipairs(trace) do
			apply()
			local warm = get(filter)
			metadata.clear()
			local cold = get(filter)
			for _, id in ipairs({ "a", "b", "c", "d", "idle", "switch" }) do
				assert.equals(cold.created(id), warm.created(id))
				assert.equals(cold.agent(id), warm.agent(id))
				assert.equals(cold.rate(id), warm.rate(id))
			end
		end
	end)

end)
