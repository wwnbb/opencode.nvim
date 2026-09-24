local blocks = require("opencode.ui.code_blocks")

describe("fenced source blocks", function()
	it("keeps incomplete code and accepts only a matching sufficiently long closing fence", function()
		local parsed = blocks.parse("before\n````rust\nfn main() {\n```\n~~~\n}")
		assert.equals(1, #parsed)
		assert.is_false(parsed[1].closed)
		assert.same({ "fn main() {", "```", "~~~", "}" }, parsed[1].lines)
		assert.equals(2, parsed[1].start_line)
		local closed = blocks.parse("~~~lua\nreturn 1\n~~~~ \t\nafter")
		assert.is_true(closed[1].closed)
		assert.equals(2, closed[1].end_line)
	end)

	it("removes fence indentation with byte offsets and rejects invalid openers", function()
		local parsed = blocks.parse("  ```lua\n  local a = 1\n return a\n  ```")
		assert.same({ "local a = 1", "return a" }, parsed[1].lines)
		assert.same({ 2, 1 }, parsed[1].offsets)
		assert.same({}, blocks.parse("    ```lua\nreturn 1"))
		assert.same({}, blocks.parse("```lu`a\nreturn 1"))
		assert.same({}, blocks.parse("> ```lua\n> return 1"))
	end)

	it("handles fences and language names split at every streaming boundary", function()
		local source = "```lua\nreturn 1\n```\nafter"
		for ending = 1, #source do
			local snapshot = source:sub(1, ending)
			local parsed = blocks.parse(snapshot)
			if ending >= 3 then assert.equals(1, #parsed) end
			if ending >= 8 and ending < 17 then assert.is_false(parsed[1].closed) end
		end
		local closed = blocks.parse("```lua\nreturn 1\n```")
		assert.is_true(closed[1].closed)
		local reopened = blocks.parse("```lua\nreturn 1\n```x")
		assert.is_false(reopened[1].closed)
	end)

	it("normalizes CRLF and sanitizes only non-line-ending control characters", function()
		assert.equals("```lua\nreturn 1\n```", blocks.normalize_text("```lua\r\nreturn 1\r\n```"))
		assert.equals("a ↵ b<NUL>", blocks.normalize_text("a\rb\0"))
	end)
end)
