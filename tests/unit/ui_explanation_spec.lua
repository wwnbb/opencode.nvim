local explanation = require("opencode.ui.explanation")
local actions = require("opencode.actions")

describe("selection explanation popup", function()
	local source, previous_buf, previous_win, original_action, original_columns, original_lines, original_setreg

	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "xt", false)
	end

	before_each(function()
		explanation.teardown()
		previous_buf, previous_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		original_action, original_columns, original_lines, original_setreg =
			actions.explain_selection, vim.o.columns, vim.o.lines, vim.fn.setreg
		vim.o.columns, vim.o.lines = 100, 40
		source = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
		vim.api.nvim_set_current_buf(source)
		vim.bo[source].filetype = "lua"
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "local value = 1", "return value" })
	end)

	after_each(function()
		explanation.teardown()
		actions.explain_selection = original_action
		vim.fn.setreg = original_setreg
		vim.o.columns, vim.o.lines = original_columns, original_lines
		if vim.api.nvim_win_is_valid(previous_win) then vim.api.nvim_set_current_win(previous_win) end
		if vim.api.nvim_buf_is_valid(previous_buf) then vim.api.nvim_set_current_buf(previous_buf) end
		if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
	end)

	it("opens immediately with a spinner, then displays the complete Markdown answer", function()
		local tick = vim.api.nvim_buf_get_changedtick(source)
		vim.bo[source].modified = false
		local closed = 0
		local view = explanation.open({ bufnr = source }, function() closed = closed + 1 end)
		assert.is_true(explanation.is_open())
		assert.equals(view.winid, vim.api.nvim_get_current_win())
		assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
			:find("Explaining selection", 1, true))
		assert.is_true(explanation.show("L1–2 — **Defines and returns** a value.\n\nMore detail."))
		assert.equals("opencode_explanation", vim.bo[view.bufnr].filetype)
		assert.same({ "L1–2 — Defines and returns a value.", "", "More detail." },
			vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false))
		assert.is_false(vim.bo[view.bufnr].modifiable)
		assert.is_true(vim.wo[view.winid].wrap)
		assert.same({ "local value = 1", "return value" }, vim.api.nvim_buf_get_lines(source, 0, -1, false))
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(source))
		assert.is_false(vim.bo[source].modified)
		assert.is_true(explanation.close())
		assert.equals(1, closed)
		assert.is_false(explanation.close())
		assert.equals(1, closed)
		assert.is_false(explanation.show("late response"))
	end)

	it("renders Markdown and code highlights, wraps to the popup width, and copies the source", function()
		local answer = "# Explanation\n\n```lua\nlocal value = 1\n    return value\n```\n\n- **Значение** и `value`\n\n"
			.. string.rep("Привет 世界 ", 30)
		local view = explanation.open({ bufnr = source }, function() end)
		assert.is_true(explanation.show(answer))
		local lines = vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)
		assert.same({ "Explanation", "", "local value = 1", "    return value", "", "- Значение и value" },
			vim.list_slice(lines, 1, 6))
		local highlighted = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.bufnr, view.popup.namespaces.content, 0, -1,
			{ details = true })) do
			highlighted[mark[4].hl_group] = true
			assert.is_true(mark[4].end_col <= #lines[mark[2] + 1])
		end
		assert.is_true(highlighted.OpenCodeMarkdownCombinedText_Heading1)
		assert.is_true(highlighted.OpenCodeMarkdownStrong)
		assert.is_true(highlighted.OpenCodeMarkdownCombinedText_Code)
		assert.is_true(highlighted["@keyword.lua"])
		for _, line in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(view.winid))
		end
		local copied = {}
		vim.fn.setreg = function(register, value) copied[register] = value end
		keys("c")
		assert.equals(answer, copied['"'])
		vim.o.columns = 50
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.is_true(vim.wait(500, function() return vim.api.nvim_win_get_width(view.winid) == 40 end, 5))
		for _, line in ipairs(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= 40)
		end
	end)

	it("keeps the spinner until visible text, then highlights and copies the partial answer", function()
		local view = explanation.open({ bufnr = source }, function() end)
		local timer = view.timer
		assert.is_true(explanation.show("", { streaming = true }))
		assert.equals("pending", view.phase)
		assert.equals(timer, view.timer)
		local answer = "# Explanation\n\n```lua\nlocal value = 1"
		assert.is_true(explanation.show(answer, { streaming = true }))
		assert.equals("streaming", view.phase)
		assert.is_nil(view.timer)
		assert.same({ "Explanation", "", "local value = 1" },
			vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false))
		local highlighted = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.bufnr, view.popup.namespaces.content, 0, -1,
			{ details = true })) do highlighted[mark[4].hl_group] = true end
		assert.is_true(highlighted.OpenCodeMarkdownCombinedText_Heading1)
		assert.is_true(highlighted["@keyword.lua"])
		assert.is_false(vim.bo[view.bufnr].modifiable)
		assert.is_true(vim.bo[view.bufnr].readonly)
		local copied = {}
		vim.fn.setreg = function(register, value) copied[register] = value end
		keys("c")
		assert.equals(answer, copied['"'])
		assert.equals(answer, copied["+"])
	end)

	it("preserves the cursor and scroll as a streamed answer grows, finishes, and resizes", function()
		local lines = {}
		for index = 1, 60 do lines[index] = "L" .. index .. " — Привет 世界" end
		local view = explanation.open({ bufnr = source }, function() end)
		explanation.show(table.concat(lines, "\n", 1, 45), { streaming = true })
		keys("35j2l")
		local saved = vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
		assert.equals(36, saved.lnum)
		assert.is_true(saved.topline > 1)
		local function assert_view()
			local current = vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
			assert.equals(saved.lnum, current.lnum)
			assert.equals(saved.col, current.col)
			assert.equals(saved.topline, current.topline)
		end
		local answer = table.concat(lines, "\n")
		assert.is_true(explanation.show(answer, { streaming = true }))
		assert_view()
		vim.o.columns = 50
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.equals(40, vim.api.nvim_win_get_width(view.winid))
		assert_view()
		assert.is_true(explanation.show(answer))
		assert.equals("ready", view.phase)
		assert_view()
		assert.equals(60, vim.api.nvim_buf_line_count(view.bufnr))
		local copied = {}
		vim.fn.setreg = function(register, value) copied[register] = value end
		keys("c")
		assert.equals(answer, copied['"'])
		assert.equals(answer, copied["+"])
		assert.is_true(explanation.is_open())
	end)

	it("shows errors in the popup and closes through q, Esc, or window closure", function()
		local closed = 0
		local function open()
			return explanation.open({ bufnr = source }, function() closed = closed + 1 end)
		end
		local view = open()
		assert.is_true(explanation.error("Selection exceeds the context budget"))
		assert.is_truthy(vim.api.nvim_buf_get_lines(view.bufnr, 0, 1, false)[1]:find("context budget", 1, true))
		keys("q")
		assert.is_false(explanation.is_open())
		assert.equals(1, closed)
		open()
		keys("<Esc>")
		assert.is_false(explanation.is_open())
		assert.equals(2, closed)
		view = open()
		vim.api.nvim_win_close(view.winid, true)
		assert.is_true(vim.wait(500, function() return closed == 3 end, 5))
		assert.is_false(explanation.is_open())
	end)

	it("maps only Visual K in source buffers and restores prior mappings", function()
		local called, callback_mode = 0, nil
		actions.explain_selection = function()
			called = called + 1
			callback_mode = vim.api.nvim_get_mode().mode
		end
		vim.keymap.set("x", "K", "gq", { buffer = source })
		local previous = vim.fn.maparg("K", "x", false, true)
		vim.keymap.set("n", "K", "<Nop>", { buffer = source })
		local normal = vim.fn.maparg("K", "n", false, true)
		explanation.setup({ enabled = true, keymaps = { trigger = "K" } })
		assert.is_function(vim.fn.maparg("K", "x", false, true).callback)
		assert.same(normal, vim.fn.maparg("K", "n", false, true))
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		keys("vK")
		assert.equals(1, called)
		assert.equals("v", callback_mode)
		local special = vim.api.nvim_create_buf(true, false)
		vim.bo[special].buftype = "nofile"
		vim.api.nvim_set_current_buf(special)
		assert.is_nil(vim.fn.maparg("K", "x", false, true).callback)
		vim.api.nvim_set_current_buf(source)
		vim.api.nvim_buf_delete(special, { force = true })
		explanation.teardown()
		assert.same(previous, vim.fn.maparg("K", "x", false, true))
		assert.same(normal, vim.fn.maparg("K", "n", false, true))
	end)

	it("supports trigger aliases and custom popup keys without retaining disabled close aliases", function()
		vim.keymap.set("x", "K", "gq", { buffer = source })
		vim.keymap.set("x", "gK", "gq", { buffer = source })
		local old_k, old_gk = vim.fn.maparg("K", "x", false, true), vim.fn.maparg("gK", "x", false, true)
		local called = 0
		actions.explain_selection = function() called = called + 1 end
		explanation.setup({ enabled = true, keymaps = { trigger = { "K", "gK" }, close = false, copy = { "y", "Y" } } })
		vim.fn.maparg("K", "x", false, true).callback()
		vim.fn.maparg("gK", "x", false, true).callback()
		assert.equals(2, called)
		local view = explanation.open({ bufnr = source }, function() end)
		assert.is_nil(vim.fn.maparg("q", "n", false, true).callback)
		assert.is_nil(vim.fn.maparg("<Esc>", "n", false, true).callback)
		local pending = table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
		assert.is_nil(pending:find("close", 1, true))
		explanation.show("answer")
		local copied
		vim.fn.setreg = function(_, value) copied = value end
		vim.fn.maparg("Y", "n", false, true).callback()
		assert.equals("answer", copied)
		assert.is_nil(vim.fn.maparg("c", "n", false, true).callback)
		explanation.teardown()
		vim.api.nvim_set_current_buf(source)
		assert.same(old_k, vim.fn.maparg("K", "x", false, true))
		assert.same(old_gk, vim.fn.maparg("gK", "x", false, true))
	end)
end)
