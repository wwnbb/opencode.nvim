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

	it("extends a range over highlights and widgets that cross either edge", function()
		local frame = {
			content = { { line = 2, end_line = 4, hl_group = "A" }, { line = 8, hl_group = "B" } },
			maps = { { widget = { start_line = 5, end_line = 7, highlights = { { line = 0, hl_group = "C" } } } } },
		}
		assert.same({ 2, 8 }, { render_state.extend_highlight_range(frame, 3, 6) })
		assert.same({ 8, 9 }, { render_state.extend_highlight_range(frame, 8, 9) })
		assert.same({ 2 }, { render_state.extend_highlight_range(frame, 4) })
	end)
end)
