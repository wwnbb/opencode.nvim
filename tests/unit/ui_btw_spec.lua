local btw = require("opencode.ui.btw")
local config = require("opencode.config")
local state = require("opencode.state")

describe("/btw view", function()
	local old_columns, old_lines, old_config, previous_win, original_setreg

	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end

	local function text(view)
		return table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
	end

	local function border(view)
		local lines = vim.api.nvim_buf_get_lines(view.popup.frame.border.bufnr, 0, -1, false)
		return lines[1], lines[#lines]
	end

	local function has_mapping(bufnr, mode, lhs)
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
			if require("opencode.util.keymap").matches(mapping.lhs, lhs) then return true end
		end
		return false
	end

	before_each(function()
		old_config = state.get_config()
		state.set_config(config.merge({}))
		old_columns, old_lines = vim.o.columns, vim.o.lines
		previous_win = vim.api.nvim_get_current_win()
		original_setreg = vim.fn.setreg
		vim.o.columns, vim.o.lines = 100, 50
	end)

	after_each(function()
		btw.close()
		state.set_config(old_config)
		vim.fn.setreg = original_setreg
		vim.o.columns, vim.o.lines = old_columns, old_lines
		if vim.api.nvim_win_is_valid(previous_win) then vim.api.nvim_set_current_win(previous_win) end
	end)

	it("shows a focused, scrollable Markdown answer below the quoted question", function()
		local answer = {}
		for index = 1, 60 do answer[index] = "Answer line " .. index end
		answer[1] = "# Heading\n\nA **bold** word"
		local view = btw.show("how is your day", table.concat(answer, "\n"))
		assert.is_true(btw.is_visible())
		assert.equals(view.winid, vim.api.nvim_get_current_win())
		local top, bottom = border(view)
		assert.is_truthy(top:find("/btw", 1, true))
		assert.is_truthy(bottom:find("c copy · q / <Esc> / <C-c> close", 1, true))
		assert.is_nil(bottom:find("ask", 1, true))
		local content = text(view)
		assert.is_truthy(content:find("how is your day", 1, true))
		assert.is_truthy(content:find("A bold word", 1, true))
		assert.is_truthy(content:find("Answer line 60", 1, true))
		local bold = false
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.bufnr, -1, 0, -1, { details = true })) do
			if mark[4].hl_group == "OpenCodeMarkdownStrong" then bold = true end
		end
		assert.is_true(bold)
		-- Ordinary Normal-mode motions move through the answer.
		keys("G")
		assert.equals(vim.api.nvim_buf_line_count(view.bufnr), vim.api.nvim_win_get_cursor(view.winid)[1])
		local copied = {}
		vim.fn.setreg = function(register, value) copied[register] = value end
		keys("c")
		assert.equals(table.concat(answer, "\n"), copied['"'])
		keys("<Esc>")
		assert.is_false(btw.is_visible())
		assert.equals(previous_win, vim.api.nvim_get_current_win())
	end)

	it("closes with Ctrl+C or when focus leaves the view", function()
		btw.show("question", "answer")
		keys("<C-c>")
		assert.is_false(btw.is_visible())
		local view = btw.show("question", "answer")
		vim.api.nvim_set_current_win(previous_win)
		assert.is_true(vim.wait(500, function() return not btw.is_visible() end, 10))
		assert.is_false(vim.api.nvim_win_is_valid(view.winid))
	end)

	it("opens with a docked composer that keeps Normal mode and submits into the same view", function()
		local asked = {}
		local view = btw.prompt(function(question, opts)
			asked[#asked + 1] = { question = question, opts = opts }
		end, { session_id = "ses_btw" })
		assert.is_not_nil(view.composer)
		local field = view.composer.input
		assert.equals(field.winid, vim.api.nvim_get_current_win())
		assert.equals(view.popup.frame.winid, vim.api.nvim_win_get_config(field.border.winid).win)
		assert.is_truthy(text(view):find("Ask anything", 1, true))
		local _, bottom = border(view)
		assert.is_truthy(bottom:find("<C-g> ask · <Esc> / <C-c> back", 1, true))

		-- Insert-mode Escape leaves the question editable in Normal mode.
		assert.is_false(has_mapping(field.bufnr, "i", "<Esc>"))
		assert.is_true(has_mapping(field.bufnr, "i", "<C-c>"))
		assert.is_true(has_mapping(field.bufnr, "n", "<Esc>"))
		keys("<Cmd><CR>What is this?<Esc>")
		assert.equals(field.winid, vim.api.nvim_get_current_win())
		assert.equals("n", vim.fn.mode())
		assert.same({ "What is this?" }, vim.api.nvim_buf_get_lines(field.bufnr, 0, -1, false))
		keys("0dwiWhy <Esc>")
		assert.same({ "Why is this?" }, vim.api.nvim_buf_get_lines(field.bufnr, 0, -1, false))
		keys("<C-g>")
		assert.is_true(vim.wait(500, function() return view.composer == nil end, 5))
		assert.equals(1, #asked)
		assert.equals("Why is this?", asked[1].question)
		assert.same({ view = view.token, turns = {} }, asked[1].opts)
		assert.equals(view.winid, vim.api.nvim_get_current_win())
		assert.is_truthy(text(view):find("Answering", 1, true))

		-- A follow-up waits for the pending answer and keeps its draft.
		local original_notify, notices = vim.notify, {}
		vim.notify = function(message) notices[#notices + 1] = message end
		keys("iToo early?<C-g>")
		vim.notify = original_notify
		assert.equals(1, #asked)
		assert.is_truthy(notices[1]:find("wait for the current answer", 1, true))
		-- Typed keys end in Normal mode, where Escape goes back to the answer.
		keys("<Esc>")
		assert.is_true(vim.wait(500, function() return view.composer == nil end, 5))
		assert.is_true(btw.is_visible())

		assert.equals(view, btw.show("Why is this?", "Because.", { view = view.token }))
		assert.is_nil(text(view):find("Answering", 1, true))
		assert.is_truthy(text(view):find("Because.", 1, true))
		keys("i")
		assert.same({ "Too early?" }, vim.api.nvim_buf_get_lines(view.composer.input.bufnr, 0, -1, false))
		keys("<C-g>")
		assert.is_true(vim.wait(500, function() return view.composer == nil end, 5))
		assert.equals("Too early?", asked[2].question)
		assert.same({ { question = "Why is this?", answer = "Because." } }, asked[2].opts.turns)

		assert.is_true(btw.error(view.token, "Model overloaded"))
		local content = text(view)
		assert.is_truthy(content:find("Because.", 1, true))
		assert.is_truthy(content:find("Too early?", 1, true))
		assert.is_truthy(content:find("/btw error: Model overloaded", 1, true))
		assert.is_false(btw.error(view.token + 1, "other view"))
	end)

	it("closes an empty view when the composer is cancelled", function()
		local view = btw.prompt(function() error("must not submit") end)
		keys("draft<Esc>")
		assert.is_true(btw.is_visible())
		keys("<Esc>")
		assert.is_true(vim.wait(500, function() return not btw.is_visible() end, 5))
		assert.is_false(vim.api.nvim_win_is_valid(view.winid))
	end)

	it("opens a new view with earlier turns when the asking view is gone", function()
		local asked
		local view = btw.show("second", "two", {
			view = 999, session_id = "ses_btw",
			turns = { { question = "first", answer = "one" } },
			on_ask = function(question, opts) asked = { question, opts } end,
		})
		local content = text(view)
		assert.is_truthy(content:find("first", 1, true))
		assert.is_truthy(content:find("two", 1, true))
		local _, bottom = border(view)
		assert.is_truthy(bottom:find("i ask", 1, true))
		keys("ithird<C-g>")
		assert.is_true(vim.wait(500, function() return asked ~= nil end, 5))
		assert.equals("third", asked[1])
		assert.same({ { question = "first", answer = "one" }, { question = "second", answer = "two" } }, asked[2].turns)
		btw.close_session("ses_other")
		assert.is_true(btw.is_visible())
		btw.close_session("ses_btw")
		assert.is_false(btw.is_visible())
	end)

	it("uses custom bindings in mappings and hints", function()
		state.set_config(config.merge({ btw_answer = { keymaps = { copy = { "y", "Y" }, close = "x", ask = false } } }))
		local view = btw.show("question", "answer", { on_ask = function() end })
		local _, bottom = border(view)
		assert.is_truthy(bottom:find("y / Y copy · x close", 1, true))
		assert.is_nil(bottom:find("ask", 1, true))
		assert.is_true(has_mapping(view.bufnr, "n", "x"))
		assert.is_false(has_mapping(view.bufnr, "n", "q"))
		assert.is_false(has_mapping(view.bufnr, "n", "i"))
		local copied = {}
		vim.fn.setreg = function(register, value) copied[register] = value end
		keys("Y")
		assert.equals("answer", copied['"'])
	end)
end)
