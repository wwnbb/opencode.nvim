local exploration = require("opencode.ui.chat.exploration_tool")
local style = require("opencode.ui.chat.exploration_style")
local syntax = require("opencode.ui.syntax")

local function part(tool, input, output)
	return { tool = tool, state = { status = "completed", input = input, output = output } }
end

local function lines(result)
	return vim.tbl_map(function(line)
		return line:gsub(" +$", "")
	end, result.lines)
end

describe("exploration list presentation", function()
	local highlight_text
	before_each(function()
		highlight_text = syntax.highlight_text
	end)
	after_each(function()
		syntax.highlight_text = highlight_text
	end)

	it("keeps tool headers stable while opening output with compact bordered output", function()
		for _, tool in ipairs({ "read", "glob", "grep" }) do
			local item = part(tool, { path = "sample.txt", pattern = "needle" }, "unique output")
			local closed = exploration.render(item, false)
			local opened = exploration.render(item, true)
			assert.equals(1, #closed.lines)
			assert.equals(closed.lines[1]:gsub("●", "○"):gsub("→", "↘"), opened.lines[1])
			assert.equals(style.header_hl, closed.highlights[1].hl_group)
			assert.equals(style.header_hl, opened.highlights[1].hl_group)
			assert.is_truthy(opened.lines[2]:find("   ┌", 1, true))
			assert.is_truthy(opened.lines[#opened.lines]:find("   └", 1, true))
			for i, line in ipairs(lines(opened)) do
				assert.is_true(line ~= "", tool .. " has an unexpected blank row")
				if i > 2 and i < #opened.lines then
					assert.equals(style.prefix, line:sub(1, #style.prefix))
				end
			end
		end
	end)

	it("moves the native read range into the header and preserves syntax through wrapping", function()
		local source = string.rep("x", 150)
		syntax.highlight_text = function(text)
			assert.equals(source, text)
			return { { line = 0, col_start = 0, col_end = #text, hl_group = "String" } }
		end
		local item = part("read", { path = "sample.lua" }, "Read file sample.lua, lines 1-1\n1: " .. source)
		local rendered = exploration.render(item, true)
		assert.equals(" ↘ Read sample.lua · lines 1–1", lines(rendered)[1])
		assert.is_nil(table.concat(rendered.lines):find("Read file", 1, true))
		local captured, count = {}, 0
		for _, hl in ipairs(rendered.highlights) do
			if hl.hl_group == "String" then
				count = count + 1
				captured[#captured + 1] = rendered.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end)
			end
		end
		assert.is_true(count > 1)
		assert.equals(source, table.concat(captured))
		local width = require("opencode.ui.chat.render").get_chat_text_width()
		for _, line in ipairs(rendered.lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= width)
		end
	end)

	it("shortens glob paths within the project and retains read loaded-file details", function()
		local glob = exploration.render(part("glob", { pattern = "*" }, vim.fn.getcwd() .. "/README.md"), true)
		assert.equals("   │ README.md", lines(glob)[3])
		local read = part("read", { path = "sample.txt" }, "content")
		read.state.metadata = { loaded = { "AGENTS.md" } }
		for _, expanded in ipairs({ false, true }) do
			assert.is_truthy(
				table.concat(exploration.render(read, expanded).lines):find("↳ Loaded AGENTS.md", 1, true)
			)
		end
	end)

	it("keeps headers unshaded and confines panel highlights to the indented body", function()
		for _, name in ipairs({ style.header_hl, style.error_hl }) do
			local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
			assert.is_nil(hl.bg)
			assert.is_not_true(hl.italic)
			assert.is_not_true(hl.bold)
		end
		local failed = part("grep", { pattern = "[" }, "")
		failed.state.status, failed.state.error = "error", "Invalid pattern"
		for _, expanded in ipairs({ false, true }) do
			local rendered = exploration.render(failed, expanded)
			assert.is_truthy(table.concat(rendered.lines):find("Invalid pattern", 1, true))
			assert.equals(style.error_hl, rendered.highlights[1].hl_group)
			if expanded then
				for _, hl in ipairs(rendered.highlights) do
					if hl.hl_group == style.body_error_hl or hl.hl_group == style.border_hl then
						assert.equals(3, hl.col_start)
					end
				end
			end
		end
	end)
end)
