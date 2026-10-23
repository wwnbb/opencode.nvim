describe("widget_base panel builders", function()
	local widget_base = require("opencode.ui.widget_base")
	local helpers = require("opencode.ui.panel").create_helpers({ prefix = "▏  ", blank_prefix = "▏", default_hl = "Normal" })
	local function trimmed(lines)
		return vim.tbl_map(function(line) return (line:gsub("%s+$", "")) end, lines)
	end

	it("creates results that carry the renderer options", function()
		local render = {}
		assert.same({ lines = {}, highlights = {}, width = 40, render = render }, widget_base.new_result({ width = 40, render = render }))
		assert.same({ lines = {}, highlights = {} }, widget_base.new_result())
	end)

	it("numbers options, records their rows and marks only the selected marker", function()
		local result = widget_base.new_result()
		result.lines[1] = "header"
		local lines, ends = widget_base.append_options(result, { "One", "Two" }, function(i) return i == 2 end,
			function(_, selected) return selected and ">" or " " end, {
				add_raw_line = helpers.add_raw_line, highlight_text = helpers.highlight_text,
				selected_hl = "Sel", option_hl = "Opt", marker_hl = "Mark",
			})
		assert.same({ 1, 2 }, lines)
		assert.same({ 1, 2 }, ends)
		assert.same({ "header", "▏    1. One", "▏  > 2. Two" }, trimmed(result.lines))
		local marks = vim.tbl_filter(function(hl) return hl.hl_group == "Mark" end, result.highlights)
		assert.equals(1, #marks)
		assert.equals(2, marks[1].line)
	end)

	it("adds status headers with the title highlighted", function()
		local result = widget_base.new_result()
		widget_base.add_status_header(helpers, result, "# Question", "Pick", "(1/2)", "Head", "Title")
		assert.same({ "▏  # Question Pick (1/2)" }, trimmed(result.lines))
		local title = vim.tbl_filter(function(hl) return hl.hl_group == "Title" end, result.highlights)[1]
		assert.equals(#"▏  # Question ", title.col_start)
		result = widget_base.new_result()
		widget_base.add_status_header(helpers, result, "# Question", "", nil, "Head", "Title")
		assert.same({ "▏  # Question" }, trimmed(result.lines))
	end)

	it("builds the select and move hint parts from chat keys", function()
		local select_part, move_part = widget_base.selection_hint(3)
		local keymaps = require("opencode.util.keymap")
		assert.equals(keymaps.number_labels("chat", 1, 3) .. " select", select_part)
		assert.equals(keymaps.label("chat", "widget_prev") .. " / " .. keymaps.label("chat", "widget_next") .. " move", move_part)
	end)
end)
