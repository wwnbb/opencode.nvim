local selection = require("opencode.completion.selection")
local defaults = require("opencode.config")

describe("completion Visual selection replacement", function()
	local buffers, original_buf, original_mode, original_visualmode, original_selection, original_virtualedit

	local function buffer(lines)
		local bufnr = vim.api.nvim_create_buf(true, false)
		buffers[#buffers + 1] = bufnr
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_set_current_buf(bufnr)
		return bufnr
	end

	local function select(mode, first, last)
		vim.api.nvim_get_mode = function() return { mode = "n" } end
		vim.fn.visualmode = function() return mode end
		vim.fn.setpos("'<", { 0, first[1], first[2], 0 })
		vim.fn.setpos("'>", { 0, last[1], last[2], 0 })
	end

	local function data(prompt) return vim.json.decode(prompt:match("Context %(JSON%):\n(.*)$")) end

	before_each(function()
		buffers, original_buf = {}, vim.api.nvim_get_current_buf()
		original_mode, original_visualmode = vim.api.nvim_get_mode, vim.fn.visualmode
		original_selection = vim.o.selection
		original_virtualedit = vim.wo.virtualedit
		vim.o.selection = "inclusive"
	end)

	after_each(function()
		vim.api.nvim_get_mode, vim.fn.visualmode = original_mode, original_visualmode
		vim.o.selection = original_selection
		vim.wo.virtualedit = original_virtualedit
		vim.api.nvim_set_current_buf(original_buf)
		for _, bufnr in ipairs(buffers) do vim.api.nvim_buf_delete(bufnr, { force = true }) end
	end)

	it("captures a reversed Unicode range and preserves unselected bytes", function()
		local contents = { "local café = 世界 + 1", "untouched" }
		local bufnr = buffer(contents)
		select("v", { 1, #"local café = 世" + 1 }, { 1, #"local " + 1 })
		local snap = assert(selection.capture())
		assert.equals("café = 世界", snap.selection.text)
		assert.equals(#"local ", snap.col)
		assert.equals(0, snap.row)
		assert.equals("", snap.prefix)
		assert.equals("", snap.suffix)
		assert.same({ "local result = value + 1" }, selection.replacement(snap, "result = value"))
		assert.equals(vim.api.nvim_get_current_win(), snap.winid)
		assert.equals(vim.api.nvim_buf_get_changedtick(bufnr), snap.changedtick)
		assert.same(contents, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end)

	it("replaces a multiline character range without consuming either boundary", function()
		buffer({ "keep(old", "middle", "end)tail", "next" })
		select("v", { 1, 6 }, { 3, 3 })
		local snap = assert(selection.capture())
		assert.same({ "old", "middle", "end" }, snap.selection.lines)
		assert.same({ "keep(new", "value)tail" }, selection.replacement(snap, "new\nvalue"))
		assert.same({ "keep()tail" }, selection.replacement(snap, ""))
		assert.same({ "keep(new", ")tail" }, selection.replacement(snap, "new\n"))
	end)

	it("honors exclusive selections without splitting UTF-8", function()
		buffer({ "aé界z" })
		vim.o.selection = "exclusive"
		select("v", { 1, #"aé" + 1 }, { 1, 2 })
		local snap = assert(selection.capture())
		assert.equals("é", snap.selection.text)
		assert.same({ "aX界z" }, selection.replacement(snap, "X"))
	end)

	it("preserves the next line's text when an exclusive selection consumes its preceding newline", function()
		buffer({ "before selected", "untouched" })
		vim.o.selection = "exclusive"
		select("v", { 1, #"before " + 1 }, { 2, 1 })
		local snap = assert(selection.capture())
		assert.equals(1, snap.selection.start_line)
		assert.equals(2, snap.selection.end_line)
		assert.equals("selected\n", snap.selection.text)
		assert.same({ "before replacementuntouched" }, selection.replacement(snap, "replacement"))
	end)

	it("captures through EOL and an empty final line exactly", function()
		buffer({ "start tail", "", "untouched" })
		select("v", { 1, 7 }, { 2, 1 })
		local snap = assert(selection.capture())
		assert.same({ "tail", "", "" }, snap.selection.lines)
		assert.same({ "start newuntouched" }, selection.replacement(snap, "new"))
		select("v", { 1, 7 }, { 1, 2147483647 })
		assert.same({ "start new" }, selection.replacement(assert(selection.capture()), "new"))
	end)

	it("replaces reversed full-line ranges and treats one final newline as a terminator", function()
		buffer({ "before", "  old()", "  more()", "after" })
		select("V", { 3, 4 }, { 2, 3 })
		local snap = assert(selection.capture())
		assert.equals(1, snap.row)
		assert.equals(0, snap.col)
		assert.equals(3, snap.selection.end_line)
		assert.same({ "  new()" }, selection.replacement(snap, "  new()\n"))
		assert.same({ "  new()", "" }, selection.replacement(snap, "  new()\n\n"))
		assert.same({ "" }, selection.replacement(snap, "\n"))
		assert.same({}, selection.replacement(snap, ""))
	end)

	it("uses the live Visual selection when invoked by a mapping", function()
		local bufnr = buffer({ "keep old tail" })
		local captured
		vim.keymap.set("x", "K", function() captured = selection.capture() end, { buffer = bufnr })
		vim.api.nvim_win_set_cursor(0, { 1, 5 })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("v2lK<Esc>", true, false, true), "xt", false)
		assert.is_true(vim.wait(1000, function() return captured ~= nil end, 10))
		assert.same({ "keep new tail" }, selection.replacement(captured, "new"))
	end)

	it("matches native Visual replacement across selected newline boundaries", function()
		local cases = {
			{ name = "exclusive next column one", lines = { "before selected", "untouched" }, cursor = { 1, 7 }, keys = "vj0", exclusive = true },
			{ name = "reversed exclusive", lines = { "before selected", "untouched" }, cursor = { 2, 0 }, keys = "vk7l", exclusive = true },
			{ name = "inclusive EOL", lines = { "before selected", "untouched" }, cursor = { 1, 7 }, keys = "v$" },
			{ name = "exclusive EOL", lines = { "before selected", "untouched" }, cursor = { 1, 7 }, keys = "v$", exclusive = true },
			{ name = "inclusive multiline EOL", lines = { "before selected", "second tail", "untouched" }, cursor = { 1, 7 }, keys = "vj$" },
			{ name = "empty last row", lines = { "before selected", "", "untouched" }, cursor = { 1, 7 }, keys = "vj0" },
			{ name = "EOF", lines = { "before selected" }, cursor = { 1, 7 }, keys = "v$" },
		}
		local register = vim.fn.getreginfo("z")
		for _, case in ipairs(cases) do
			local bufnr, captured = buffer(case.lines)
			vim.o.selection = case.exclusive and "exclusive" or "inclusive"
			vim.keymap.set("x", "K", function() captured = selection.capture() end, { buffer = bufnr })
			vim.api.nvim_win_set_cursor(0, case.cursor)
			vim.fn.setreg("z", "X", "v")
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(case.keys .. 'K"zP<Esc>', true, false, true), "xt", false)
			assert.is_not_nil(captured, case.name)
			local computed = vim.list_slice(case.lines, 1, captured.selection.start_line - 1)
			vim.list_extend(computed, selection.replacement(captured, "X"))
			vim.list_extend(computed, vim.list_slice(case.lines, captured.selection.end_line + 1))
			assert.same(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), computed, case.name)
		end
		vim.fn.setreg("z", register)
	end)

	it("rejects rectangular selections and read-only buffers without changing them", function()
		local contents = { "abc", "def" }
		local bufnr = buffer(contents)
		select("\022", { 1, 1 }, { 2, 2 })
		local snap, err = selection.capture()
		assert.is_nil(snap)
		assert.matches("Use v or V", err, 1, true)
		vim.bo[bufnr].readonly = true
		select("V", { 1, 1 }, { 2, 1 })
		snap, err = selection.capture()
		assert.is_nil(snap)
		assert.matches("editable file buffer", err, 1, true)
		assert.same(contents, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end)

	it("rejects a partial tab selected with virtual editing", function()
		local bufnr = buffer({ "\tvalue" })
		vim.wo.virtualedit = "all"
		local captured, err, called
		vim.keymap.set("x", "K", function() captured, err = selection.capture(); called = true end, { buffer = bufnr })
		vim.api.nvim_win_set_cursor(0, { 1, 0 })
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("3lv2lK<Esc>", true, false, true), "xt", false)
		assert.is_true(vim.wait(1000, function() return called end, 10))
		assert.is_nil(captured)
		assert.matches("Select whole characters", err, 1, true)
		assert.same({ "\tvalue" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
	end)

	it("builds bounded context containing the whole selection and instruction", function()
		buffer({ "local before = true", "call(old)", "return value" })
		select("v", { 2, 6 }, { 2, 8 })
		local snap = assert(selection.capture())
		local opts = defaults.merge().completion
		local prompt = assert(selection.build(snap, opts, 'Use "é🙂"'))
		local decoded = data(prompt)
		assert.equals('Use "é🙂"', decoded.instruction)
		assert.same({ "old" }, decoded.selection)
		assert.equals("character", decoded.selection_mode)
		assert.equals("call(", decoded.prefix)
		assert.equals(")", decoded.suffix)
		assert.equals(1 + opts.max_lines, decoded.max_lines)
		assert.same({ "local before = true" }, decoded.before)
		assert.same({ "return value" }, decoded.after)
		assert.is_true(#prompt <= opts.context.max_bytes)
		opts.context.before_lines, opts.context.after_lines, opts.context.header_lines = 0, 0, 0
		opts.context.max_related_buffers = 0
		local required = assert(selection.build(snap, opts, 'Use "é🙂"'))
		opts.context.max_bytes = #required
		assert.equals(required, selection.build(snap, opts, 'Use "é🙂"'))
		opts.context.max_bytes = #required - 1
		local result, err = selection.build(snap, opts, 'Use "é🙂"')
		assert.is_nil(result)
		assert.matches("full selection and instruction exceed", err, 1, true)
	end)
end)
