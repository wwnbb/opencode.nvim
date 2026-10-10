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

	it("withholds the preface until a fragmented standalone opening marker is complete", function()
		local raw = "Reasoning before the answer.\n<answer>\nL1 — Привет 世界"
		local marker_end = assert(raw:find("<answer>", 1, true)) + #"<answer>" - 1
		for index = 1, marker_end do
			assert.equals("", response.display(raw:sub(1, index), {}, { streaming = true }))
		end
		assert.equals("L1 — Привет 世界", response.display(raw, {}, { streaming = true }))
		assert.equals("", response.display("Use `<answer>` inline.\nUnmarked text", {}, { streaming = true }))
	end)

	it("hides fragmented closing markers and all trailing text during streaming", function()
		local prefix = "Preface\n<answer>\n**Значение** и `世界`\n  "
		local marker = "</answer>"
		for index = 1, #marker do
			assert.equals("**Значение** и `世界`",
				response.display(prefix .. marker:sub(1, index), {}, { streaming = true }))
		end
		local raw = prefix .. marker .. "\nReasoning after the answer.\n<ans"
		assert.equals("**Значение** и `世界`", response.display(raw, {}, { streaming = true }))
		assert.equals("**Значение** и `世界`", response.display(raw, {}))
		assert.equals("Literal </ans", response.display("<answer>\nLiteral </ans", {}, { streaming = true }))
	end)

	it("streams the current answer block after an earlier complete block", function()
		local raw = "<answer>\nDraft\n</answer>\nRevision preface\n<answer>\nFinal explanation"
		assert.equals("Final explanation", response.display(raw, {}, { streaming = true }))
		assert.equals("Final explanation", response.display(raw .. "\n</answer>\nAfter", {}))
	end)

	it("preserves arbitrary output when a custom prompt replaces the default", function()
		local raw = "Before\n<answer>\nL1 — Custom response\n</answer>\nAfter"
		assert.equals(raw, response.display(raw, {
			prompt = "Describe the selection however you like.", language = "en",
		}))
		assert.equals(raw, response.display(raw, { prompt = "Custom" }, { streaming = true }))
	end)
end)
