local write = require("opencode.ui.chat.write")
local render = require("opencode.ui.chat.render")
local style = require("opencode.ui.chat.tool_style")
local syntax = require("opencode.ui.syntax")
local view = require("opencode.ui.chat.state").state
local helpers = require("tests.helpers.tool_render")
local contains, body_text = helpers.contains, helpers.panel_text

local function part(status, content, extra)
	return { type = "tool", tool = "write", state = vim.tbl_extend("force", {
		status = status, input = { path = "notes.lua", content = content },
	}, extra or {}) }
end

describe("write tool widget", function()
	local old_winid, old_columns, old_highlight, old_tabstop, bufnr, winid
	before_each(function()
		old_winid, old_columns = view.winid, vim.o.columns
		old_highlight, old_tabstop = syntax.highlight_text, vim.bo.tabstop
		vim.o.columns = 120
		bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, false, { relative = "editor", row = 0, col = 0, width = 80, height = 10 })
		view.winid = winid
		vim.bo.tabstop = 8
	end)
	after_each(function()
		view.winid, syntax.highlight_text, vim.bo.tabstop = old_winid, old_highlight, old_tabstop
		vim.api.nvim_win_close(winid, true)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		vim.o.columns = old_columns
	end)

	it("folds completed writes into one row and expands the literal submitted content", function()
		local source = "# Heading\n**literal Markdown**\n```lua\nprint('hello')\n```\n"
		local item = part("completed", source)
		local snapshot = vim.deepcopy(item)
		local calls = 0
		syntax.highlight_text = function() calls = calls + 1; return {} end
		local closed = write.render_tool(item, false)
		assert.equals(1, #closed.lines)
		contains(closed.lines[1], "▸ Write notes.lua · Completed")
		assert.equals(0, calls)
		local opened = write.render_tool(item, true)
		contains(opened.lines[1], "▾ Write notes.lua · Completed")
		contains(opened.lines[2], "   ┌")
		contains(opened.lines[#opened.lines], "   └")
		local body = body_text(opened)
		contains(body, "Content sent to write (before server formatting)")
		contains(body, source:sub(1, -2))
		assert.is_nil(body:find("+0 -0", 1, true))
		assert.same(snapshot, item)
		assert.equals(0, write.animation_line)
	end)

	it("labels pending and running content as proposed", function()
		for _, status in ipairs({ "pending", "running" }) do
			local result = write.render_tool(part(status, "local proposed = true"), true)
			contains(result.lines[1], status:gsub("^%l", string.upper))
			assert.matches("[|/\\-]$", vim.trim(result.lines[1]))
			contains(body_text(result), "Proposed content")
			contains(body_text(result), "local proposed = true")
			assert.is_nil(body_text(result):find("Content sent", 1, true))
		end
	end)

	it("keeps failed writes visibly failed and shows their error beside the proposal", function()
		local result = write.render_tool(part("error", "unapplied", { error = "Permission denied\nTry another path" }), true)
		contains(result.lines[1], "Failed")
		assert.equals(style.error_hl, result.highlights[1].hl_group)
		local body = body_text(result)
		contains(body, "Proposed content")
		contains(body, "unapplied")
		contains(body, "Permission denied\nTry another path")
		assert.is_nil(body:find("Content sent", 1, true))
		contains(body_text(write.render_tool(part("error", nil), true)), "Write failed")
	end)

	it("distinguishes an empty submitted file from unavailable content", function()
		local empty = body_text(write.render_tool(part("completed", ""), true))
		local missing = body_text(write.render_tool(part("completed", nil), true))
		contains(empty, "(empty file)")
		assert.is_nil(empty:find("unavailable", 1, true))
		contains(missing, "Content unavailable")
		assert.is_nil(missing:find("empty file", 1, true))
	end)

	it("preserves all wrapped Unicode and tabbed source with aligned syntax highlights", function()
		vim.api.nvim_win_set_config(winid, { width = 32 })
		local source = "\tlocal value = '" .. string.rep("世界é", 30) .. "'\n\treturn value"
		local expanded_lines = vim.tbl_map(function(line)
			return render.expand_tabs(line, vim.fn.strdisplaywidth(style.prefix))
		end, vim.split(source, "\n", { plain = true }))
		syntax.highlight_text = function(value, language, opts)
			assert.equals(table.concat(expanded_lines, "\n"), value)
			assert.equals("lua", language)
			assert.equals("tools", opts.scope)
			local captures = {}
			for index, line in ipairs(expanded_lines) do
				captures[#captures + 1] = { line = index - 1, col_start = 0, col_end = #line, hl_group = "String" }
			end
			return captures
		end
		local path = string.rep("世界", 15) .. "/notes.lua"
		local item = part("completed", nil, { input = { path = path, content = source } })
		local closed, result = write.render_tool(item, false), write.render_tool(item, true)
		assert.equals(1, #closed.lines)
		local captured = {}
		for _, hl in ipairs(result.highlights) do
			if hl.hl_group == "String" then
				assert.is_true(hl.col_start >= #style.prefix)
				captured[#captured + 1] = result.lines[hl.line + 1]:sub(hl.col_start + 1, hl.col_end)
			end
		end
		assert.is_true(#captured > 2)
		-- The shared word wrapper consumes the separating space at this line break.
		assert.equals(table.concat(expanded_lines):gsub(" = '", " ='"), table.concat(captured))
		for _, line in ipairs(result.lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= 32, line)
			assert.is_nil(line:find("\t", 1, true))
		end
		contains(body_text(result):gsub("\n", ""), path)
	end)

	it("keeps native diagnostics and their navigation hint", function()
		local result = write.render_tool(part("completed", "", { metadata = { diagnostics = {
			{ severity = 1, message = "Expected expression", range = { start = { line = 2, character = 4 } } },
		} } }), true)
		contains(body_text(result), "Error [3:5] Expected expression")
		contains(body_text(result), "/diagnostics: list and jump")
	end)
end)
