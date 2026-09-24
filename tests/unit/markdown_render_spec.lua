local render = require("opencode.ui.chat.render")

describe("reference TUI Markdown layout", function()
	local old_width
	before_each(function()
		old_width = render.get_chat_text_width
		render.get_chat_text_width = function() return 80 end
	end)
	after_each(function() render.get_chat_text_width = old_width end)
	local function lines(source)
		return render.extract_lines(render.render_content(source))
	end
	local function body(source)
		local result = lines(source)
		for i, line in ipairs(result) do result[i] = line:sub(1, 3) == "   " and line:sub(4) or line end
		return table.concat(result, "\n")
	end
	local function styled(source, group)
		local result = render.render_content(source)
		local fragments = {}
		for _, span in ipairs(result._opencode_highlights) do
			if span.hl_group == group or vim.tbl_contains(vim.split(span.hl_group:gsub("^OpenCodeMarkdownCombined", ""), "_"), (group:gsub("^OpenCodeMarkdown", ""))) then
				fragments[#fragments + 1] = result[span.line + 1]:content():sub(span.col_start + 1, span.col_end)
			end
		end
		return table.concat(fragments)
	end

	it("renders the AST screenshot with hidden fences and preserved diagram/code indentation", function()
		local source = table.concat({
			"## Что такое AST", "", "AST — **Abstract Syntax Tree**, дерево операций.", "", "Например:", "",
			"```text", "1 + 2 * 3", "```", "", "Парсер строит AST:", "", "```text",
			"        Add", "       /   \\", "    Num(1) Mul", "           /  \\", "        Num(2) Num(3)", "```", "",
			"В Rust это выглядит так:", "", "```rust", "Expr::Add(", "    Box::new(Expr::Num(1.0)),", ")", "```", "",
			"---", "", "## Определение узлов AST",
		}, "\n")
		assert.same({
			"   Что такое AST", "", "   AST — Abstract Syntax Tree, дерево операций.", "", "   Например:", "",
			"   1 + 2 * 3", "", "   Парсер строит AST:", "", "           Add", "          /   \\",
			"       Num(1) Mul", "              /  \\", "           Num(2) Num(3)", "", "   В Rust это выглядит так:", "",
			"   Expr::Add(", "       Box::new(Expr::Num(1.0)),", "   )", "", "   " .. string.rep("─", 77), "", "   Определение узлов AST",
		}, lines(source))
		assert.equals("Что такое ASTОпределение узлов AST", styled(source, "OpenCodeMarkdownHeading"))
		assert.equals("Abstract Syntax Tree", styled(source, "OpenCodeMarkdownStrong"))
	end)

	-- Expected bodies copied from OpenTUI Markdown.test.ts top-level snapshots.
	it("matches upstream block-spacing snapshots", function()
		local fixtures = {
			{ "# Title\n\nParagraph\n\n```ts\nconst x = 1\n```", "Title\n\nParagraph\n\nconst x = 1" },
			{ "Paragraph:\n- one\n- two", "Paragraph:\n\n- one\n- two" },
			{ "1. one\n2. two\n\nParagraph after list", "1. one\n2. two\n\nParagraph after list" },
			{ "```ts\nconst x = 1\n```\nParagraph", "const x = 1\n\nParagraph" },
			{ "- Main section:\n  - Supporting point:\n    - Third-level detail\n    - Another detail with **emphasis**\n- Second section:\n  - Short detail",
			  "- Main section:\n  - Supporting point:\n    - Third-level detail\n    - Another detail with emphasis\n- Second section:\n  - Short detail" },
			{ "- Lead-in\n\n  - Nested\n- Next", "- Lead-in\n  - Nested\n- Next" },
		}
		for _, fixture in ipairs(fixtures) do assert.equals(fixture[2], body(fixture[1]), fixture[1]) end
	end)

	it("uses parsed inline syntax, preserves literals and follows link conceal rules", function()
		assert.equals("bold italic strike code a_b_c", body("**bold** *italic* ~~strike~~ `code` a_b_c"))
		assert.equals("\\*literal\\* and **code**", body("\\*literal\\* and `**code**`"))
		assert.equals("site (https://example.com) alt < > &", body("[site](https://example.com) ![alt](a.png) &lt; &gt; &amp;"))
		assert.equals("bold", styled("**bold**", "OpenCodeMarkdownStrong"))
		assert.equals("italic", styled("*italic*", "OpenCodeMarkdownEmphasis"))
		assert.equals("title", styled("# title", "OpenCodeMarkdownHeading1"))
		assert.equals("title\n-----", body("title\n-----"))
		assert.equals("not closed **yet", body("not closed **yet"))
		assert.equals("not closed yet", body("not closed **yet**"))
	end)

	it("renders code literally, including open fences, nested lists and unknown languages", function()
		assert.equals("**literal**\n# heading", body("```missing_parser\n**literal**\n# heading"))
		assert.equals("intro\n\nreturn 1", body("intro\n\n  ~~~lua\n  return 1\n  ~~~"))
		assert.equals("- code:\n  return 1", body("- code:\n  ```lua\n  return 1\n  ```"))
		assert.equals("intro\n\nreturn 1\nreturn 2", body("intro\n\n    return 1\n    return 2"))
		assert.equals("│   a\n│   b\n│ ", body("> ```lua\n>   a\n>   b\n> ```"))
		assert.equals("- intro\n    a\n    b", body("- intro\n    ```lua\n      a\n      b\n    ```"))
	end)

	it("renders quotes, lists, full-width grid tables and empty cells", function()
		assert.equals("│ Note\n│ continued\n│ \n│ next", body("> **Note**\n> continued\n>\n> next"))
		assert.equals(" 9. one\n10. two", body("9) one\n9) two"))
		render.get_chat_text_width = function() return 14 end
		assert.equals("┌─────┬───┐\n│Name │Age│\n├─────┼───┤\n│Alice│30 │\n├─────┼───┤\n│Bob  │5  │\n└─────┴───┘",
			body("| Name | Age |\n|---|---|\n| Alice | 30 |\n| Bob | 5 |"))
		render.get_chat_text_width = function() return 8 end
		assert.equals("┌─┬─┐\n│A│B│\n├─┼─┤\n│X│ │\n├─┼─┤\n│ │Y│\n└─┴─┘", body("| A | B |\n|---|---|\n| X | |\n| | Y |"))
		render.get_chat_text_width = old_width
		assert.equals("| Only | Header |\n|---|---|", body("| Only | Header |\n|---|---|"))
	end)

	it("wraps Unicode and maps emphasis/code highlights to visible byte ranges", function()
		render.get_chat_text_width = function() return 18 end
		local source = "**Привет 世界 hello world**\n\n```lua\nlocal n = 'Привет 世界'\n```"
		local result = render.render_content(source)
		for _, line in ipairs(result) do assert.is_true(vim.fn.strdisplaywidth(line:content()) <= 18) end
		assert.is_truthy(styled(source, "OpenCodeMarkdownStrong"):find("Привет", 1, true))
		for _, span in ipairs(result._opencode_highlights) do
			assert.is_true(span.col_start >= 3)
			assert.is_true(span.col_end <= #result[span.line + 1]:content())
		end
	end)

	it("refreshes theme-derived defaults while preserving explicit highlight overrides", function()
		local function_hl = vim.api.nvim_get_hl(0, { name = "Function", link = true })
		local original_strong = vim.api.nvim_get_hl(0, { name = "OpenCodeMarkdownStrong", link = true })
		vim.api.nvim_set_hl(0, "Function", { fg = 0x123456 })
		vim.api.nvim_set_hl(0, "OpenCodeMarkdownStrong", { fg = 0xabcdef, bold = true })
		require("opencode.ui.highlights").refresh()
		local heading = vim.api.nvim_get_hl(0, { name = "OpenCodeMarkdownHeading1", link = false })
		local strong = vim.api.nvim_get_hl(0, { name = "OpenCodeMarkdownStrong", link = false })
		vim.api.nvim_set_hl(0, "Function", function_hl)
		vim.api.nvim_set_hl(0, "OpenCodeMarkdownStrong", original_strong)
		require("opencode.ui.highlights").refresh()
		assert.equals(0x123456, heading.fg)
		assert.is_true(heading.bold)
		assert.is_true(heading.underline)
		assert.equals(0xabcdef, strong.fg)
	end)

	it("uses OpenTUI's two-cell tabs instead of the editor's tabstop", function()
		assert.equals("a  b\n\n  return 1", body("a\tb\n\n```lua\n\treturn 1\n```"))
	end)

	it("keeps content visible if Markdown parsers are unavailable", function()
		local original = vim.treesitter.get_string_parser
		vim.treesitter.get_string_parser = function() error("missing parser") end
		local ok, result = pcall(render.render_content, "# Hello\n\n**world**")
		vim.treesitter.get_string_parser = original
		assert.is_true(ok, result)
		assert.same({ "   # Hello", "   ", "   **world**" }, render.extract_lines(result))
		assert.is_true(result._opencode_syntax_retry)
	end)
end)
