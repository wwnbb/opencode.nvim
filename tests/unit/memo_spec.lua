local memo = require("opencode.util.memo")

describe("shared render memo budget", function()
	before_each(memo.clear_all)
	after_each(memo.clear_all)

	it("replaces revisions of one owner and rejects the previous signature", function()
		local cache = memo.new("memo-test-owner", { max_entries = 2 })
		cache:put("owner", 1, { text = "before" })
		local before = cache:stats().bytes
		cache:put("owner", 2, { text = "after!" })
		assert.is_nil(cache:get("owner", 1))
		assert.same({ text = "after!" }, cache:get("owner", 2))
		assert.equals(1, cache:stats().entries)
		assert.equals(before, cache:stats().bytes)
	end)

	it("retains each namespace entry cap while sharing global FIFO eviction", function()
		local a = memo.new("memo-test-cap", { max_entries = 2 })
		local b = memo.new("memo-test-neighbor", { max_entries = 2 })
		a:put("a", 1, {})
		b:put("b", 1, {})
		a:put("c", 1, {})
		a:put("d", 1, {})
		assert.is_nil(a:get("a", 1))
		assert.is_not_nil(a:get("c", 1))
		assert.is_not_nil(b:get("b", 1))
		assert.equals(3, memo.stats().entries)
		a:clear()
		assert.equals(1, memo.stats().entries)
		b:delete("b")
		assert.equals(0, memo.stats().bytes)
	end)

	it("evicts across namespaces to enforce one 16 MiB aggregate budget", function()
		local a = memo.new("memo-test-budget-a")
		local b = memo.new("memo-test-budget-b")
		local value = string.rep("x", 9 * 1024 * 1024)
		a:put("a", 1, value)
		b:put("b", 1, value)
		assert.is_nil(a:get("a", 1))
		assert.equals(value, b:get("b", 1))
		assert.equals(16 * 1024 * 1024, memo.stats().max_bytes)
		assert.is_true(memo.stats().bytes <= memo.stats().max_bytes)
	end)

	it("returns oversized data intact without retaining it or an obsolete revision", function()
		local cache = memo.new("memo-test-oversize")
		cache:put("owner", 1, "old")
		local value = string.rep("x", 16 * 1024 * 1024)
		local returned, retained = cache:put("owner", 2, value)
		assert.equals(value, returned)
		assert.is_false(retained)
		assert.is_nil(cache:get("owner", 1))
		assert.is_nil(cache:get("owner", 2))
		assert.equals(0, cache:stats().entries)
	end)

	it("counts keys, signatures and retained nested snapshots", function()
		local cache = memo.new("memo-test-estimate")
		local value = { snapshot = { output = string.rep("x", 2048) }, lines = { "shown" } }
		cache:put(string.rep("k", 100), string.rep("s", 200), value)
		assert.is_true(cache:stats().bytes > 2348)
		local cyclic = {}; cyclic.self = cyclic
		assert.is_true(memo.estimate(cyclic) > 0)
		cache:put("owner", 1, {}, 50)
		assert.is_true(cache:stats().bytes > memo.estimate(value))
	end)

	it("accounts compact dense arrays without charging hash nodes for every slot", function()
		local tuples, records = {}, {}
		for index = 1, 100 do
			tuples[index] = { index, 0, 10, "Highlight" }
			records[index] = { line = index, col_start = 0, col_end = 10, hl_group = "Highlight" }
		end
		assert.is_true(memo.estimate(tuples) < memo.estimate(records))
		local original = memo.estimate(tuples)
		tuples[1000000] = string.rep("x", 4096)
		assert.is_true(memo.estimate(tuples) > original + 4096)
		tuples.extra = { snapshot = string.rep("y", 2048) }
		assert.is_true(memo.estimate(tuples) > original + 4096 + 2048)
		local cyclic = { false }; cyclic[2] = cyclic
		assert.is_true(memo.estimate(cyclic) > memo.estimate({}))
	end)
end)
