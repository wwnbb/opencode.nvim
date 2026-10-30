local rg = require("opencode.ui.chat.rg")

local function lines_for(state, expanded)
	local result = rg.render_tool({ tool = "rg", state = state }, expanded)
	return vim.tbl_map(function(line)
		return line:gsub(" +$", "")
	end, result.lines), result
end

describe("rg custom tool rendering", function()

	it("collapses to its summary and frames arguments and complete output when expanded", function()
		local output = { "src/ast.rs-15-    pub fn eval(&self) {", "src/ast.rs:16:        match self {", "--", "" }
		for i = 1, 12 do
			output[#output + 1] = "src/parser.rs:" .. i .. ":    parse()"
		end
		local state = {
			status = "completed",
			input = { pattern = "Expr", path = "src" },
			output = table.concat(output, "\n"),
		}
		local lines = lines_for(state, true)
		assert.equals(" ○ rg [pattern=Expr, path=src]", lines[1])
		assert.is_truthy(lines[2]:find("   ┌", 1, true))
		assert.equals("   │ pattern: Expr", lines[3])
		assert.equals("   │ path: src", lines[4])
		assert.equals("   │", lines[5])
		assert.equals("   │ " .. output[1], lines[6])
		for i = 2, #output do
			assert.equals(output[i] == "" and "   │" or "   │ " .. output[i], lines[i + 5])
		end
		assert.same({ " ● rg [pattern=Expr, path=src]", "" }, lines_for(state, false))
		state.input = { pattern = "x", path = "src", glob = "*.rs", context = 2, max_results = 200, hidden = false }
		state.output = nil
		local fields = table.concat(lines_for(state, true), "\n")
		assert.is_truthy(fields:find("   │ context: 2\n   │ max_results: 200\n   │ hidden: false\n", 1, true))
		assert.is_truthy(fields:find("   │ No matches found.", 1, true))
	end)

	it("wraps framed output without losing text", function()
		local value = string.rep("x", 150)
		local lines = lines_for({ status = "completed", output = value }, true)
		assert.is_truthy(lines[2]:find("   ┌", 1, true))
		assert.equals("   │ " .. string.rep("x", 75), lines[3])
		assert.equals("   │ " .. string.rep("x", 75), lines[4])
		assert.is_truthy(lines[5]:find("   └", 1, true))
	end)

	it("shows running, failed and interrupted calls without a success marker", function()
		for _, status in ipairs({ "pending", "running" }) do
			local lines = lines_for({ status = status })
			assert.equals(2, #lines)
			local frame = lines[1]:match("^ ● rg (.+)$")
			assert.is_true(vim.tbl_contains(require("opencode.ui.chat.tool_panel").ANIM_FRAMES, frame), lines[1])
		end
		local lines, result = lines_for({ status = "error", error = "ripgrep failed (2):\n    invalid regex" }, true)
		assert.equals(" ○ rg", lines[1])
		assert.equals("   │ error: ripgrep failed (2):", lines[3])
		assert.equals("   │            invalid regex", lines[4])
		assert.is_true(vim.tbl_contains(
			vim.tbl_map(function(hl)
				return hl.hl_group
			end, result.highlights),
			"OpenCodeExploreOutputError"
		))
		-- Folded, the error reads like the other exploration rows: indented sub-lines.
		assert.same({ " ● rg", "     ripgrep failed (2):", "         invalid regex", "" },
			lines_for({ status = "error", error = "ripgrep failed (2):\n    invalid regex" }, false))
		assert.same({ " ● rg", "     Tool execution interrupted", "" },
			lines_for({ status = "error", error = "Tool execution interrupted" }, false))
	end)

	it("renders native recorded success, no matches and failure results", function()
		local fixture = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/rg/nvim-rg.json"), "\n"))
		for _, state in ipairs(fixture.results) do
			local lines = lines_for(state, true)
			local text = table.concat(lines, "\n")
			assert.equals("○", vim.fn.strcharpart(lines[1], 1, 1))
			assert.is_truthy(text:find("   ┌", 1, true))
			if state.status == "error" then assert.is_truthy(text:find("   │ error: ", 1, true)) end
		end
	end)
end)
