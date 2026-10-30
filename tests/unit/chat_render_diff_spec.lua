local render_state = require("opencode.ui.chat.render_state")

describe("chat render line diff", function()
	local function diff(old, new)
		return { render_state.diff_lines(old, new) }
	end

	it("reports an empty range for identical lines", function()
		assert.same({ 3, 3, 3 }, diff({ "a", "b", "c" }, { "a", "b", "c" }))
		assert.same({ 0, 0, 0 }, diff({}, {}))
	end)

	it("keeps the common suffix out of a change near the top", function()
		assert.same({ 0, 0, 1 }, diff({ "b", "c" }, { "a", "b", "c" }))
		assert.same({ 1, 2, 2 }, diff({ "a", "b", "c" }, { "a", "B", "c" }))
		assert.same({ 1, 2, 4 }, diff({ "a", "b", "c", "d" }, { "a", "x", "y", "z", "c", "d" }))
	end)

	it("handles appends, truncation and deletions", function()
		assert.same({ 2, 2, 3 }, diff({ "a", "b" }, { "a", "b", "c" }))
		assert.same({ 2, 3, 2 }, diff({ "a", "b", "c" }, { "a", "b" }))
		assert.same({ 1, 3, 1 }, diff({ "a", "b", "c", "d" }, { "a", "d" }))
		assert.same({ 0, 0, 2 }, diff({}, { "a", "b" }))
		assert.same({ 0, 2, 0 }, diff({ "a", "b" }, {}))
	end)

	it("never overlaps prefix and suffix on repeated lines", function()
		assert.same({ 2, 2, 3 }, diff({ "a", "a" }, { "a", "a", "a" }))
		assert.same({ 2, 3, 2 }, diff({ "", "", "" }, { "", "" }))
		assert.same({ 2, 2, 3 }, diff({ "x", "" }, { "x", "", "" }))
	end)
end)
