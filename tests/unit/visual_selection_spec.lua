local selection = require("opencode.util.visual_selection")

describe("Visual selection capture", function()
	local original_buf, original_mode, original_visualmode, buffers

	local function buffer(contents, path)
		local bufnr = vim.api.nvim_create_buf(true, false)
		buffers[#buffers + 1] = bufnr
		if path then vim.api.nvim_buf_set_name(bufnr, path) end
		vim.bo[bufnr].filetype = "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, contents)
		vim.api.nvim_set_current_buf(bufnr)
		return bufnr
	end

	local function last_selection(mode, first, last)
		vim.api.nvim_get_mode = function() return { mode = "n" } end
		vim.fn.visualmode = function() return mode end
		vim.fn.setpos("'<", { 0, first[1], first[2], 0 })
		vim.fn.setpos("'>", { 0, last[1], last[2], 0 })
	end

	before_each(function()
		buffers = {}
		original_buf = vim.api.nvim_get_current_buf()
		original_mode = vim.api.nvim_get_mode
		original_visualmode = vim.fn.visualmode
	end)

	after_each(function()
		vim.api.nvim_get_mode = original_mode
		vim.fn.visualmode = original_visualmode
		vim.api.nvim_set_current_buf(original_buf)
		for _, bufnr in ipairs(buffers) do vim.api.nvim_buf_delete(bufnr, { force = true }) end
	end)

	it("reads charwise Unicode as complete characters from unsaved buffer text", function()
		local contents = { "local café = 1", "print(世界)", "return ok" }
		local bufnr = buffer(contents, vim.fn.getcwd() .. "/tests/selection-example.lua")
		-- Neovim marks use one-based byte columns. The end is the first byte of 世.
		last_selection("v", { 1, #"local " + 1 }, { 2, #"print(" + 1 })
		local tick = vim.api.nvim_buf_get_changedtick(bufnr)
		local snap = assert(selection.capture())
		assert.same({ "café = 1", "print(世" }, snap.lines)
		assert.equals("café = 1\nprint(世", snap.text)
		assert.equals(1, snap.start_line)
		assert.equals(2, snap.end_line)
		assert.equals(bufnr, snap.bufnr)
		assert.equals(tick, snap.changedtick)
		assert.equals("lua", snap.filetype)
		assert.equals(vim.fn.getcwd(), snap.root)
		assert.same(contents, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
		assert.equals(tick, vim.api.nvim_buf_get_changedtick(bufnr))
	end)

	it("reads full physical lines from a reversed linewise selection", function()
		buffer({ "first", "", "третий", "fourth" })
		last_selection("V", { 3, 2 }, { 1, 4 })
		local snap = assert(selection.capture())
		assert.equals("V", snap.mode)
		assert.same({ "first", "", "третий" }, snap.lines)
		assert.equals("first\n\nтретий", snap.text)
		assert.equals(1, snap.start_line)
		assert.equals(3, snap.end_line)
		assert.equals("", snap.path)
		assert.equals(vim.fn.getcwd(), snap.root)
	end)

	it("uses display columns for blockwise selections across wide characters", function()
		buffer({ "ab界dZ", "ab12dZ", "ab福dZ" })
		last_selection("\022", { 1, 3 }, { 3, 6 })
		local snap = assert(selection.capture())
		assert.equals("\022", snap.mode)
		assert.same({ "界d", "12d", "福d" }, snap.lines)
		assert.equals("界d\n12d\n福d", snap.text)
		assert.equals(1, snap.start_line)
		assert.equals(3, snap.end_line)
	end)

	it("captures the live Visual anchor and cursor without using stale marks", function()
		buffer({ "left α right", "second" })
		last_selection("V", { 2, 1 }, { 2, 1 })
		vim.api.nvim_get_mode = function() return { mode = "v" } end
		local original_getpos = vim.fn.getpos
		vim.fn.getpos = function(mark)
			if mark == "v" then return { 0, 1, 6, 0 } end
			if mark == "." then return { 0, 1, 7, 0 } end
			return original_getpos(mark)
		end
		local ok, snap = pcall(selection.capture)
		vim.fn.getpos = original_getpos
		assert.is_true(ok)
		assert.equals("α", snap.text)
		assert.equals(1, snap.start_line)
		assert.equals(1, snap.end_line)
	end)

	it("captures from a live Visual mapping before leaving Visual mode", function()
		local bufnr = buffer({ "abcdef" })
		local captured
		vim.keymap.set("x", "K", function() captured = selection.capture() end, { buffer = bufnr })
		vim.api.nvim_win_set_cursor(0, { 1, 1 })
		local keys = vim.api.nvim_replace_termcodes("v2lK<Esc>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		assert.is_true(vim.wait(1000, function() return captured ~= nil end, 10))
		assert.equals("bcd", captured.text)
		assert.equals("v", captured.mode)
	end)

	it("captures a live blockwise mapping as one fragment per source line", function()
		local bufnr = buffer({ "abcde", "ABCDE", "12345" })
		local captured
		vim.keymap.set("x", "K", function() captured = selection.capture() end, { buffer = bufnr })
		vim.api.nvim_win_set_cursor(0, { 1, 1 })
		local keys = vim.api.nvim_replace_termcodes("<C-v>2j2lK<Esc>", true, false, true)
		vim.api.nvim_feedkeys(keys, "xt", false)
		assert.is_true(vim.wait(1000, function() return captured ~= nil end, 10))
		assert.equals("\022", captured.mode)
		assert.same({ "bcd", "BCD", "234" }, captured.lines)
		assert.equals(1, captured.start_line)
		assert.equals(3, captured.end_line)
	end)

	it("rejects an absent Visual range", function()
		buffer({ "x" })
		vim.api.nvim_get_mode = function() return { mode = "n" } end
		vim.fn.visualmode = function() return "v" end
		vim.fn.setpos("'<", { 0, 0, 0, 0 })
		vim.fn.setpos("'>", { 0, 0, 0, 0 })
		local snap, err = selection.capture()
		assert.is_nil(snap)
		assert.matches("No Visual selection", err)
	end)
end)
