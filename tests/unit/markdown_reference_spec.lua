local render = require("opencode.ui.chat.render")
local fixture = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/markdown/tui.json"), "\n"))

describe("OpenTUI 0.4.1 text-renderer oracle", function()
	local original_width, originals
	local names = { "Heading", "Heading1", "Strong", "Emphasis", "Strike", "Code", "Link", "LinkText",
		"Quote", "Border", "List", "Punctuation", "Escape", "Entity" }
	before_each(function()
		original_width, originals = render.get_chat_text_width, {}
		require("opencode.ui.markdown.styles")
		for index, name in ipairs(names) do
			local group = "OpenCodeMarkdown" .. name
			originals[group] = vim.api.nvim_get_hl(0, { name = group, link = true })
			local attrs = vim.api.nvim_get_hl(0, { name = group, link = false })
			attrs.fg = index
			vim.api.nvim_set_hl(0, group, attrs)
		end
		originals.OpenCodeMarkdownText = vim.api.nvim_get_hl(0, { name = "OpenCodeMarkdownText", link = true })
		vim.api.nvim_set_hl(0, "OpenCodeMarkdownText", { fg = 0xeeeeee })
		require("opencode.ui.highlights").refresh()
	end)
	after_each(function()
		render.get_chat_text_width = original_width
		for name, attrs in pairs(originals) do vim.api.nvim_set_hl(0, name, attrs) end
		require("opencode.ui.highlights").refresh()
	end)

	for _, case in ipairs(fixture.cases) do
		it(case.name .. " at " .. case.width .. " columns", function()
			render.get_chat_text_width = function() return case.width end
			local result = render.render_content(case.source)
			local actual = {}
			for _, line in ipairs(result) do actual[#actual + 1] = line:content():gsub("%s+$", "") end
			while actual[#actual] == "" do table.remove(actual) end
			if #actual == 0 then actual[1] = "" end
			assert.same(case.lines, actual)
			local styles = {}
			for _, span in ipairs(result._opencode_highlights) do
				local attrs = vim.api.nvim_get_hl(0, { name = span.hl_group, link = false })
				local row = span.line + 1
				styles[row] = styles[row] or {}
				local value = { attrs.fg or 0xeeeeee, (attrs.bold and 1 or 0) + (attrs.italic and 4 or 0) + (attrs.underline and 8 or 0) }
				for col = span.col_start + 1, span.col_end do styles[row][col] = value end
			end
			for row, spans in ipairs(case.styles) do
				local column, byte = 0, 1
				for index = 0, vim.fn.strchars(actual[row], true) - 1 do
					local char = vim.fn.strcharpart(actual[row], index, 1, true)
					if not char:match("^%s+$") then
						for _, span in ipairs(spans) do
							if column >= span[1] and column < span[2] then
								assert.same({ span[3], span[4] }, styles[row] and styles[row][byte] or { 0xeeeeee, 0 },
									"style at row " .. row .. ", column " .. column .. " (" .. char .. ")")
								break
							end
						end
					end
					column, byte = column + vim.fn.strdisplaywidth(char), byte + #char
				end
			end
		end)
	end
end)
