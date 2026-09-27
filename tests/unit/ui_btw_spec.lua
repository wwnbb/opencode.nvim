local btw = require("opencode.ui.btw")

describe("/btw dialog", function()
	local old_columns, old_lines
	local previous_win
	local original_setreg, original_getreg, original_getmousepos

	before_each(function()
		old_columns, old_lines = vim.o.columns, vim.o.lines
		previous_win = vim.api.nvim_get_current_win()
		original_setreg, original_getreg = vim.fn.setreg, vim.fn.getreg
		original_getmousepos = vim.fn.getmousepos
		vim.o.columns, vim.o.lines = 100, 50
	end)

	after_each(function()
		btw.close()
		vim.fn.setreg, vim.fn.getreg, vim.fn.getmousepos = original_setreg, original_getreg, original_getmousepos
		vim.o.columns, vim.o.lines = old_columns, old_lines
		if vim.api.nvim_win_is_valid(previous_win) then vim.api.nvim_set_current_win(previous_win) end
	end)

	it("shows a centered borderless answer with fixed hints", function()
		local answer = "Day good. Sun up, tokens flow."
		local view = btw.show("how is your day", answer)
		local cfg = vim.api.nvim_win_get_config(view.winid)
		assert.is_true(btw.is_visible())
		assert.equals(view.winid, vim.api.nvim_get_current_win())
		assert.equals("editor", cfg.relative)
		assert.equals("none", cfg.border)
		assert.equals(88, cfg.width)
		assert.is_true(cfg.height < vim.o.lines)
		assert.equals(math.floor((vim.o.columns - cfg.width) / 2), cfg.col)
		local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.equals(cfg.height, #lines)
		assert.equals(math.floor((vim.o.lines - vim.o.cmdheight - cfg.height) / 2), cfg.row)
		assert.is_truthy(lines[2]:find("/btw", 1, true))
		assert.is_truthy(lines[2]:find("esc", 1, true))
		assert.is_truthy(lines[4]:find("how is your day", 1, true))
		assert.is_truthy(lines[7]:find(answer, 1, true))
		local marks = vim.api.nvim_buf_get_extmarks(view.bufnr, -1, 0, -1, { details = true })
		local muted_question, raised_rows = false, 0
		for _, mark in ipairs(marks) do
			if mark[2] == 3 and mark[4].hl_group == "OpenCodeBtwMuted" then muted_question = true end
			if mark[4].line_hl_group == "OpenCodeBtwRaised" then raised_rows = raised_rows + 1 end
		end
		assert.is_true(muted_question)
		assert.equals(20, raised_rows)
		assert.equals(18, view.geometry.answer_rows)
		assert.equals(28, cfg.height)
		assert.is_truthy(lines[#lines - 1]:find("c copy", 1, true))
		assert.is_truthy(lines[#lines - 1]:find("↑/↓ scroll", 1, true))
		for _, line in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= cfg.width)
		end
		assert.is_truthy(vim.fn.maparg("<LeftMouse>", "n"):find("Lua", 1, true))
		assert.equals(1, vim.fn.maparg("<Esc>", "n", false, true).buffer)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
		assert.is_false(btw.is_visible())
		assert.equals(previous_win, vim.api.nvim_get_current_win())
	end)

	it("reports copied only after the system register reads back correctly", function()
		local answer = "copy this answer"
		local registers = {}
		vim.fn.setreg = function(register, value)
			registers[register] = value
			return 0
		end
		vim.fn.getreg = function(register) return registers[register] or "" end
		local view = btw.show("question", answer)
		vim.api.nvim_feedkeys("c", "xt", false)
		local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.equals(answer, registers['"'])
		assert.equals(answer, registers["+"])
		assert.is_nil(registers["*"])
		assert.is_truthy(lines[#lines - 1]:find("✓ copied", 1, true))
		btw.close()
		registers = {}
		vim.fn.setreg = function(register, value)
			if register == '"' then registers[register] = value end
			return 0
		end
		view = btw.show("question", answer)
		vim.api.nvim_feedkeys("c", "xt", false)
		lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.equals(answer, registers['"'])
		assert.is_truthy(lines[#lines - 1]:find("copy failed", 1, true))
		assert.is_nil(lines[#lines - 1]:find("✓ copied", 1, true))
	end)

	it("scrolls only the answer and keeps the header and footer on resize", function()
		local answer_lines = {}
		for index = 1, 60 do answer_lines[index] = "Answer line " .. index end
		answer_lines[60] = "**Answer line 60**"
		local view = btw.show("a question", table.concat(answer_lines, "\n"))
		local initial = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.is_truthy(initial[7]:find("Answer line 1", 1, true))
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Down>", true, false, true), "xt", false)
		local scrolled = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.equals(initial[2], scrolled[2])
		assert.equals(initial[#initial - 1], scrolled[#scrolled - 1])
		assert.is_truthy(scrolled[7]:find("Answer line 2", 1, true))
		assert.is_nil(table.concat(initial, "\n"):find("Answer line 60", 1, true))
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<PageDown>", true, false, true), "xt", false)
		assert.equals(21, view.scroll)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<PageUp>", true, false, true), "xt", false)
		assert.equals(1, view.scroll)
		vim.api.nvim_feedkeys("G", "xt", false)
		local at_end = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		local last_answer_row = 5 + view.geometry.question_rows + view.geometry.answer_rows
		assert.is_truthy(at_end[last_answer_row]:find("Answer line 60", 1, true))
		local marks = vim.api.nvim_buf_get_extmarks(view.bufnr, -1, 0, -1, { details = true })
		local last_line_highlighted = false
		for _, mark in ipairs(marks) do
			if mark[2] == last_answer_row - 1 and mark[4].hl_group == "OpenCodeMarkdownStrong" then
				last_line_highlighted = true
			end
		end
		assert.is_true(last_line_highlighted)
		assert.equals(initial[2], at_end[2])
		assert.equals(initial[#initial - 1], at_end[#at_end - 1])
		vim.o.columns, vim.o.lines = 70, 24
		vim.api.nvim_exec_autocmds("VimResized", {})
		local cfg = vim.api.nvim_win_get_config(view.winid)
		local resized = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.equals(math.floor((vim.o.columns - cfg.width) / 2), cfg.col)
		assert.equals(cfg.height, #resized)
		assert.is_truthy(resized[#resized - 1]:find("c copy", 1, true))
	end)

	it("renders Markdown content with the chat renderer", function()
		local view = btw.show("format this", "# Heading\n\nA **bold** word")
		local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.equals("  Heading", lines[7])
		assert.equals("  A bold word", lines[9])
		local marks = vim.api.nvim_buf_get_extmarks(view.bufnr, -1, 0, -1, { details = true })
		local heading_highlight, bold_highlight = false, false
		for _, mark in ipairs(marks) do
			local group = mark[4].hl_group or ""
			if group:find("Heading", 1, true) then heading_highlight = true end
			if group == "OpenCodeMarkdownStrong" then bold_highlight = true end
		end
		assert.is_true(heading_highlight)
		assert.is_true(bold_highlight)
	end)

	it("wraps the full question and keeps the raised answer box at 20 rows", function()
		local question = string.rep("a longer question with context ", 9) .. "tail-marker"
		local view = btw.show(question, "One short answer")
		local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.is_true(view.geometry.question_rows > 1)
		assert.equals(view.geometry.question_rows + view.geometry.answer_rows + 9, view.geometry.height)
		assert.equals(18, view.geometry.answer_rows)
		assert.is_truthy(table.concat(lines, "\n"):find("tail-marker", 1, true))
		assert.equals("  One short answer", lines[6 + view.geometry.question_rows])
		for _, line in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= view.geometry.width)
		end
	end)

	it("closes the answer with Ctrl+C or when focus leaves the dialog", function()
		btw.show("question", "answer")
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-c>", true, false, true), "xt", false)
		assert.is_false(btw.is_visible())
		local view = btw.show("question", "answer")
		vim.api.nvim_set_current_win(previous_win)
		assert.is_true(vim.wait(500, function() return not btw.is_visible() end, 10))
		assert.is_false(btw.is_visible())
		assert.is_false(vim.api.nvim_win_is_valid(view.winid))
		assert.equals(previous_win, vim.api.nvim_get_current_win())
	end)

	it("opens a styled question prompt, accepts Enter, and cancels with Escape", function()
		local submitted
		local view = btw.prompt(function(text) submitted = text end)
		assert.is_true(btw.is_visible())
		assert.equals(view.input_winid, vim.api.nvim_get_current_win())
		local prompt_cfg = vim.api.nvim_win_get_config(view.winid)
		assert.equals("none", prompt_cfg.border)
		assert.equals(60, prompt_cfg.width)
		assert.equals(math.floor((vim.o.lines - vim.o.cmdheight) / 4), prompt_cfg.row)
		assert.equals("none", vim.api.nvim_win_get_config(view.input_winid).border)
		local prompt_lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.is_truthy(prompt_lines[#prompt_lines - 1]:find("return submit", 1, true))
		local marks = vim.api.nvim_buf_get_extmarks(view.input_bufnr, -1, 0, -1, { details = true })
		local has_placeholder = false
		for _, mark in ipairs(marks) do
			local text = mark[4].virt_text
			if text and text[1] and text[1][1] == "Ask anything" then has_placeholder = true end
		end
		assert.is_true(has_placeholder)
		vim.o.columns, vim.o.lines = 72, 26
		vim.api.nvim_exec_autocmds("VimResized", {})
		local resized_panel = vim.api.nvim_win_get_config(view.winid)
		local resized_input = vim.api.nvim_win_get_config(view.input_winid)
		assert.equals(60, resized_panel.width)
		assert.equals(resized_panel.row + 3, resized_input.row)
		assert.equals(resized_panel.col + 2, resized_input.col)
		assert.equals(resized_panel.width - 4, resized_input.width)
		vim.api.nvim_buf_set_lines(view.input_bufnr, 0, -1, false, { "  What is this?  " })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
		assert.equals("What is this?", submitted)
		assert.is_false(btw.is_visible())
		assert.equals(previous_win, vim.api.nvim_get_current_win())
		local cancelled = btw.prompt(function() submitted = "wrong" end)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
		assert.is_false(btw.is_visible())
		assert.equals("What is this?", submitted)
		assert.is_false(vim.api.nvim_win_is_valid(cancelled.input_winid))
	end)

	it("clears prompt text on first Ctrl+C and closes on the second", function()
		local view = btw.prompt(function() error("prompt must not submit") end)
		vim.api.nvim_buf_set_lines(view.input_bufnr, 0, -1, false, { "draft question" })
		local ctrl_c = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)
		vim.api.nvim_feedkeys(ctrl_c, "xt", false)
		assert.is_true(btw.is_visible())
		assert.same({ "" }, vim.api.nvim_buf_get_lines(view.input_bufnr, 0, -1, false))
		vim.api.nvim_feedkeys(ctrl_c, "xt", false)
		assert.is_false(btw.is_visible())
	end)

	it("reopens through the shared popup and cleans both prompt windows", function()
		local first = btw.prompt()
		assert.is_not_nil(first.popup.input)
		local panel_win, input_win = first.winid, first.input_winid
		local panel_buf, input_buf = first.bufnr, first.input_bufnr
		local second = btw.show("question", "answer")
		assert.is_false(vim.api.nvim_win_is_valid(panel_win))
		assert.is_false(vim.api.nvim_win_is_valid(input_win))
		assert.is_false(vim.api.nvim_buf_is_valid(panel_buf))
		assert.is_false(vim.api.nvim_buf_is_valid(input_buf))
		assert.is_true(btw.is_visible())
		second.popup:close()
		assert.is_false(btw.is_visible())
	end)

	it("closes from the answer header mouse target", function()
		local view = btw.show("question", "answer")
		vim.fn.getmousepos = function()
			return { winid = view.winid, winrow = 2, wincol = view.geometry.width - 3 }
		end
		vim.fn.maparg("<LeftMouse>", "n", false, true).callback()
		assert.is_false(btw.is_visible())
		assert.is_false(vim.api.nvim_win_is_valid(view.winid))
	end)
end)
