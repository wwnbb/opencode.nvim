local syntax = require("opencode.ui.syntax")
local api = vim.treesitter.query

local function upvalue(fn, wanted)
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if name == wanted then return value end
		if name == nil then break end
	end
end

local serial = 0
local function query(predicate)
	serial = serial + 1
	return api.parse("lua", "((identifier) @variable " .. predicate .. ")\n; fixture " .. serial)
end

local function first_pattern(value)
	local _, patterns = next(value.info.patterns)
	return patterns[1]
end

describe("conservative query capture memo eligibility", function()
	local predicates, directives, saved

	before_each(function()
		local value = query('(#eq? @variable "value")')
		predicates = assert(upvalue(value._match_predicates, "predicate_handlers"))
		directives = assert(upvalue(value._apply_directives, "directive_handlers"))
		saved = { eq = predicates["eq?"], set = directives["set!"], debug = debug.getupvalue,
			getinfo = debug.getinfo, sort = table.sort, concat = table.concat,
			parser = vim.treesitter.get_string_parser }
	end)

	after_each(function()
		api.add_predicate("eq?", saved.eq, { force = true, all = true })
		api.add_directive("set!", saved.set, { force = true, all = true })
		debug.getupvalue = saved.debug
		debug.getinfo, table.sort, table.concat = saved.getinfo, saved.sort, saved.concat
		vim.treesitter.get_string_parser = saved.parser
		api.set("lua", "highlights", nil)
	end)

	it("accepts the actual Lua query and stays stable after runtime predicate memoization", function()
		local value = api.get("lua", "highlights")
		local signature = syntax.query_cache_signature(value)
		assert.is_string(signature)
		local captures, status = syntax.highlight_text('local value = math.abs(1)\nreturn value', "lua", { min_bytes = 0 })
		assert.equals("ok", status)
		assert.is_true(#captures > 0)
		assert.equals(signature, syntax.query_cache_signature(value))
		assert.is_string(syntax.query_cache_signature(query('(#not-eq? @variable "value")')))
	end)

	it("rejects unknown predicates and option-sensitive Vim regex predicates", function()
		for _, predicate in ipairs({
			'(#external-state? @variable)', '(#match? @variable "value")',
			'(#any-match? @variable "value")', '(#vim-match? @variable "value")',
		}) do assert.is_nil(syntax.query_cache_signature(query(predicate))) end
	end)

	it("detects direct and legacy-adapter overrides even when registered before first inspection", function()
		for _, all in ipairs({ true, false }) do
			api.add_predicate("eq?", function() return true end, { force = true, all = all })
			assert.is_nil(syntax.query_cache_signature(query('(#eq? @variable "value")')))
			api.add_predicate("eq?", saved.eq, { force = true, all = true })
			api.add_directive("set!", function() end, { force = true, all = all })
			assert.is_nil(syntax.query_cache_signature(query('(#set! priority 150)')))
			api.add_directive("set!", saved.set, { force = true, all = true })
		end
	end)

	it("invalidates observed warm query generations on handler replacement and recovery", function()
		local value = query('(#eq? @variable "value")')
		local signature = syntax.query_cache_signature(value)
		local generation = syntax.get_cache_generation()
		api.add_predicate("eq?", function() return false end, { force = true, all = true })
		assert.is_true(syntax.get_cache_generation() > generation)
		assert.is_nil(syntax.query_cache_signature(value))
		generation = syntax.get_cache_generation()
		api.add_predicate("eq?", saved.eq, { force = true, all = true })
		assert.is_true(syntax.get_cache_generation() > generation)
		assert.equals(signature, syntax.query_cache_signature(value))
	end)

	it("tracks exact literal arguments and capture names without trusting mutable query identity", function()
		local value = query('(#eq? @variable "value")')
		local signature = syntax.query_cache_signature(value)
		first_pattern(value)[3] = "other"
		local changed = syntax.query_cache_signature(value)
		assert.is_string(changed)
		assert.is_not.equals(signature, changed)
		value.captures[1] = "constant"
		assert.is_not.equals(changed, syntax.query_cache_signature(value))
		first_pattern(value)[1] = "external-state?"
		assert.is_nil(syntax.query_cache_signature(value))
	end)

	it("reuses warm tokens without sorting, serialization or repeated function introspection", function()
		local inspect = require("opencode.ui.syntax_query").signature
		local value = api.get("lua", "highlights")
		local signature = inspect(value)
		assert.is_string(signature)
		local calls = { sort = 0, concat = 0, getinfo = 0 }
		table.sort = function(...)
			calls.sort = calls.sort + 1
			return saved.sort(...)
		end
		table.concat = function(...)
			calls.concat = calls.concat + 1
			return saved.concat(...)
		end
		debug.getinfo = function(...)
			calls.getinfo = calls.getinfo + 1
			return saved.getinfo(...)
		end
		local signatures = {}
		for index = 1, 20 do signatures[index] = inspect(value) end
		debug.getinfo, table.sort, table.concat = saved.getinfo, saved.sort, saved.concat
		for _, actual in ipairs(signatures) do assert.equals(signature, actual) end
		assert.same({ sort = 0, concat = 0, getinfo = 0 }, calls)
	end)

	it("distinguishes replacement native queries with identical tostring representations", function()
		local value, replacement = query('(#eq? @variable "value")'), query('(#eq? @variable "other")')
		assert.equals(tostring(value.query), tostring(replacement.query))
		assert.is_not.equals(value.query, replacement.query)
		local signature = syntax.query_cache_signature(value)
		value.query = replacement.query
		local changed = syntax.query_cache_signature(value)
		assert.is_string(changed)
		assert.is_not.equals(signature, changed)
		assert.equals(changed, syntax.query_cache_signature(value))
	end)

	it("detects added and removed metadata keys as well as nested processed changes", function()
		local value = query('(#eq? @variable "value")')
		local signature = syntax.query_cache_signature(value)
		value.captures[2] = "constant"
		local added = syntax.query_cache_signature(value)
		assert.is_string(added)
		assert.is_not.equals(signature, added)
		value.captures[2] = nil
		assert.is_not.equals(added, syntax.query_cache_signature(value))
		local _, processed = next(value._processed_patterns)
		processed.predicates[1][2] = false
		assert.is_nil(syntax.query_cache_signature(value))
		processed.predicates[1][2] = true
		assert.is_string(syntax.query_cache_signature(value))
		processed.predicates[1].unexpected = true
		assert.is_nil(syntax.query_cache_signature(value))
		processed.predicates[1].unexpected = nil
		assert.is_string(syntax.query_cache_signature(value))
		processed.predicates[1][false] = "unexpected boolean key"
		assert.is_nil(syntax.query_cache_signature(value))
	end)

	it("safely declines malformed metadata and introspection responses", function()
		local value = query('(#eq? @variable "value")')
		assert.is_string(syntax.query_cache_signature(value))
		value.info = setmetatable({}, { __index = function() error("external metadata") end })
		assert.is_nil(syntax.query_cache_signature(value))
		local isolated = dofile("lua/opencode/ui/syntax_query.lua")
		value = query('(#eq? @variable "value")')
		debug.getinfo = function() return true end
		local malformed = isolated.signature(value)
		debug.getinfo = function() error("unavailable introspection") end
		local unavailable = isolated.signature(value)
		debug.getinfo = saved.getinfo
		debug.getupvalue = function() error("unavailable registry") end
		local missing_registry = isolated.signature(value)
		debug.getupvalue = saved.debug
		assert.is_nil(malformed)
		assert.is_nil(unavailable)
		assert.is_nil(missing_registry)
	end)

	it("requires public patterns and executed processed handler records to agree", function()
		local value = query('(#eq? @variable "value")')
		assert.is_string(syntax.query_cache_signature(value))
		local _, processed = next(value._processed_patterns)
		processed.predicates[1][1] = "external-state?"
		assert.is_nil(syntax.query_cache_signature(value))
		processed.predicates[1][1] = "eq?"
		local _, patterns = next(value.info.patterns)
		patterns[1] = { "eq?", 1, "value" }
		assert.is_nil(syntax.query_cache_signature(value))
	end)

	it("falls back for unknown runtime layouts, iterator replacements and unavailable introspection", function()
		local value = query('(#eq? @variable "value")')
		value._processed_patterns = nil
		assert.is_nil(syntax.query_cache_signature(value))
		value = query('(#eq? @variable "another")')
		value.iter_captures = function() end
		assert.is_nil(syntax.query_cache_signature(value))
		debug.getupvalue = nil
		assert.is_nil(syntax.query_cache_signature(query('(#eq? @variable "new")')))
	end)

	it("preserves externally stateful successful captures while forcing ordinary recomputation", function()
		local accepts = true
		api.add_predicate("eq?", function() return accepts end, { force = true, all = true })
		api.set("lua", "highlights", '((identifier) @variable (#eq? @variable "value"))')
		local first, first_status = syntax.highlight_text("return value", "lua", { min_bytes = 0 })
		assert.is_true(#first > 0)
		assert.equals("retry", first_status)
		accepts = false
		local second, second_status = syntax.highlight_text("return value", "lua", { min_bytes = 0 })
		assert.same({}, second)
		assert.equals("retry", second_status)
	end)

	it("refreshes direct source signatures for parser replacement without requiring a render frame", function()
		local first = syntax.cache_signature("lua", { min_bytes = 0 })
		vim.treesitter.get_string_parser = function() error("unavailable") end
		assert.is_not.equals(first, syntax.cache_signature("lua", { min_bytes = 0 }))
	end)
end)
