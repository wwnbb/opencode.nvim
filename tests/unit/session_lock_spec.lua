local locks = require("opencode.session.lock")

describe("session execution locks", function()
	local deepcopy = vim.deepcopy

	before_each(function()
		locks.clear_all()
	end)

	after_each(function()
		vim.deepcopy = deepcopy
		locks.clear_all()
	end)

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
		for _, id in pairs({ "", false, 1, {}, vim.NIL }) do
			assert.is_nil(locks.set(id, {}))
			assert.is_nil(locks.get(id))
			assert.is_false(locks.is_locked(id))
			locks.clear(id)
		end
		assert.is_nil(locks.set(nil, {}))
		assert.is_nil(locks.get(nil))
		assert.is_false(locks.is_locked(nil))
		locks.clear(nil)
		assert.is_nil(locks.set("child", false))
		assert.is_true(locks.is_locked("child"))
	end)

	it("checks existence without copying records", function()
		locks.set("child", { model = { modelID = "model" } })
		vim.deepcopy = function() error("Existence checks must not copy lock records") end
		assert.is_true(locks.is_locked("child"))
		assert.is_false(locks.is_locked("missing"))
	end)

	it("clears one lock or every lock", function()
		locks.set("child", {})
		locks.set("other", {})
		locks.clear("child")
		assert.is_false(locks.is_locked("child"))
		assert.is_true(locks.is_locked("other"))
		locks.clear_all()
		assert.is_false(locks.is_locked("other"))
	end)
end)
