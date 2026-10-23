describe("child session lock resolution", function()
	local lock = require("opencode.session.lock")
	local state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local sync = require("opencode.sync")

	before_each(function() state.reset(); pending.clear_all(); sync.clear_all(); lock.clear_all() end)
	after_each(function() state.reset(); pending.clear_all(); sync.clear_all(); lock.clear_all() end)

	local function fetch(session, messages)
		return {
			get_session = function(_, callback) callback(nil, session) end,
			load_messages = function(_, _, callback) callback(nil, messages or {}) end,
			tool_part = function(part) return part end,
		}
	end

	it("resolves agent and model without a chat view", function()
		local result
		lock.resolve("child", { state = { input = { subagent_type = "explore" } } },
			fetch({ id = "child", title = "Child", model = { providerID = "p", id = "m", variant = "high" } }),
			function(err, record) result = { err = err, record = record } end)
		assert.is_nil(result.err)
		assert.equals("explore", result.record.agent)
		assert.same({ providerID = "p", modelID = "m" }, result.record.model)
		assert.equals("high", result.record.variant)
		assert.is_nil(result.record.error)
	end)

	it("falls back to message metadata and reports a missing model", function()
		local result
		lock.resolve("child", { state = {} }, fetch({ id = "child" }, { { info = { role = "assistant", agent = "build" } } }),
			function(err, record) result = { err = err, record = record } end)
		assert.equals("build", result.record.agent)
		assert.is_nil(result.record.model)
		assert.is_true(result.record.pending)
		assert.matches("execution model", result.record.error, 1, true)
	end)

	it("rejects metadata for another session", function()
		local result
		lock.resolve("child", { state = {} }, fetch({ id = "other" }), function(err) result = err end)
		assert.matches("does not match", result.message, 1, true)
	end)
end)
