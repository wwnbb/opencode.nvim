local app = require("opencode.state")
local sync = require("opencode.sync")
local pending = require("opencode.session.pending")
local Popup = require("opencode.ui.popup")

local function press(buf, key)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == key then return map.callback() end
	end
	error("Missing mapping " .. key)
end

describe("UI quality work bounds and retained behavior", function()
	local stubs, cleanup, config, columns, rows
	local function stub(object, key, callback)
		stubs[#stubs + 1] = require("luassert.stub")(object, key, callback)
	end
	local function own(close) cleanup[#cleanup + 1] = close end
	before_each(function()
		stubs, cleanup = {}, {}
		config, columns, rows = app.get_config(), vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 120, 45
	end)
	after_each(function()
		for index = #cleanup, 1, -1 do cleanup[index]() end
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		vim.o.columns, vim.o.lines = columns, rows
		app.reset(); app.set_config(config); sync.clear_all(); pending.clear_all()
	end)

	it("moves default menu selection without rebuilding buffers and still refreshes changed items", function()
		local items = { { label = "A", value = "a" }, { label = "B", value = "b" } }
		local ctx = require("opencode.ui.menu").open({ items = items, refocus_chat = false })
		own(ctx.close)
		local write, writes = vim.api.nvim_buf_set_lines, 0
		stub(vim.api, "nvim_buf_set_lines", function(buf, ...)
			if buf == ctx.popup.bufnr or buf == ctx.frame.bufnr then writes = writes + 1 end
			return write(buf, ...)
		end)
		press(ctx.popup.bufnr, "j")
		assert.equals("b", ctx.current().value)
		assert.equals(2, vim.api.nvim_win_get_cursor(ctx.popup.winid)[1])
		assert.equals(0, writes)
		press(ctx.popup.bufnr, "j"); assert.equals("a", ctx.current().value)
		items[1].label = "Changed"; ctx.refresh()
		assert.is_true(writes > 0)
		assert.matches("Changed", table.concat(vim.api.nvim_buf_get_lines(ctx.popup.bufnr, 0, -1, false)))
	end)

	it("keeps custom filter, sort and move callback semantics on each menu step", function()
		local filters, sorts, moves = 0, 0, {}
		local ctx = require("opencode.ui.menu").open({ items = { "A", "B", "C" }, refocus_chat = false,
			filter = function() filters = filters + 1; return true end,
			sort = function(a, b) sorts = sorts + 1; return a < b end,
			on_move = function(item) moves[#moves + 1] = item end,
		})
		own(ctx.close)
		filters, sorts = 0, 0
		press(ctx.popup.bufnr, "j")
		assert.equals(3, filters); assert.is_true(sorts > 0); assert.same({ "B" }, moves)
	end)

	it("moves palette selection while preserving text and static keybind marks", function()
		local palette, registry = require("opencode.ui.palette"), require("opencode.command_registry")
		app.set_config({ palette = { frecency = false, width = 50, height = 8, categories = { "quality" } } })
		palette.setup()
		for _, id in ipairs({ "a", "b" }) do
			local key = "quality." .. id
			palette.register({ id = key, title = "Quality " .. id, category = "quality", keybind = "<CR>", run = function() end })
			own(function() registry.unregister(key) end)
		end
		palette.show(); own(palette.hide)
		local wins = palette.get_winids()
		local input, buf = vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[2])
		vim.api.nvim_buf_set_lines(input, 0, -1, false, { "Quality " })
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = input })
		local text = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local ns = vim.api.nvim_create_namespace("opencode_palette")
		local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
		local write, writes = vim.api.nvim_buf_set_lines, 0
		stub(vim.api, "nvim_buf_set_lines", function(target, ...)
			if target == buf then writes = writes + 1 end
			return write(target, ...)
		end)
		press(input, "<Down>")
		assert.equals(0, writes); assert.same(text, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		local after = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
		assert.equals(#marks, #after)
		local function static(list)
			return vim.tbl_filter(function(mark) return mark[4].hl_group ~= "OpenCodePaletteSelected" end, list)
		end
		assert.same(static(marks), static(after))
		assert.equals(3, vim.api.nvim_win_get_cursor(wins[2])[1])
	end)

	it("clamps provided popup marks with no per-mark buffer reads and isolates concurrent windows", function()
		local first = Popup.new({ size = { width = 30, height = 4 }, enter = false })
		local second = Popup.new({ size = { width = 30, height = 4 }, enter = false })
		first:mount(); own(function() first:close() end)
		second:mount(); own(function() second:close() end)
		assert.equals(first.namespaces.content, second.namespaces.content)
		second:render({ "second" }, { { line = 0, col = 0, end_col = 6, hl_group = "Comment" } })
		local read, count, reads, counts = vim.api.nvim_buf_get_lines, vim.api.nvim_buf_line_count, 0, 0
		stub(vim.api, "nvim_buf_get_lines", function(buf, ...)
			if buf == first.bufnr then reads = reads + 1 end
			return read(buf, ...)
		end)
		stub(vim.api, "nvim_buf_line_count", function(buf)
			if buf == first.bufnr then counts = counts + 1 end
			return count(buf)
		end)
		local marks = {}
		for index = 1, 100 do marks[index] = { line = 0, col = 50, end_col = 100, hl_group = "Title" } end
		first:render({ "猫" }, marks)
		assert.equals(0, reads); assert.equals(0, counts)
		local actual = vim.api.nvim_buf_get_extmarks(first.bufnr, first.namespaces.content, 0, -1, { details = true })
		assert.equals(100, #actual)
		for _, mark in ipairs(actual) do assert.equals(#"猫", mark[3]); assert.equals(#"猫", mark[4].end_col) end
		first:render(nil, marks)
		assert.equals(1, reads); assert.equals(1, counts)
		assert.equals(1, #vim.api.nvim_buf_get_extmarks(second.bufnr, second.namespaces.content, 0, -1, {}))
	end)

	it("does no skill catalog work for a draft without active skill parts", function()
		local buf = vim.api.nvim_create_buf(false, true)
		own(function() vim.api.nvim_buf_delete(buf, { force = true }) end)
		local reads = 0
		stub(sync, "get_skills", function() reads = reads + 1; return { { id = "skill", name = "Named" } } end)
		local state = { visible = true, info_bufnr = buf, parts = {}, mode = "shell", layout = { content_width = 100 } }
		local info = require("opencode.ui.input.info_bar")
		info.update(state); assert.equals(0, reads)
		state.parts = { { type = "skill", skillID = "skill" } }
		info.update(state); assert.equals(1, reads)
		assert.matches("Skill: Named", vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1])
	end)

	it("reuses owned VCS projections for review/tree changes and refreshes changed patches", function()
		app.set_session("quality", "Quality"); app.set_config({ chat = { diff_view = "split" } })
		local patch, actions = require("opencode.vcs"), require("opencode.actions")
		local project, builds = patch.project, 0
		stub(patch, "project", function(...) builds = builds + 1; return project(...) end)
		local source = "@@ -1 +1 @@\n-before\n+after\n"
		stub(actions, "get_vcs_diff", function(_, done)
			done(nil, { { file = "one.lua", status = "modified", additions = 1, deletions = 1, patch = source } })
		end)
		local viewer = require("opencode.ui.vcs")
		local view = viewer.open({ mode = "working" }); own(viewer.close)
		assert.equals(1, builds)
		press(view.after_buf, "m"); press(view.tree_buf, "t")
		assert.equals(1, builds)
		source = "@@ -1 +1 @@\n-before\n+changed\n"
		press(view.after_buf, "r"); assert.equals(2, builds)
		assert.matches("changed", table.concat(vim.api.nvim_buf_get_lines(view.after_buf, 0, -1, false)))
	end)
end)

describe("incremental shell output", function()
	local popup, timers, requests, stubs, saved_defer, config
	local actions = require("opencode.actions")
	local function entry()
		return { id = "quality-shell", command = "printf", status = "running", location = { directory = "/quality" } }
	end
	local function output() return table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 3, -1, false), "\n") end
	local function stub(object, key, callback) stubs[#stubs + 1] = require("luassert.stub")(object, key, callback) end

	before_each(function()
		pending.clear_all(); config = app.get_config(); app.set_connection("connected")
		stubs, timers, requests = {}, {}, {}
		saved_defer = vim.defer_fn
		vim.defer_fn = function(fn)
			local timer = { fn = fn, closed = false, stop = function() end }
			function timer:close() self.closed = true end
			function timer:is_closing() return self.closed end
			timers[#timers + 1] = timer; return timer
		end
		stub(actions, "get_shell", function(_, _, done) done(nil, entry()) end)
		stub(actions, "get_shell_output", function(_, opts, done) requests[#requests + 1] = { opts = opts, cb = done } end)
		popup = require("opencode.ui.palette.processes").output(entry())
	end)
	after_each(function()
		popup:close()
		for _, timer in ipairs(timers) do timer:close() end
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		vim.defer_fn = saved_defer; pending.clear_all(); app.reset(); app.set_config(config)
	end)

	it("matches whole-output normalization at every ANSI, UTF-8, OSC and CRLF byte boundary", function()
		local raw = "猫\27[31mred\27[0m\r\nline\27]0;title\nhidden\7done\n\27]8;;url\27\\link\27]8;;\27\\\r\nfinish\r\27[31m\nCSI\r\27]title\7\nOSC\r\27]title\27\\\27[0m\nST\r\27]inside\rtitle\7\n\27[\27]t\00731m\27\27]t\7[0m"
		local normal = require("opencode.util.text").normalize_text
		local prefix = ""
		for index = 1, #raw do
			local chunk = raw:sub(index, index); prefix = prefix .. chunk
			if index > 1 then timers[#timers].fn() end
			requests[#requests].cb(nil, { output = chunk, cursor = index, size = #raw, truncated = false })
			assert.equals(normal(prefix, tostring), output(), "byte boundary " .. index)
		end
		local tick = vim.api.nvim_buf_get_changedtick(popup.bufnr)
		timers[#timers].fn(); requests[#requests].cb(nil, { output = "", cursor = #raw, size = #raw, truncated = false })
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(popup.bufnr))
	end)

	it("keeps full history with linear normalization work and preserves manual/follow scroll", function()
		local text = require("opencode.util.text")
		local strip, processed = text.strip_ansi, 0
		stub(text, "strip_ansi", function(value) processed = processed + #value; return strip(value) end)
		local chunk, bytes = string.rep("retained line\n", 1000), 0
		for index = 1, 10 do
			if index > 1 then timers[#timers].fn() end
			bytes = bytes + #chunk
			requests[#requests].cb(nil, { output = chunk, cursor = bytes, size = #chunk * 10, truncated = false })
			if index == 1 then vim.api.nvim_win_set_cursor(popup.winid, { 4, 0 }) end
		end
		assert.equals(string.rep(chunk, 10), output())
		assert.equals(4, vim.api.nvim_win_get_cursor(popup.winid)[1])
		assert.is_true(processed <= bytes * 2)
		local last = vim.api.nvim_buf_line_count(popup.bufnr)
		vim.api.nvim_win_set_cursor(popup.winid, { last, 0 })
		timers[#timers].fn(); requests[#requests].cb(nil, { output = "last", cursor = bytes + 4, size = bytes + 4, truncated = false })
		assert.equals(vim.api.nvim_buf_line_count(popup.bufnr), vim.api.nvim_win_get_cursor(popup.winid)[1])
		assert.equals(string.rep(chunk, 10) .. "last", output())
	end)
end)
