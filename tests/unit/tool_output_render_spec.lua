describe("tool output envelopes", function()
	for _, tool in ipairs({ "read", "glob", "grep", "rg" }) do
		it("preserves " .. tool .. " text and highlights across server output representations", function()
			local renderer = require("opencode.ui.chat." .. ((tool == "glob" or tool == "grep") and "search" or tool))
			local body = "first\r\n\27[31msecond\27[0m"
			local cases = {
				{ output = { output = body, content = "ignored" }, text = "first\nsecond" },
				{ output = { content = body }, text = "first\nsecond" },
				{ output = { output = "", content = "ignored" }, text = "" },
				{ output = { output = false, content = body }, text = "first\nsecond" },
				{ output = { count = 2 }, text = '{\n  count = 2\n}' },
				{ output = false, text = "false" },
				{ output = 0, text = "0" },
				{ output = vim.NIL, text = "" },
			}
			local function render(value, field)
				local state = { status = "completed", input = {} }
				state[field] = value
				local result = renderer.render_tool({ tool = tool, state = state }, true)
				assert.is_table(result)
				assert.is_true(#result.lines > 0)
				return result
			end
			for _, case in ipairs(cases) do
				for _, field in ipairs({ "output", "error" }) do
					local result = render(case.output, field)
					local visible = table.concat(result.lines, "\n")
					-- An empty/constant renderer must not satisfy only the equivalence check.
					for _, line in ipairs(vim.split(case.text, "\n", { plain = true })) do
						if line ~= "" then assert.is_truthy(visible:find(line, 1, true), "Missing: " .. line) end
					end
					assert.is_nil(visible:find("ignored", 1, true))
					assert.same(render(case.text, field), result)
				end
			end
		end)
	end
end)
