local syntax = require("opencode.ui.syntax")

describe("syntax source projection", function()
	it("clips multiline captures to wrapped rows without coloring prefixes or hidden lines", function()
		local source = { "αbc def", "hidden", "tail" }
		local result = syntax.project_highlights({
			{ line = 0, col_start = 2, end_line = 2, end_col = 3, hl_group = "String", priority = 4100 },
		}, source, {
			{ { line_index = 4, byte_start = 0, byte_end = 4, prefix = "┃  " },
				{ line_index = 5, byte_start = 5, byte_end = 8, prefix = "┃  " } },
			{},
			{ { line_index = 7, byte_start = 0, byte_end = 4, col_offset = 2 } },
		})
		assert.same({
			{ line = 4, col_start = 7, col_end = 9, hl_group = "String", priority = 4100 },
			{ line = 5, col_start = 5, col_end = 8, hl_group = "String", priority = 4100 },
			{ line = 7, col_start = 2, col_end = 5, hl_group = "String", priority = 4100 },
		}, result)
	end)

	it("handles exclusive end rows and captures extending beyond the visible source", function()
		local rows = { { { line_index = 0, byte_end = 3 } }, { { line_index = 1, byte_end = 3 } } }
		local source = { "abc", "def" }
		local result = syntax.project_highlights({ { line = 0, end_line = 1, end_col = 0, hl_group = "String" } }, source, rows)
		assert.equals(1, #result)
		assert.equals(3, result[1].col_end)
		result = syntax.project_highlights({ { line = 0, end_line = 3, end_col = 1, hl_group = "String" } }, source, rows)
		assert.equals(3, result[2].col_end)
	end)
end)
