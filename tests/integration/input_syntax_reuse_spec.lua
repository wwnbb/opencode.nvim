local input_syntax = require("opencode.ui.input.syntax")
local syntax = require("opencode.ui.syntax")
local code_blocks = require("opencode.ui.code_blocks")
local memo = require("opencode.util.memo")
local app = require("opencode.state")
local namespace = vim.api.nvim_create_namespace("opencode_input_syntax")

local fixture = {
	"Introduction", "```lua", "local first = 1", "return first", "```", "Between blocks",
	"```lua", "local second = 2", "return second", "```", "Final prose",
}

local function sorted(values)
	table.sort(values, function(a, b) return vim.inspect(a) < vim.inspect(b) end)
	return values
end

local function predicate_registry()
	for index = 1, 100 do
		local name, value = debug.getupvalue(vim.treesitter.query.add_predicate, index)
		if name == "predicate_handlers" then return value end
		if name == nil then break end
	end
	error("Missing predicate registry")
end

describe("input syntax block reuse through attached buffers", function()
	local bufnr, previous_buffer, config, previous_config, originals, queue, counts, oracle
	local predicates, previous_predicate

	local function reset_counts()
		counts = { parsers = 0, reads = 0, fence_parses = 0, sets = 0, deletes = 0, clears = 0 }
	end

	local function marks()
		return vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })
	end

	local function ids(first_row, last_row)
		local result = {}
		for _, mark in ipairs(marks()) do
			if (not first_row or mark[2] >= first_row) and (not last_row or mark[2] <= last_row) then
				result[#result + 1] = mark[1]
			end
		end
		table.sort(result)
		return result
	end

	local function drain()
		local rounds = 0
		while #queue > 0 do
			rounds = rounds + 1
			assert.is_true(rounds < 100, "Scheduled input update did not settle")
			table.remove(queue, 1)()
		end
	end

	local function assert_equivalent()
		local actual = {}
		for _, mark in ipairs(marks()) do
			local detail = mark[4]
			actual[#actual + 1] = { line = mark[2], col_start = mark[3], end_line = detail.end_row,
				col_end = detail.end_col, hl_group = detail.hl_group, priority = detail.priority }
		end
		local draft = table.concat(originals.get_lines(bufnr, 0, -1, false), "\n")
		oracle = true
		local ok, expected = pcall(syntax.highlight_markdown_fenced_blocks, draft, {
			scope = "input_markdown", priority = vim.hl and vim.hl.priorities and vim.hl.priorities.treesitter or 100,
		})
		oracle = false
		assert.is_true(ok, expected)
		local canonical = {}
		for _, highlight in ipairs(expected) do
			canonical[#canonical + 1] = { line = highlight.line, col_start = highlight.col_start,
				end_line = highlight.line, col_end = highlight.col_end,
				hl_group = highlight.hl_group, priority = highlight.priority or 0 }
		end
		assert.same(sorted(canonical), sorted(actual))
	end

	local function flush_and_compare()
		local cursor, view = vim.api.nvim_win_get_cursor(0), vim.fn.winsaveview()
		drain()
		assert.same(cursor, vim.api.nvim_win_get_cursor(0))
		assert.same(view, vim.fn.winsaveview())
		assert_equivalent()
	end

	local function replace(lines)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		flush_and_compare()
	end

	local function refresh()
		local row = vim.api.nvim_buf_line_count(bufnr) - 1
		local line = originals.get_lines(bufnr, row, row + 1, false)[1]
		vim.api.nvim_buf_set_lines(bufnr, row, row + 1, false, { line })
		flush_and_compare()
	end

	before_each(function()
		memo.clear_all()
		previous_config, previous_buffer = app.get_config(), vim.api.nvim_get_current_buf()
		config = vim.deepcopy(require("opencode.config").defaults)
		config.syntax.enabled, config.syntax.input_markdown = true, true
		originals = {
			schedule = vim.schedule, get_config = app.get_config,
			parser = vim.treesitter.get_string_parser, query_get = vim.treesitter.query.get,
			get_lines = vim.api.nvim_buf_get_lines, set_mark = vim.api.nvim_buf_set_extmark,
			delete_mark = vim.api.nvim_buf_del_extmark, clear = vim.api.nvim_buf_clear_namespace,
			fence_parse = code_blocks.parse,
		}
		-- Exercise mutations of one actual config table; the public state getter
		-- normally returns a detached snapshot and cannot be mutated in place.
		app.get_config = function() return config end
		predicates = predicate_registry()
		previous_predicate = predicates["input_reuse_external?"]
		queue, oracle = {}, false
		reset_counts()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		vim.bo[bufnr].undolevels = 1000
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.deepcopy(fixture))
		vim.schedule = function(callback) queue[#queue + 1] = callback end
		vim.treesitter.get_string_parser = function(...)
			if not oracle then counts.parsers = counts.parsers + 1 end
			return originals.parser(...)
		end
		vim.api.nvim_buf_get_lines = function(buffer, ...)
			if buffer == bufnr and not oracle then counts.reads = counts.reads + 1 end
			return originals.get_lines(buffer, ...)
		end
		code_blocks.parse = function(...)
			if not oracle then counts.fence_parses = counts.fence_parses + 1 end
			return originals.fence_parse(...)
		end
		vim.api.nvim_buf_set_extmark = function(buffer, ns, ...)
			if buffer == bufnr and ns == namespace then counts.sets = counts.sets + 1 end
			return originals.set_mark(buffer, ns, ...)
		end
		vim.api.nvim_buf_del_extmark = function(buffer, ns, ...)
			if buffer == bufnr and ns == namespace then counts.deletes = counts.deletes + 1 end
			return originals.delete_mark(buffer, ns, ...)
		end
		vim.api.nvim_buf_clear_namespace = function(buffer, ns, ...)
			if buffer == bufnr and ns == namespace then counts.clears = counts.clears + 1 end
			return originals.clear(buffer, ns, ...)
		end
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		drain()
		vim.schedule, app.get_config = originals.schedule, originals.get_config
		vim.treesitter.get_string_parser, vim.treesitter.query.get = originals.parser, originals.query_get
		vim.api.nvim_buf_get_lines, code_blocks.parse = originals.get_lines, originals.fence_parse
		vim.api.nvim_buf_set_extmark, vim.api.nvim_buf_del_extmark = originals.set_mark, originals.delete_mark
		vim.api.nvim_buf_clear_namespace = originals.clear
		predicates["input_reuse_external?"] = previous_predicate
		if vim.api.nvim_buf_is_valid(previous_buffer) then vim.api.nvim_set_current_buf(previous_buffer) end
		app.set_config(previous_config)
		memo.clear_all()
	end)

	it("retains unchanged fence IDs after prose shifts and rebuilds only an edited fence", function()
		input_syntax.attach(bufnr)
		flush_and_compare()
		assert.equals(2, counts.parsers)
		local all_ids, first_ids, second_ids = ids(), ids(2, 3), ids(7, 8)
		assert.is_true(#all_ids > 0)
		reset_counts()
		refresh()
		assert.equals(0, counts.parsers)
		assert.equals(0, counts.sets)
		assert.equals(0, counts.deletes)
		assert.same(all_ids, ids())
		reset_counts()
		vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "More prose" })
		flush_and_compare()
		assert.equals(0, counts.parsers)
		assert.equals(0, counts.sets)
		assert.equals(0, counts.deletes)
		assert.same(first_ids, ids(3, 4))
		assert.same(second_ids, ids(8, 9))
		reset_counts()
		vim.api.nvim_buf_set_lines(bufnr, 3, 4, false, { "local first = math.max(1, 20)" })
		flush_and_compare()
		assert.equals(1, counts.parsers)
		assert.is_true(counts.sets > 0)
		assert.equals(#first_ids, counts.deletes)
		assert.same(second_ids, ids(8, 9))
	end)

	it("coalesces edits and matches the full calculation after undo and redo", function()
		input_syntax.attach(bufnr)
		flush_and_compare()
		-- Finish setup's undo block before simulating normal editor commands.
		vim.cmd("let &undolevels = &undolevels")
		vim.api.nvim_win_set_cursor(0, { 3, 0 })
		vim.cmd("normal! A + 3")
		flush_and_compare()
		local changed = originals.get_lines(bufnr, 0, -1, false)
		vim.cmd("silent undo")
		flush_and_compare()
		assert.same(fixture, originals.get_lines(bufnr, 0, -1, false))
		vim.cmd("silent redo")
		flush_and_compare()
		assert.same(changed, originals.get_lines(bufnr, 0, -1, false))
		reset_counts()
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "Prose one" })
		vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "Prose two" })
		assert.equals(1, #queue)
		flush_and_compare()
		assert.equals(1, counts.reads)
		assert.equals(1, counts.fence_parses)
		assert.equals(0, counts.parsers)
	end)

	it("matches every language, delimiter, deletion and draft-replacement event", function()
		input_syntax.attach(bufnr)
		flush_and_compare()
		local drafts = {
			{ "  ```lua", "  local text = 'Привет 世界🙂'", "  return text", "  ```", "prose" },
			{ "  ```missing_input_parser", "  local text = 'Привет 世界🙂'", "  ```", "prose" },
			{ "  ~~~lua", "  local text = 'Привет 世界🙂'", "  ~~~", "prose" },
			{ "```lua", "local a = 1", "```", "```lua", "return 2", "```", "prose" },
			{ "```lua", "return 2", "```", "prose" },
			{ "```lua", "return 2", "return 3" },
			{ "Everything is plain prose now" },
			{ "```lua", "return 4", "```", "```lua", "return 4", "```", "prose" },
			{ "```lua", "return 4", "```", "prose" },
		}
		for _, draft in ipairs(drafts) do replace(draft) end
	end)

	it("clears disabled marks without reading or parsing and observes in-place config mutation", function()
		input_syntax.attach(bufnr)
		flush_and_compare()
		config.syntax.input_markdown = false
		reset_counts()
		refresh()
		assert.equals(0, #marks())
		assert.equals(0, counts.reads)
		assert.equals(0, counts.fence_parses)
		assert.equals(0, counts.parsers)
		config.syntax.input_markdown = true
		refresh()
		assert.is_true(#marks() > 0)
		config.syntax.max_lines = 1
		refresh()
		assert.equals(0, #marks())
		config.syntax.max_lines = 500
		refresh()
		assert.is_true(#marks() > 0)
		reset_counts()
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		flush_and_compare()
		assert.equals(2, counts.parsers)
	end)

	it("discards a queued update when the buffer closes and removes its callbacks", function()
		local before = #vim.api.nvim_get_autocmds({ group = "OpenCodeInputSyntax" })
		input_syntax.attach(bufnr)
		assert.equals(1, #queue)
		vim.api.nvim_buf_delete(bufnr, { force = true })
		drain()
		assert.equals(0, counts.reads)
		assert.equals(0, counts.parsers)
		assert.equals(0, counts.sets)
		assert.equals(before, #vim.api.nvim_get_autocmds({ group = "OpenCodeInputSyntax" }))
	end)

	it("re-executes stateful query predicates on every ordinary refresh", function()
		local enabled = true
		vim.treesitter.query.add_predicate("input_reuse_external?", function() return enabled end,
			{ force = true, all = true })
		local custom = vim.treesitter.query.parse("lua", "((identifier) @variable (#input_reuse_external? @variable))")
		vim.treesitter.query.get = function(language, name)
			if language == "lua" and name == "highlights" then return custom end
			return originals.query_get(language, name)
		end
		input_syntax.attach(bufnr)
		flush_and_compare()
		assert.is_true(#marks() > 0)
		reset_counts()
		enabled = false
		refresh()
		assert.equals(2, counts.parsers)
		assert.equals(0, #marks())
		reset_counts()
		enabled = true
		refresh()
		assert.equals(2, counts.parsers)
		assert.is_true(#marks() > 0)
	end)

	it("recomputes evicted captures without recreating correct live marks", function()
		input_syntax.attach(bufnr)
		flush_and_compare()
		local original_ids = ids()
		memo.clear_all()
		reset_counts()
		refresh()
		assert.equals(2, counts.parsers)
		assert.equals(0, counts.sets)
		assert.equals(0, counts.deletes)
		assert.same(original_ids, ids())
		local pressure = memo.new("input-reuse-pressure")
		local value = string.rep("x", 9 * 1024 * 1024)
		pressure:put("first", 1, value)
		pressure:put("second", 1, value)
		reset_counts()
		refresh()
		assert.equals(2, counts.parsers)
		assert.equals(0, counts.sets)
		assert.same(original_ids, ids())
		assert.is_true(memo.stats().bytes <= memo.stats().max_bytes)
	end)

	it("removes unowned namespace marks while retaining unchanged owned IDs", function()
		input_syntax.attach(bufnr)
		flush_and_compare()
		local owned = ids()
		local extra = originals.set_mark(bufnr, namespace, 0, 0, { end_col = 3, hl_group = "ErrorMsg", priority = 99 })
		reset_counts()
		refresh()
		assert.same(owned, ids())
		assert.same({}, vim.api.nvim_buf_get_extmark_by_id(bufnr, namespace, extra, {}))
		assert.equals(0, counts.parsers)
		assert.equals(0, counts.sets)
		assert.equals(1, counts.deletes)
	end)
end)
