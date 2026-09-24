local rg = require("opencode.ui.chat.rg")

local function lines_for(state, expanded)
	local result = rg.render_tool({ tool = "rg", state = state }, expanded)
	return vim.tbl_map(function(line)
		return line:gsub(" +$", "")
	end, result.lines), result
end

describe("rg custom tool rendering", function()
	it("collapses to its summary and expands to arguments and complete output", function()
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
		assert.equals(" ✱ rg [pattern=Expr, path=src]", lines[1])
		assert.equals("  pattern: Expr", lines[2])
		assert.equals("  path: src", lines[3])
		assert.equals("  output: " .. output[1], lines[4])
		for i = 2, #output do
			assert.equals(output[i] == "" and "" or "          " .. output[i], lines[i + 3])
		end
		assert.same({ " ✱ rg [pattern=Expr, path=src]", "" }, lines_for(state, false))
	end)

	it("wraps output under its value column without losing text", function()
		local value = string.rep("x", 150)
		local lines = lines_for({ status = "completed", output = value }, true)
		assert.equals("  output: " .. string.rep("x", 70), lines[2])
		assert.equals("          " .. string.rep("x", 70), lines[3])
		assert.equals("          " .. string.rep("x", 10), lines[4])
	end)

	it("uses the reference argument order and preserves false options", function()
		local lines = lines_for({
			status = "completed",
			input = { pattern = "x", path = "src", glob = "*.rs", context = 2, max_results = 200, hidden = false },
		}, true)
		local fields = table.concat(lines, "\n")
		assert.is_truthy(fields:find("  context: 2\n  max_results: 200\n  hidden: false\n", 1, true))
		assert.is_truthy(fields:find("  output: No matches found.", 1, true))
	end)

	it("shows running, failed and interrupted calls without a success marker", function()
		for _, status in ipairs({ "pending", "running" }) do
			assert.same({ " ✱ rg", "" }, lines_for({ status = status }))
		end
		local lines, result = lines_for({ status = "error", error = "ripgrep failed (2):\n    invalid regex" }, true)
		assert.same({ " ✗ rg", "  error: ripgrep failed (2):", "             invalid regex", "" }, lines)
		assert.is_true(vim.tbl_contains(vim.tbl_map(function(hl)
			return hl.hl_group
		end, result.highlights), "OpenCodeRgFailure"))
		assert.same({ " ✗ rg", "  error: Tool execution interrupted", "" },
			lines_for({ status = "error", error = "Tool execution interrupted" }, true))
		assert.same({ " ✗ rg", "" }, lines_for({ status = "error", error = "Tool execution interrupted" }, false))
	end)

	it("renders native recorded success, no matches and failure results", function()
		local fixture = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/rg/nvim-rg.json"), "\n"))
		for _, state in ipairs(fixture.results) do
			local lines = lines_for(state, true)
			local text = table.concat(lines, "\n")
			assert.equals(state.status == "completed" and "✱" or "✗", vim.fn.strcharpart(lines[1], 1, 1))
			assert.is_truthy(text:find(state.status == "error" and "  error: " or "  output: ", 1, true))
		end
	end)
end)
