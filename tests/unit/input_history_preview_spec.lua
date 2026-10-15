describe("input prompt history preview", function()
	local search = require("opencode.ui.input.history_search")
	local backend = require("opencode.ui.history_search")
	local autocomplete = require("opencode.ui.input.autocomplete")
	local namespace = vim.api.nvim_get_namespaces().opencode_input_history_preview
	local state, saved, previous_win, entries, pending, closed, restored, original

	local function marks()
		return vim.api.nvim_buf_get_extmarks(state.bufnr, namespace, 0, -1, { details = true })
	end

	local function geometry()
		return { config = vim.api.nvim_win_get_config(state.winid), position = vim.api.nvim_win_get_position(state.winid),
			height = vim.api.nvim_win_get_height(state.winid), text_height = vim.api.nvim_win_text_height(state.winid, {}) }
	end

	local function start()
		assert.is_true(search.start(state, original, {
			prepare = function() vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "" }) end,
			restore = function()
				restored = restored + 1
				vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, vim.split(original.text, "\n", { plain = true }))
			end,
			select = function() error("Preview must not select or send") end,
		}))
	end

	before_each(function()
		previous_win = vim.api.nvim_get_current_win()
		local bufnr = vim.api.nvim_create_buf(false, true)
		local winid = vim.api.nvim_open_win(bufnr, true, { relative = "editor", row = 3, col = 5, width = 40, height = 3, style = "minimal" })
		vim.wo[winid].wrap, vim.wo[winid].linebreak = true, true
		state = { bufnr = bufnr, winid = winid, visible = true, config = {} }
		original = { text = "Keep\nthis draft", parts = { { type = "agent", name = "explore" } }, mode = "shell",
			options = { context = { { type = "text", text = "context" } } } }
		entries = {
			{ kind = "history", entry = { text = "First line\nsecond line", parts = {}, mode = "normal" } },
			{ kind = "history", entry = { text = "Second prompt", parts = {}, mode = "normal" } },
		}
		pending, closed, restored = nil, 0, 0
		saved = { new = backend.new, show_items = autocomplete.show_items, close = autocomplete.close }
		backend.new = function()
			return { search = function(query, callback)
				if query == "" then callback(entries, false)
				else callback({}, true); pending = callback end
			end, close = function() closed = closed + 1 end }
		end
		autocomplete.show_items = function(current, kind, trigger, items)
			current.autocomplete = { visible = true, kind = kind, query = trigger.query, items = items, selected = 1 }
		end
		autocomplete.close = function(current) current.autocomplete = nil end
	end)

	after_each(function()
		search.cancel(state)
		backend.new, autocomplete.show_items, autocomplete.close = saved.new, saved.show_items, saved.close
		if vim.api.nvim_win_is_valid(state.winid) then vim.api.nvim_win_close(state.winid, true) end
		if vim.api.nvim_buf_is_valid(state.bufnr) then vim.api.nvim_buf_delete(state.bufnr, { force = true }) end
		if vim.api.nvim_win_is_valid(previous_win) then vim.api.nvim_set_current_win(previous_win) end
	end)

	it("previews the highlighted full prompt without modifying the query or saved draft", function()
		local snapshot = vim.deepcopy(original)
		start()
		local tick, before = vim.api.nvim_buf_get_changedtick(state.bufnr), geometry()
		vim.bo[state.bufnr].modified = false
		local mark = marks()[1][4]
		assert.same({ { "First line second line", "OpenCodeInputAutocompleteDescription" } }, mark.virt_text)
		assert.equals("eol", mark.virt_text_pos)
		assert.is_nil(mark.virt_lines)
		state.autocomplete.selected = 2
		search.preview(state)
		assert.equals("Second prompt", marks()[1][4].virt_text[1][1])
		assert.same({ "" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(state.bufnr))
		assert.is_false(vim.bo[state.bufnr].modified)
		assert.same(snapshot, state.history_search.draft)
		assert.same(before, geometry())
	end)

	it("clears loading and empty results, then shows a query suffix without changing the query", function()
		start()
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "match" })
		search.refresh(state)
		assert.same({}, marks())
		local tick = vim.api.nvim_buf_get_changedtick(state.bufnr)
		pending(entries, false)
		assert.equals(" → First line second line", marks()[1][4].virt_text[1][1])
		assert.equals(5, marks()[1][3])
		assert.same({ "match" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(state.bufnr))
		pending({}, false)
		assert.same({}, marks())
		pending({ { kind = "history", entry = { text = "", parts = { { type = "file" } } } } }, false)
		assert.same({}, marks())
	end)

	it("truncates Unicode previews within the remaining width without wrapping or moving the input", function()
		start()
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "query" })
		search.refresh(state)
		local before, tick = geometry(), vim.api.nvim_buf_get_changedtick(state.bufnr)
		pending({ { kind = "history", entry = { text = string.rep("界", 100) .. "\nlast line" } } }, false)
		local mark = marks()[1][4]
		assert.equals("eol", mark.virt_text_pos)
		assert.is_nil(mark.virt_lines)
		assert.is_nil(mark.virt_text[1][1]:find("\n", 1, true))
		assert.is_true(vim.fn.strdisplaywidth(mark.virt_text[1][1]) <= 40 - 5 - 1)
		assert.same(before, geometry())
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(state.bufnr))
		vim.api.nvim_win_set_width(state.winid, 10)
		local resized = geometry()
		search.preview(state)
		assert.is_true(vim.fn.strdisplaywidth(marks()[1][4].virt_text[1][1]) <= 10 - 5 - 1)
		assert.same(resized, geometry())
	end)

	it("clears the preview on cancellation and ignores late results while restoring the original draft", function()
		start()
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "match" })
		search.refresh(state)
		pending(entries, false)
		assert.equals(1, #marks())
		assert.is_true(search.cancel(state))
		assert.same({}, marks())
		assert.equals(1, restored)
		assert.equals(1, closed)
		assert.same({ "Keep", "this draft" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
		pending(entries, false)
		assert.same({}, marks())
		assert.same({ "Keep", "this draft" }, vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false))
	end)
end)
