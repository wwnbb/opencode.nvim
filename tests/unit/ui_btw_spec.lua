local btw = require("opencode.ui.btw")
local config = require("opencode.config")
local state = require("opencode.state")
local Popup = require("opencode.ui.popup")

local function assert_inside_screen(window_config)
	local border_width, border_height = Popup.outer_insets()
	assert.is_true(window_config.col >= 0 and window_config.col + window_config.width + border_width <= vim.o.columns)
	assert.is_true(window_config.row >= 0
		and window_config.row + window_config.height + border_height <= vim.o.lines - vim.o.cmdheight)
end

describe("/btw dialog", function()
	local old_columns, old_lines
	local old_config
	local previous_win
	local original_setreg, original_getreg, original_getmousepos

	before_each(function()
		old_config = state.get_config()
		state.set_config(config.merge({}))
		old_columns, old_lines = vim.o.columns, vim.o.lines
		previous_win = vim.api.nvim_get_current_win()
		original_setreg, original_getreg = vim.fn.setreg, vim.fn.getreg
		original_getmousepos = vim.fn.getmousepos
		vim.o.columns, vim.o.lines = 100, 50
	end)

	after_each(function()
		btw.close()
		state.set_config(old_config)
		vim.fn.setreg, vim.fn.getreg, vim.fn.getmousepos = original_setreg, original_getreg, original_getmousepos
		vim.o.columns, vim.o.lines = old_columns, old_lines
		if vim.api.nvim_win_is_valid(previous_win) then vim.api.nvim_set_current_win(previous_win) end
	end)

	it("shows a focused answer inside the screen with matching hints", function()
		local answer = "Day good. Sun up, tokens flow."
		local view = btw.show("how is your day", answer)
		local cfg = vim.api.nvim_win_get_config(view.winid)
		assert.is_true(btw.is_visible())
		assert.equals(view.winid, vim.api.nvim_get_current_win())
		assert_inside_screen(cfg)
		local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		local text = table.concat(lines, "\n")
		assert.is_truthy(text:find("how is your day", 1, true))
		assert.is_truthy(text:find(answer, 1, true))
		assert.is_truthy(lines[#lines - 1]:find("c copy", 1, true))
		for _, line in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= cfg.width)
		end
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
		assert.equals(initial[2], at_end[2])
		assert.equals(initial[#initial - 1], at_end[#at_end - 1])
		vim.o.columns, vim.o.lines = 70, 24
		vim.api.nvim_exec_autocmds("VimResized", {})
		local cfg = vim.api.nvim_win_get_config(view.winid)
		local resized = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.equals(view.geometry.col, cfg.col)
		assert_inside_screen(cfg)
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

	it("wraps the full question above the answer", function()
		local question = string.rep("a longer question with context ", 9) .. "tail-marker"
		local view = btw.show(question, "One short answer")
		local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.is_true(view.geometry.question_rows > 1)
		assert.is_truthy(table.concat(lines, "\n"):find("tail-marker", 1, true))
		assert.equals("  One short answer", lines[6 + view.geometry.question_rows])
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

	it("opens a question prompt, accepts Enter, and cancels with Escape", function()
		local submitted
		local view = btw.prompt(function(text) submitted = text end)
		assert.is_true(btw.is_visible())
		assert.equals(view.input_winid, vim.api.nvim_get_current_win())
		vim.o.columns, vim.o.lines = 72, 26
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.equals(view.winid, vim.api.nvim_win_get_config(view.input_winid).win)
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

	it("preserves normal-only q on prompt input and Escape-only close on the main panel by default", function()
		local view = btw.prompt()
		local function has_mapping(bufnr, mode, lhs)
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
				if require("opencode.util.keymap").matches(mapping.lhs, lhs) then return true end
			end
			return false
		end
		assert.is_true(has_mapping(view.input_bufnr, "n", "q"))
		assert.is_false(has_mapping(view.input_bufnr, "i", "q"))
		assert.is_true(has_mapping(view.input_bufnr, "i", "<Esc>"))
		assert.is_false(has_mapping(view.bufnr, "n", "q"))
		assert.is_true(has_mapping(view.bufnr, "n", "<Esc>"))
		btw.close()
		state.set_config(config.merge({ btw_prompt = { keymaps = { close = "x" } } }))
		view = btw.prompt()
		assert.is_true(has_mapping(view.bufnr, "n", "x"))
		assert.is_true(has_mapping(view.input_bufnr, "i", "x"))
		assert.is_false(has_mapping(view.bufnr, "n", "<Esc>"))
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

	it("uses custom prompt and answer bindings in mappings and hints", function()
		state.set_config(config.merge({
			btw_prompt = { keymaps = { submit = "<M-s>", close = false, clear = false } },
			btw_answer = { keymaps = { copy = { "y", "Y" }, close = false, scroll_down = "J" } },
		}))
		local submitted
		local prompt = btw.prompt(function(value) submitted = value end)
		assert.is_nil(vim.fn.maparg("<CR>", "i", false, true).callback)
		for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
			assert.is_nil(vim.fn.maparg(key, "n", false, true).callback)
		end
		local prompt_text = table.concat(vim.api.nvim_buf_get_lines(prompt.bufnr, 0, -1, false), "\n")
		assert.is_truthy(prompt_text:find("<M-s> submit", 1, true))
		vim.api.nvim_buf_set_lines(prompt.input_bufnr, 0, -1, false, { "question" })
		vim.fn.maparg("<M-s>", "i", false, true).callback()
		assert.equals("question", submitted)
		local answer = {}
		for index = 1, 40 do answer[index] = "Line " .. index end
		local view = btw.show("question", table.concat(answer, "\n"))
		local text = table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
		assert.is_truthy(text:find("y / Y copy", 1, true))
		assert.is_truthy(text:find("J scroll", 1, true))
		for _, key in ipairs({ "q", "<Esc>", "<C-c>", "c", "j", "<Down>" }) do
			assert.is_nil(vim.fn.maparg(key, "n", false, true).callback)
		end
		vim.fn.maparg("J", "n", false, true).callback()
		assert.equals(1, view.scroll)
		local copied = {}
		vim.fn.setreg = function(register, value) copied[register] = value end
		vim.fn.getreg = function(register) return copied[register] end
		vim.fn.maparg("Y", "n", false, true).callback()
		assert.equals(table.concat(answer, "\n"), copied['"'])
	end)
end)
