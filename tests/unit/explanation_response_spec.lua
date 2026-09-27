local response = require("opencode.explanation.response")

describe("selection explanation response", function()
	it("shows only the last complete standalone answer block for the default prompt", function()
		local raw = table.concat({
			"The user wants an explanation in Russian.",
			"<answer>",
			"L1–2 — Draft explanation.",
			"</answer>",
			"I should be more concise.",
			"<answer>",
			"L1–2 — Импортируются типы выражений и токенов для парсера.",
			"</answer>",
			"Keep it concise and in Russian.",
		}, "\n")
		assert.equals("L1–2 — Импортируются типы выражений и токенов для парсера.",
			response.display(raw, { language = "ru" }))
	end)

	it("leaves an unmarked answer visible, including incomplete line ranges", function()
		local raw = "L1 — Импортируется AST; остальная строка не описана."
		assert.equals(raw, response.display(raw, { language = "ru" }))
	end)

	it("does not interpret inline or incomplete answer markers", function()
		local inline = "Use `<answer>` as a literal string in this explanation."
		assert.equals(inline, response.display(inline, { language = "ru" }))
		local unclosed = "The model wrote:\n<answer>\nL1–2 — Explanation"
		assert.equals(unclosed, response.display(unclosed, { language = "ru" }))
	end)

	it("preserves arbitrary output when a custom prompt replaces the default", function()
		local raw = "Before\n<answer>\nL1 — Custom response\n</answer>\nAfter"
		assert.equals(raw, response.display(raw, {
			prompt = "Describe the selection however you like.", language = "en",
		}))
	end)
end)
