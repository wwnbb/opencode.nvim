local completion = require("opencode.completion.context")
local explanation = require("opencode.explanation.context")

-- Frozen pre-optimization implementations retain whole-prompt encoding after
-- every attempted insertion, including custom encoder calls and rollbacks.
local legacy_completion = assert(loadfile("tests/fixtures/hot_paths/completion_context_legacy.lua"))()
local explanation_chunk = assert(loadfile("tests/fixtures/hot_paths/explanation_context_legacy.lua"))
setfenv(explanation_chunk, setmetatable({
	require = function(name)
		if name == "opencode.completion.context" then return legacy_completion end
		return require(name)
	end,
}, { __index = _G }))
local legacy_explanation = explanation_chunk()

local function pack(...) return { n = select("#", ...), ... } end

local function override(object, key, replacement, run)
	local original = object[key]
	object[key] = replacement
	local result = pack(pcall(run))
	object[key] = original
	assert.is_true(result[1], result[2])
	return unpack(result, 2, result.n)
end

local function decoded(prompt)
	return vim.json.decode(prompt:match("Context %(JSON%):\n(.*)$"))
end

describe("editor context incremental JSON equivalence", function()
	local buffers, original_buf
	local root = "/tmp/opencode-context-equivalence"
	local function buffer(path, content, filetype)
		local bufnr = vim.api.nvim_create_buf(true, false)
		buffers[#buffers + 1] = bufnr
		vim.api.nvim_buf_set_name(bufnr, root .. "/" .. path)
		vim.bo[bufnr].filetype = filetype or "lua"
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
		return bufnr
	end
	local function snapshot(bufnr, row, col)
		local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
		return { bufnr = bufnr, path = vim.api.nvim_buf_get_name(bufnr), root = root,
			filetype = vim.bo[bufnr].filetype, row = row, col = col,
			prefix = line:sub(1, col), suffix = line:sub(col + 1) }
	end
	local function selection(bufnr, first, last, mode)
		local selected = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
		return { bufnr = bufnr, path = vim.api.nvim_buf_get_name(bufnr), root = root,
			filetype = vim.bo[bufnr].filetype, mode = mode or "V", start_line = first,
			end_line = last, lines = selected, text = table.concat(selected, "\n") }
	end
	local function options()
		return { max_lines = 8, language = "ru", context = {
			max_bytes = 1000000, before_lines = 3, after_lines = 3, header_lines = 2,
			max_related_buffers = 4, related_lines = 3,
		} }
	end
	local function compare(actual, legacy, snap, opts, previous)
		local expected = pack(legacy.build(snap, vim.deepcopy(opts), previous))
		local result = pack(actual.build(snap, vim.deepcopy(opts), previous))
		assert.same(expected, result, "prompt and error at budget " .. opts.context.max_bytes)
		if result[1] then assert.is_true(#result[1] <= opts.context.max_bytes) end
		return result[1], result[2]
	end
	before_each(function() buffers = {}; original_buf = vim.api.nvim_get_current_buf() end)
	after_each(function()
		vim.api.nvim_set_current_buf(original_buf)
		for _, bufnr in ipairs(buffers) do vim.api.nvim_buf_delete(bufnr, { force = true }) end
	end)

	it("matches complete UTF-8 and escaped prompts at exact and one-byte-short budgets", function()
		local content = { '-- header "é" \\', "local dependency = 'helper'", "\t-- combining é",
			'local value = "🙂é"', "after('\\')", "return value\t-- tail", "-- final\r" }
		local bufnr = buffer("main.lua", content)
		buffer("lib/helper.lua", { 'return "λ\\\""', "-- emoji 🙂", "-- tab\t" })
		buffer("sibling.lua", { "local sibling = 1", "return sibling" })
		local cases = {
			{ actual = completion, legacy = legacy_completion, snap = snapshot(bufnr, 3, #'local value = "🙂'), previous = "next\n\t\"é\\🙂" },
			{ actual = explanation, legacy = legacy_explanation, snap = selection(bufnr, 4, 5) },
			{ actual = explanation, legacy = legacy_explanation, snap = selection(bufnr, 4, 5, "\022"), prompt = "Explain {language}: \"quoted\" \\ " },
		}
		for _, case in ipairs(cases) do
			local opts = options()
			opts.prompt = case.prompt
			local full = assert(compare(case.actual, case.legacy, case.snap, opts, case.previous))
			local minimal_opts = vim.deepcopy(opts)
			minimal_opts.context.before_lines, minimal_opts.context.after_lines, minimal_opts.context.header_lines = 0, 0, 0
			minimal_opts.context.max_related_buffers = 0
			local minimal = assert(case.legacy.build(case.snap, minimal_opts))
			for _, limit in ipairs({ #minimal - 1, #minimal, #minimal + 1, #full - 1, #full, #full + 1 }) do
				opts.context.max_bytes = limit
				compare(case.actual, case.legacy, case.snap, opts, case.previous)
			end
		end
	end)

	it("retains or rejects the entire previous suggestion at its exact serialized boundary", function()
		local bufnr = buffer("previous.lua", { "local value = " })
		local snap, opts = snapshot(bufnr, 0, #"local value = "), options()
		opts.context.before_lines, opts.context.after_lines, opts.context.header_lines = 0, 0, 0
		opts.context.max_related_buffers = 0
		local previous = "é🙂\n\t\"\\\r"
		local base = assert(legacy_completion.build(snap, opts))
		local full = assert(legacy_completion.build(snap, opts, previous))
		for _, limit in ipairs({ #base - 1, #base, #full - 1, #full }) do
			opts.context.max_bytes = limit
			local prompt = compare(completion, legacy_completion, snap, opts, previous)
			if prompt then assert.equals(limit >= #full and previous or nil, decoded(prompt).previous_suggestion) end
		end
	end)

	it("accounts for nested related entries, commas, and rollback when no whole line fits", function()
		local bufnr = buffer("main.lua", { "local value = " })
		local related = buffer("a.lua", { string.rep("é\\\"", 40), "tail" })
		local snap, opts = snapshot(bufnr, 0, #"local value = "), options()
		opts.context.before_lines, opts.context.after_lines, opts.context.header_lines = 0, 0, 0
		opts.context.related_lines, opts.context.max_related_buffers = 2, 2
		local no_related = vim.deepcopy(opts)
		no_related.context.max_related_buffers = 0
		local base = assert(legacy_completion.build(snap, no_related))
		local prefix = base:match("^(.*Context %(JSON%):\n)")
		local empty = decoded(base)
		empty.related = { { path = "a.lua", start_line = 1, lines = {} } }
		local empty_bytes = #prefix + #vim.json.encode(empty)
		opts.context.max_bytes = empty_bytes
		assert.same({}, decoded(assert(compare(completion, legacy_completion, snap, opts))).related)
		empty.related[1].lines = { string.rep("é\\\"", 40) }
		local first_line_bytes = #prefix + #vim.json.encode(empty)
		for _, limit in ipairs({ empty_bytes - 1, empty_bytes, first_line_bytes - 1, first_line_bytes }) do
			opts.context.max_bytes = limit
			compare(completion, legacy_completion, snap, opts)
		end
		vim.api.nvim_buf_set_lines(related, 0, -1, false, { '"a"', "λ" })
		buffer("b.lua", { "\tsecond", "🙂" })
		opts.context.max_bytes = 1000000
		local full = assert(compare(completion, legacy_completion, snap, opts))
		assert.equals(2, #decoded(full).related)
		for limit = #full - 16, #full do
			opts.context.max_bytes = limit
			compare(completion, legacy_completion, snap, opts)
		end
	end)

	it("keeps arbitrary exported encoders and their insertion/rollback call sequence unchanged", function()
		local bufnr = buffer("custom.lua", { "header", "before far", "before near", "focus", "after near", "after far" })
		buffer("sibling.lua", { "related one", "related two" })
		local snap, settings = snapshot(bufnr, 3, 5), options().context
		settings.max_bytes = 400
		local function collect(module)
			local data = { seed = "é", before = {}, after = {}, header = {}, related = {} }
			local calls = {}
			local function encode(value)
				calls[#calls + 1] = vim.deepcopy(value)
				return string.rep("x", #vim.json.encode(value) * (1 + #value.before) + #calls)
			end
			module.add_surroundings(snap, settings, data, encode, 3, 3, "focus")
			return { data = data, calls = calls }
		end
		local expected = collect(legacy_completion)
		assert.is_true(#expected.calls > 2)
		assert.same(expected, collect(completion))
	end)

	it("encodes the growing whole payload only at the start and finish of both built-in builders", function()
		local content = {}
		for index = 1, 200 do content[index] = "local line_" .. index .. " = '\\é🙂\"'" end
		local bufnr = buffer("main.lua", content)
		for index = 1, 4 do buffer("related" .. index .. ".lua", content) end
		local opts = options()
		opts.context.before_lines, opts.context.after_lines, opts.context.header_lines = 80, 80, 10
		opts.context.related_lines = 30
		local function measured(module, snap)
			local original_encode, roots, bytes = vim.json.encode, 0, 0
			local prompt = override(vim.json, "encode", function(value, ...)
				local result = original_encode(value, ...)
				bytes = bytes + #result
				if type(value) == "table" and value.before and (value.cursor or value.selection) then roots = roots + 1 end
				return result
			end, function() return assert(module.build(snap, opts)) end)
			return prompt, roots, bytes
		end
		for _, case in ipairs({
			{ completion, legacy_completion, snapshot(bufnr, 99, #content[100]) },
			{ explanation, legacy_explanation, selection(bufnr, 100, 101) },
		}) do
			local expected, old_roots, old_bytes = measured(case[2], case[3])
			local actual, roots, bytes = measured(case[1], case[3])
			assert.equals(expected, actual)
			assert.is_true(old_roots > 150)
			assert.equals(2, roots)
			assert.is_true(bytes < old_bytes / 5)
		end
	end)

	it("memoizes repeated positive and negative path searches without truncating candidate ranking", function()
		local focus = "local helper = value"
		local bufnr = buffer("main.lua", { focus })
		local recency, expected = {}, {}
		for index = 1, 40 do
			local path = string.format("group%02d/helper.lua", index)
			local related = buffer(path, { "return " .. index })
			recency[related] = index % 3
			expected[#expected + 1] = { path = path, lastused = index % 3 }
		end
		for index = 1, 10 do buffer("unused" .. index .. "/missing.lua", { "not referenced" }) end
		local sibling = buffer("sibling.lua", { "low rank even when recent" })
		recency[sibling] = 100000
		table.sort(expected, function(a, b)
			return a.lastused ~= b.lastused and a.lastused > b.lastused or (a.lastused == b.lastused and a.path < b.path)
		end)
		local snap, opts = snapshot(bufnr, 0, #focus), options()
		opts.context.before_lines, opts.context.after_lines, opts.context.header_lines = 0, 0, 0
		opts.context.max_related_buffers, opts.context.related_lines = 3, 1
		local original_info = vim.fn.getbufinfo
		override(vim.fn, "getbufinfo", function(buf)
			if recency[buf] ~= nil then return { { lastused = recency[buf], lnum = 1 } } end
			return original_info(buf)
		end, function()
			local reference = "\n\n" .. focus .. "\n"
			local function measured(module)
				local original_find, searches = string.find, {}
				local prompt = override(string, "find", function(value, needle, first, plain)
					if value == reference then
						local key = (plain and "plain:" or "pattern:") .. needle
						searches[key] = (searches[key] or 0) + 1
					end
					return original_find(value, needle, first, plain)
				end, function() return assert(module.build(snap, opts)) end)
				return prompt, searches
			end
			local old_prompt, old_searches = measured(legacy_completion)
			local prompt, searches = measured(completion)
			assert.equals(old_prompt, prompt)
			assert.equals(40, old_searches["plain:helper.lua"])
			assert.equals(1, searches["plain:helper.lua"])
			assert.equals(1, searches["pattern:%f[%w_]helper%f[^%w_]"])
			assert.equals(10, old_searches["plain:missing.lua"])
			assert.equals(1, searches["plain:missing.lua"])
			assert.equals(1, searches["pattern:%f[%w_]missing%f[^%w_]"])
			for index = 1, 40 do assert.equals(1, searches[string.format("plain:group%02d/helper.lua", index)]) end
			for index, entry in ipairs(decoded(prompt).related) do assert.equals(expected[index].path, entry.path) end
		end)
	end)
end)
