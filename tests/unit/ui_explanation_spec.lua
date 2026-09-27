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
		assert.equals("markdown", vim.bo[view.bufnr].filetype)
		assert.same({ "L1–2 — **Defines and returns** a value.", "", "More detail." },
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

	it("keeps all answer lines scrollable and copies the full response", function()
		local lines = {}
		for index = 1, 60 do lines[index] = "L" .. index .. " — explanation" end
		local answer = table.concat(lines, "\n")
		local view = explanation.open({ bufnr = source }, function() end)
		assert.is_true(explanation.show(answer))
		assert.equals(60, vim.api.nvim_buf_line_count(view.bufnr))
		keys("35j")
		assert.equals(36, vim.api.nvim_win_get_cursor(view.winid)[1])
		assert.is_true(vim.api.nvim_win_call(view.winid, function() return vim.fn.line("w0") end) > 1)
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
end)
