local output = require("opencode.ui.chat.execute_output")

describe("execute output descriptions", function()
	it("renders object fields deterministically and expands decoded multiline strings", function()
		local raw = '{"title":"Example","main":"first\\nsecond","z":1,"a":false}'
		local result = output.describe(raw)
		assert.same({ "a: false", "main:", "  first", "  second", "title: Example", "z: 1" }, result.lines)
		assert.equals(raw, result.raw)
		assert.equals("json", result.kind)
		assert.equals("JSON", result.label)
		assert.equals(4, result.count)
		assert.equals("fields", result.count_label)
	end)

	it("preserves literal backslashes and only decodes a JSON escape once", function()
		local raw = [[{"path":"C:\\new\\notes","literal":"first\\nsecond"}]]
		local result = output.describe(raw)
		assert.same({ [[literal: first\nsecond]], [[path: C:\new\notes]] }, result.lines)
		assert.equals(raw, result.raw)
		assert.same({ [[first\nsecond]] }, output.describe([[first\nsecond]]).lines)
	end)

	it("keeps false, null, empty objects, and empty arrays distinct", function()
		local result = output.describe('{"missing":null,"ok":false,"object":{},"array":[]}')
		assert.same({ "array: []", "missing: null", "object: {}", "ok: false" }, result.lines)
		assert.same({ "- null", "- false", "- []", "- {}" }, output.describe("[null,false,[],{}]").lines)
		assert.same({ "null" }, output.describe("null").lines)
		assert.same({ "false" }, output.describe(false).lines)
		assert.same({ '""' }, output.describe('""').lines)
	end)

	it("serializes table values and reports an array count", function()
		local result = output.describe({ "one", false, vim.NIL })
		assert.same({ "one", false, vim.NIL }, vim.json.decode(result.raw))
		assert.same({ "- one", "- false", "- null" }, result.lines)
		assert.equals(3, result.count)
		assert.equals("items", result.count_label)
	end)

	it("summarizes a useful generic JSON field inside a screenshot-like wrapper", function()
		for _, fields in ipairs({
			{ '"main":' .. vim.json.encode(string.rep("Long page text\n", 200)), '"title":"Senior Engineer | Example"', '"apply":[{"href":"https://example.test/apply"}]' },
			{ '"apply":[{"href":"https://example.test/apply"}]', '"title":"Senior Engineer | Example"', '"main":' .. vim.json.encode(string.rep("Long page text\n", 200)) },
		}) do
			local raw = "Script ran on page and returned:\n```json\n{" .. table.concat(fields, ",") .. "}\n```\n\nLogs:\nfinished"
			local result = output.describe(raw)
			assert.equals("title: Senior Engineer | Example", result.summary)
			assert.equals(result.summary, output.describe(raw, { max_lines = 4, max_chars = 256 }).summary)
			assert.equals("Script ran on page and returned:", result.lines[1])
			assert.equals("finished", result.lines[#result.lines])
			assert.equals(raw, result.raw)
		end
		assert.equals("zebra: Useful", output.describe({ aardvark = { 1, 2 }, zebra = "Useful" }).summary)
		assert.equals("enabled: false", output.describe({ enabled = false, nested = { "text" } }).summary)
	end)

	it("uses a bounded first nonempty text line as the fallback summary", function()
		assert.equals("Useful line", output.describe("\n  \n  Useful line\nMore details").summary)
		assert.equals("Indented line", output.describe(string.rep(" ", 300) .. "Indented line\nOther").summary)
		assert.equals("false", output.describe(false).summary)
		local result = output.describe(string.rep("🌍", 100), { max_chars = 61 })
		assert.is_true(#result.summary <= 61)
		assert.is_true(pcall(vim.json.encode, result.summary))
		assert.equals("", output.describe("").summary)
	end)

	it("formats leading JSON followed by native logs or other trailing text", function()
		for _, suffix in ipairs({ "Logs:\nfinished", "Additional text:\nuntouched\\nvalue" }) do
			local raw = '{"text":"first\\nsecond","value":1}\n\n' .. suffix
			local result = output.describe(raw)
			local expected = { "text:", "  first", "  second", "value: 1", "" }
			vim.list_extend(expected, vim.split(suffix, "\n", { plain = true }))
			assert.same(expected, result.lines)
			assert.equals(raw, result.raw)
		end
		assert.same({ "false", "", "Logs:", "finished" }, output.describe("false\n\nLogs:\nfinished").lines)
	end)

	it("formats several fenced JSON values including scalar false and null", function()
		local result = output.describe("First:\n~~~json\nfalse\n~~~\nSecond:\n```JSON\nnull\n```")
		assert.same({ "First:", "false", "Second:", "null" }, result.lines)
	end)

	it("preserves Unicode and special JSON key names", function()
		local result = output.describe('{"ключ":"Привет 🌍\\n日本語","a\\nb":"value"}')
		assert.same({ [["a\nb": value]], '"ключ":', "  Привет 🌍", "  日本語" }, result.lines)
	end)

	it("bounds deep JSON formatting and retains data beyond the readable depth", function()
		local raw = string.rep('{"child":', 40) .. '"leaf"' .. string.rep("}", 40)
		local result = output.describe(raw, { max_depth = 4 })
		assert.equals(raw, result.raw)
		assert.is_true(result.truncated)
		assert.matches("depth limit", result.lines[#result.lines])
		assert.is_true(#result.lines <= 5)
	end)

	it("handles exceptionally deep and large raw values without recursive decoding", function()
		for _, raw in ipairs({ string.rep("[", 5000) .. "0" .. string.rep("]", 5000), string.rep("x", 2 * 1024 * 1024) }) do
			local result = output.describe(raw, { max_chars = 100, max_lines = 4 })
			assert.equals(raw, result.raw)
			assert.is_true(result.truncated)
			assert.is_true(#table.concat(result.lines) <= 100)
		end
	end)

	it("falls back safely for Lua values that cannot be JSON encoded", function()
		local value = { a = function() end }
		value.self = value
		local result = output.describe(value)
		assert.is_string(result.raw)
		assert.is_true(#result.lines > 0)
	end)

	it("provides generic field columns and a document with separate headings", function()
		local body = "First paragraph\n\nSecond paragraph\n" .. string.rep("More text. ", 30)
		local raw = vim.json.encode({ alpha = body, zebra = "An ordinary title" })
		local result = output.describe(raw)
		assert.equals("zebra: An ordinary title", result.lines[1])
		assert.equals("alpha:", result.lines[2])
		assert.same({
			{ key = "zebra", lines = { "An ordinary title" } },
			{ key = "alpha", lines = { "First paragraph", "", "Second paragraph", string.rep("More text. ", 30) } },
		}, result.fields)
		assert.same({ "zebra", "An ordinary title", "", "alpha", "First paragraph", "", "Second paragraph", string.rep("More text. ", 30) }, result.document_lines)
		assert.same({ 1, 4 }, result.document_headings)
		assert.equals(2, result.field_count)
		assert.same({}, result.prefix_lines)
		assert.same({}, result.suffix_lines)
		assert.equals(raw, result.raw)
	end)

	it("retains wrapper text and logs alongside a single fenced object's fields", function()
		local raw = 'Result from a tool:\n\n```json\n{"answer":false,"body":"one\\n\\ntwo"}\n```\n\nLogs:\nfinished\n'
		local result = output.describe(raw)
		assert.same({ "Result from a tool:", "", "answer: false", "body:", "  one", "  ", "  two", "", "Logs:", "finished", "" }, result.lines)
		assert.equals(raw, result.raw)
		assert.equals("markdown", result.filetype)
		assert.same({ "Result from a tool:", "" }, result.prefix_lines)
		assert.same({ "", "Logs:", "finished", "" }, result.suffix_lines)
		assert.same({
			{ key = "answer", lines = { "false" } },
			{ key = "body", lines = { "one", "", "two" } },
		}, result.fields)
		assert.same({ "Result from a tool:", "", "answer", "false", "", "body", "one", "", "two", "", "Logs:", "finished", "" }, result.document_lines)
		assert.same({ 3, 6 }, result.document_headings)
		assert.equals(2, result.field_count)
		assert.equals("Markdown", result.label)
	end)

	it("does not pretend several JSON blocks are one object, even in a short preview", function()
		local raw = 'First:\n```json\n{"first":1}\n```\nSecond:\n```json\n{"second":2}\n```'
		local result = output.describe(raw)
		assert.is_nil(result.fields)
		assert.same({ "First:", "first", "1", "Second:", "second", "2" }, result.document_lines)
		local preview = output.describe(raw, { max_lines = 3 })
		assert.is_nil(preview.fields)
		assert.is_true(preview.document_truncated)
		assert.is_true(#preview.document_lines <= 3)
	end)

	it("preserves structured values, Unicode keys, and JSON primitives in fields", function()
		local result = output.describe('{"ключ":"Привет 🌍\\n日本語","nested":{"active":false,"missing":null},"empty":{},"list":[1,false]}')
		assert.same({
			{ key = "empty", lines = { "{}" } },
			{ key = "list", lines = { "- 1", "- false" } },
			{ key = "nested", lines = { "active: false", "missing: null" } },
			{ key = "ключ", lines = { "Привет 🌍", "日本語" } },
		}, result.fields)
		assert.same({ 1, 4, 8, 12 }, result.document_headings)
		assert.same({ "null" }, output.describe("null").document_lines)
		assert.same({ "false" }, output.describe(false).document_lines)
		assert.is_nil(output.describe("[]").fields)
	end)

	it("bounds field and document previews together while keeping all raw bytes", function()
		local raw = vim.json.encode({ short = "Title", text = string.rep("Привет 🌍\n", 1000) })
		local result = output.describe(raw, { max_chars = 100, max_lines = 8 })
		assert.equals(raw, result.raw)
		assert.is_true(result.document_truncated)
		assert.is_true(#result.document_lines <= 8)
		assert.is_true(#table.concat(result.document_lines) <= 100)
		assert.equals(2, result.field_count)
		for _, line in ipairs(result.document_lines) do
			assert.is_true(pcall(vim.json.encode, line))
		end
		local field_chars, field_lines = 0, 0
		for _, field in ipairs(result.fields) do
			field_chars = field_chars + #field.key + #table.concat(field.lines)
			field_lines = field_lines + #field.lines + 1
		end
		assert.is_true(field_chars <= 100)
		assert.is_true(field_lines <= 8)
	end)
	it("preserves literal text and invalid JSON in compact and document views", function()
		for _, raw in ipairs({
			"  ```JSON\n{broken}\n  ```\nLogs: bad", "```json\n{broken", [[{"broken":"\escape"}]],
			"Example:\n````markdown\n```json\n{\"a\":1}\n```\n````\nDone.",
			"```json\n{broken}\n```\nLogs: bad", "```json\n{unfinished",
			"# Heading\n\nSome **text**.\n",
		}) do
			local result = output.describe(raw)
			local expected = vim.split(raw, "\n", { plain = true })
			assert.same(expected, result.lines, raw)
			assert.same(expected, result.document_lines, raw)
			assert.equals(raw, result.raw)
			assert.is_nil(result.fields)
			assert.same({}, result.document_headings)
		end
		assert.same({ "" }, output.describe(nil).lines)
	end)

	it("bounds text and JSON previews without dropping raw bytes or splitting UTF-8", function()
		for _, case in ipairs({
			{ raw = string.rep("a line\n", 1000), bytes = 200, lines = 6, prefix = "a line" },
			{ raw = string.rep("🌍", 100), bytes = 61, lines = 6, prefix = "🌍" },
			{ raw = vim.json.encode({ text = string.rep("example ", 1000) }), bytes = 200, lines = 6, prefix = "text: example example" },
		}) do
			local result = output.describe(case.raw, { max_chars = case.bytes, max_lines = case.lines })
			assert.equals(case.raw, result.raw)
			assert.is_true(result.truncated)
			assert.is_true(#result.lines <= case.lines)
			assert.matches(case.prefix, result.lines[1], 1, true)
			assert.matches("truncated", result.lines[#result.lines])
			assert.is_true(#table.concat(result.lines) <= case.bytes)
			for _, line in ipairs(result.lines) do assert.is_true(pcall(vim.json.encode, line)) end
		end
	end)

end)
