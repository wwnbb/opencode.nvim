local syntax = require("opencode.ui.syntax")
local input_syntax = require("opencode.ui.input.syntax")
local app = require("opencode.state")
local memory = require("opencode.util.memo")
local namespace = vim.api.nvim_create_namespace("opencode_input_syntax")
local serial = 0

describe("input captures with native query mutation", function()
	local bufnr, saved, queued, parser_calls

	local function drain()
		while #queued > 0 do table.remove(queued, 1)() end
	end

	local function snapshot()
		local result = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
			result[#result + 1] = { mark[2], mark[3], mark[4].end_col, mark[4].hl_group, mark[4].priority }
		end
		table.sort(result, function(a, b) return vim.inspect(a) < vim.inspect(b) end)
		return result
	end

	local function equivalent()
		local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		local expected = {}
		vim.treesitter.get_string_parser = saved.parser
		for _, hl in ipairs(syntax.highlight_markdown_fenced_blocks(text, { scope = "input_markdown", priority = 100 })) do
			expected[#expected + 1] = { hl.line, hl.col_start, hl.col_end, hl.hl_group, hl.priority }
		end
		vim.treesitter.get_string_parser = saved.counting_parser
		table.sort(expected, function(a, b) return vim.inspect(a) < vim.inspect(b) end)
		assert.same(expected, snapshot())
	end

	local function refresh()
		vim.api.nvim_buf_set_lines(bufnr, 4, 5, false, { "after" })
		drain()
	end

	before_each(function()
		serial = serial + 1
		saved = { schedule = vim.schedule, parser = vim.treesitter.get_string_parser, config = app.get_config }
		local config = vim.deepcopy(require("opencode.config").defaults)
		app.get_config = function() return config end
		queued, parser_calls = {}, 0
		vim.schedule = function(fn) queued[#queued + 1] = fn end
		saved.counting_parser = function(...)
			parser_calls = parser_calls + 1
			return saved.parser(...)
		end
		vim.treesitter.get_string_parser = saved.counting_parser
		vim.treesitter.query.set("lua", "highlights", '(identifier) @variable\n(number) @number\n; native mutation fixture ' .. serial)
		memory.clear_all()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "```lua", "local value = 1", "return value", "```", "after" })
	end)

	after_each(function()
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		drain()
		vim.schedule, vim.treesitter.get_string_parser, app.get_config = saved.schedule, saved.parser, saved.config
		vim.treesitter.query.set("lua", "highlights", nil)
		if saved.node_methods then saved.node_methods.child_count = saved.child_count end
		memory.clear_all()
	end)

	for _, method in ipairs({ "disable_capture", "disable_pattern" }) do
		it("observes " .. method .. " through a native alias saved before warming", function()
			local query = vim.treesitter.query.get("lua", "highlights")
			local native, mutate = query.query, query.query[method]
			input_syntax.attach(bufnr)
			drain()
			assert.equals(1, parser_calls)
			local before = snapshot()
			parser_calls = 0
			refresh()
			assert.equals(0, parser_calls, "Unchanged native query reuses the source AST")
			mutate(native, method == "disable_capture" and "variable" or 1)
			refresh()
			assert.equals(0, parser_calls, "Native capture mutation requires capture evaluation, not reparsing source")
			assert.is_true(#snapshot() < #before)
			equivalent()
		end)
	end

	it("rechecks the native userdata when a public Query table retains its identity", function()
		local query = vim.treesitter.query.get("lua", "highlights")
		input_syntax.attach(bufnr)
		drain()
		local before = snapshot()
		local replacement = vim.treesitter.query.parse("lua", '(identifier) @variable\n(number) @number\n; native replacement ' .. serial)
		replacement.query:disable_capture("variable")
		query.query = replacement.query
		refresh()
		assert.is_true(#snapshot() < #before)
		equivalent()
	end)

	it("accounts retained native tree memory in the shared pool and releases it on detach", function()
		input_syntax.attach(bufnr)
		drain()
		local pool = memory.new("input_syntax")
		local trees = memory.new("input_syntax_trees")
		assert.equals(1, pool:stats().entries)
		assert.equals(1, trees:stats().entries)
		assert.is_true(trees:stats().bytes > 4096, "Native AST memory must supplement Lua packet accounting")
		vim.api.nvim_buf_delete(bufnr, { force = true })
		assert.equals(0, pool:stats().entries)
		assert.equals(0, trees:stats().entries)
	end)

	it("keeps fifty fence metadata entries warm when only some native trees fit", function()
		local node = saved.parser("local value = 1", "lua"):parse()[1]:root()
		saved.node_methods = getmetatable(node).__index
		saved.child_count = saved.node_methods.child_count
		local visits = 0
		saved.node_methods.child_count = function(...)
			visits = visits + 1
			return saved.child_count(...)
		end
		local pressure = memory.new("input_tree_pressure")
		pressure:put("fixture", "steady", string.rep("x", 14 * 1024 * 1024))
		local lines = {}
		for fence = 1, 50 do
			lines[#lines + 1] = "```lua"
			for row = 1, 40 do lines[#lines + 1] = "local value" .. row .. " = " .. fence end
			lines[#lines + 1] = "```"
		end
		lines[#lines + 1] = "after"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		input_syntax.attach(bufnr)
		drain()
		assert.equals(50, parser_calls)
		assert.is_true(visits > 0)
		assert.equals(50, memory.new("input_syntax"):stats().entries)
		local retained = memory.new("input_syntax_trees"):stats().entries
		assert.is_true(retained > 0 and retained < 50)
		for _ = 1, 2 do
			parser_calls, visits = 0, 0
			vim.api.nvim_buf_set_lines(bufnr, #lines - 1, #lines, false, { "after" })
			drain()
			assert.equals(50 - retained, parser_calls)
			assert.equals(0, visits, "Unretained native trees must reuse the admitted size estimate")
			assert.equals(50, memory.new("input_syntax"):stats().entries)
			assert.is_true(memory.stats().bytes <= memory.stats().max_bytes)
			-- Exclude the fresh oracle parse from the input work counter.
			local counted = parser_calls
			equivalent()
			parser_calls = counted
		end
	end)
end)
