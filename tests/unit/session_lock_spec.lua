local locks = require("opencode.session.lock")

describe("session execution locks", function()
	local state, pending, sync = require("opencode.state"), require("opencode.session.pending"), require("opencode.sync")
	before_each(function() state.reset(); pending.clear_all(); sync.clear_all(); locks.clear_all() end)
	after_each(function() state.reset(); pending.clear_all(); sync.clear_all(); locks.clear_all() end)

	local function fetch(session, messages)
		return {
			get_session = function(_, callback) callback(nil, session) end,
			load_messages = function(_, _, callback) callback(nil, messages or {}) end,
			tool_part = function(part) return part end,
		}
	end

	it("isolates stored records from inputs and returned values", function()
		local record = { session_id = "other", model = { modelID = "original" } }
		local result = locks.set("child", record)
		assert.equals("child", result.session_id)
		assert.equals("other", record.session_id)
		record.model.modelID = "input changed"
		result.model.modelID = "result changed"
		local fetched = locks.get("child")
		assert.equals("original", fetched.model.modelID)
		fetched.model.modelID = "read changed"
		assert.equals("original", locks.get("child").model.modelID)
	end)

	it("rejects invalid IDs and records", function()
		locks.set("child", {})
		for _, id in pairs({ "", 1, vim.NIL }) do
			assert.is_nil(locks.set(id, {}))
			assert.is_false(locks.is_locked(id))
		end
		assert.is_nil(locks.set("child", false))
		assert.is_true(locks.is_locked("child"))
	end)

	it("resolves agent and model without a chat view", function()
		local result
		locks.resolve("child", { state = { input = { subagent_type = "explore" } } },
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
		locks.resolve("child", { state = {} }, fetch({ id = "child" }, { { info = { role = "assistant", agent = "build" } } }),
			function(err, record) result = { err = err, record = record } end)
		assert.equals("build", result.record.agent)
		assert.is_nil(result.record.model)
		assert.is_true(result.record.pending)
		assert.matches("execution model", result.record.error, 1, true)
	end)

	it("rejects metadata for another session", function()
		local result
		locks.resolve("child", { state = {} }, fetch({ id = "other" }), function(err) result = err end)
		assert.matches("does not match", result.message, 1, true)
	end)
end)
