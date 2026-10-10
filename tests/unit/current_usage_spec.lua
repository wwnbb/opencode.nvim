local selectors, state, sync = require("opencode.selectors"), require("opencode.state"), require("opencode.sync")
local projection = require("opencode.protocol.v2.messages")

describe("current session context and money", function()
	local function tokens(input)
		return { input = input or 1000, output = 100, reasoning = 20, cache = { read = 800, write = 80 }, total = 999999 }
	end
	local function put(message, sid) sync.handle_session_messages(sid or "s", { projection.project(sid or "s", message) }) end
	local function assistant(id, created, usage)
		return { id = id, type = "assistant", time = { created = created }, model = { providerID = "p", id = "measured" }, tokens = usage, content = {} }
	end
	before_each(function()
		state.reset(); sync.clear_all(); state.set_session("s", "Session")
		state.upsert_session({ id = "s", directory = "/project", cost = 1.5, model = { providerID = "p", id = "next-model" } }, { touch = false })
		sync.handle_location_catalog("/project", "providers", { providers = { { id = "p", models = {
			measured = { id = "measured", limit = { context = 10000 } }, ["next-model"] = { limit = { context = 1000000 } },
		} } }, default = {} })
		sync.select_catalog_location("/project")
		put(assistant("earlier", 1, tokens(9000)))
		put(assistant("latest", 2, tokens()))
	end)
	after_each(function() state.reset(); sync.clear_all() end)

	it("uses the last measured step and its own model limit, ignoring historical totals and next-send selection", function()
		local usage = assert(selectors.current_context())
		assert.equals(2000, usage.tokens); assert.equals(20, usage.percent); assert.equals("latest", usage.message_id)
		assert.equals("measured", usage.model.modelID)
		assert.same({ input = 1000, output = 100, reasoning = 20, cached = 800, cache_write = 80, new = 1200, total = 2000 }, usage.breakdown)
		usage.breakdown.total = -1
		assert.equals(2000, selectors.current_context().breakdown.total)
		put(assistant("streaming", 3))
		assert.equals("latest", selectors.current_context().message_id)
	end)

	it("applies staged revert by the boundary's actual history position and reports an unloaded boundary as unknown", function()
		put({ id = "lexically-first", type = "user", time = { created = 3 }, text = "Undo this turn" })
		put(assistant("zz-response", 4, tokens(8000)))
		state.upsert_session({ id = "s", revert = { messageID = "lexically-first" } }, { touch = false })
		assert.equals(2000, selectors.current_context().tokens)
		assert.equals(1.5, selectors.session_cost(), "staging undo cannot undo money already spent")
		state.upsert_session({ id = "s", revert = { messageID = "missing" } }, { touch = false })
		assert.is_nil(selectors.current_context())
		state.upsert_session({ id = "s", revert = vim.NIL }, { touch = false })
		assert.equals(9000, selectors.current_context().tokens)
	end)

	it("resets context after completed compaction, preserves cancelled compaction, and respects compaction before revert", function()
		put({ id = "compact", type = "compaction", status = "completed", time = { created = 3 } })
		assert.is_nil(selectors.current_context())
		put(assistant("after", 4, tokens(3000)))
		assert.equals(4000, selectors.current_context().tokens)
		state.upsert_session({ id = "s", revert = { messageID = "compact" } }, { touch = false })
		assert.equals(2000, selectors.current_context().tokens)
		state.upsert_session({ id = "s", revert = vim.NIL }, { touch = false })
		put({ id = "compact", type = "compaction", status = "cancelled", time = { created = 3 } })
		sync.handle_message_removed("s", "after")
		assert.equals(2000, selectors.current_context().tokens)
	end)

	it("does not turn absent, partial, zero, negative, or non-finite latest usage into a context estimate", function()
		for _, invalid in ipairs({ {}, { input = 1, cache = {} }, { input = 0, output = 0, reasoning = 0, cache = { read = 0, write = 0 } },
			{ input = -1, output = 0, reasoning = 0, cache = { read = 0, write = 0 } }, { input = math.huge, output = 0, reasoning = 0, cache = { read = 0, write = 0 } } }) do
			put(assistant("latest", 2, invalid))
			assert.is_nil(selectors.current_context())
		end
	end)

	it("selects the requested session and its location catalog, leaving unknown model limits without percent", function()
		state.upsert_session({ id = "other", directory = "/other", cost = 0 }, { touch = false })
		sync.handle_location_catalog("/other", "providers", { providers = { { id = "p", models = { measured = { limit = { context = 40000 } } } } }, default = {} })
		put(assistant("o", 1, tokens()), "other")
		state.set_session("other", "Other")
		sync.select_catalog_location("/other")
		assert.equals(5, selectors.current_context().percent)
		assert.equals(20, selectors.current_context("s").percent)
		local message = assistant("o", 1, tokens()); message.model.id = "unknown"
		put(message, "other")
		assert.equals(2000, selectors.current_context().tokens); assert.is_nil(selectors.current_context().percent)
	end)

	it("uses authoritative family costs, keeps child scope local, and exposes missing member cost as partial", function()
		for _, record in ipairs({ { id = "child", parentID = "s", cost = 0.5 }, { id = "grandchild", parentID = "child", cost = 0.25 },
			{ id = "unrelated", cost = 99 }, { id = "cycle-a", parentID = "cycle-b", cost = 99 }, { id = "cycle-b", parentID = "cycle-a", cost = 99 } }) do state.upsert_session(record, { touch = false }) end
		local cost, complete = selectors.session_cost()
		assert.equals(2.25, cost); assert.is_true(complete)
		assert.equals(0.5, selectors.session_cost("child"))
		state.upsert_session({ id = "unknown", parentID = "s" }, { touch = false })
		cost, complete = selectors.session_cost()
		assert.equals(2.25, cost); assert.is_false(complete)
		assert.is_nil(selectors.session_cost("unknown"))
		state.upsert_session({ id = "unknown", cost = 0 }, { touch = false })
		cost, complete = selectors.session_cost("unknown")
		assert.equals(0, cost); assert.is_true(complete)
		assert.is_nil(selectors.session_cost("missing"))
		local ids = state.get_session_ids(); ids[1] = "changed"
		assert.is_nil(state.get_session_record("changed"))
	end)
end)
