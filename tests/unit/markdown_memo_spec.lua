local inline = require("opencode.ui.markdown.inline")
local wrap = require("opencode.ui.markdown.wrap")
local memo = require("opencode.util.memo")
local render = require("opencode.ui.chat.render")
local reference_wrap = dofile("tests/helpers/markdown_wrap_reference.lua")

local function chunks_text(chunks)
	local result = {}
	for _, chunk in ipairs(chunks) do result[#result + 1] = chunk.text end
	return table.concat(result)
end

local function handlers(method, name)
	for index = 1, 100 do
		local key, value = debug.getupvalue(method, index)
		if key == name then return value end
		if key == nil then break end
	end
	error("Missing query handler registry " .. name)
end

describe("pure Markdown memoization", function()
	local parser, language_add, old_config, get_config, eq_handler, set_handler, query_module
	local query_signature, query_get
	local query_restores, new_context
	local generation_refresh
	before_each(function()
		memo.clear_all()
		parser, language_add = vim.treesitter.get_string_parser, vim.treesitter.language.add
		old_config = require("opencode.state").get_config()
		get_config = require("opencode.state").get_config
		eq_handler = handlers(vim.treesitter.query.add_predicate, "predicate_handlers")["eq?"]
		set_handler = handlers(vim.treesitter.query.add_directive, "directive_handlers")["set!"]
		query_module = package.loaded["opencode.ui.syntax_query"]
		query_signature = require("opencode.ui.syntax").query_cache_signature
		query_get = vim.treesitter.query.get
		query_restores, new_context = {}, inline.new_context
		generation_refresh = require("opencode.ui.syntax").get_cache_generation
		require("opencode.state").set_config(vim.deepcopy(require("opencode.config").defaults))
	end)
	after_each(function()
		vim.treesitter.get_string_parser, vim.treesitter.language.add = parser, language_add
		require("opencode.state").get_config = get_config
		vim.treesitter.query.add_predicate("eq?", eq_handler, { force = true, all = true })
		vim.treesitter.query.add_directive("set!", set_handler, { force = true, all = true })
		package.loaded["opencode.ui.syntax_query"] = query_module
		require("opencode.ui.syntax").query_cache_signature = query_signature
		vim.treesitter.query.get = query_get
		inline.new_context = new_context
		require("opencode.ui.syntax").get_cache_generation = generation_refresh
		for index = #query_restores, 1, -1 do
			local item = query_restores[index]
			item[1][item[2]] = item[3]
		end
		require("opencode.state").set_config(old_config)
		memo.clear_all()
	end)

	local function change_capture(query, index, name)
		query_restores[#query_restores + 1] = { query.captures, index, query.captures[index] }
		query.captures[index] = name
	end

	local function capture_inline_query()
		local found = {}
		require("opencode.ui.syntax").query_cache_signature = function(query)
			for index, name in pairs(query.captures) do
				if name == "markup.strong" then found.query, found.index = query, index end
			end
			found.calls = (found.calls or 0) + 1
			return query_signature(query)
		end
		return found
	end

	local function has_group_at(result, label, group)
		local row
		for index, value in ipairs(render.extract_lines(result)) do if value:find(label, 1, true) then row = index - 1; break end end
		for _, span in ipairs(result._opencode_highlights) do
			if span.line == row and span.hl_group == group then return true end
		end
		return false
	end

	it("reuses successful inline parsing while returning fresh mutable chunks", function()
		local calls = 0
		vim.treesitter.get_string_parser = function(...)
			calls = calls + 1
			return parser(...)
		end
		local first, retry = inline.parse("**value**")
		assert.is_false(retry)
		local expected = vim.deepcopy(first)
		first[1].text, first[1].hl = "changed", "ChangedHighlight"
		first[2] = { text = "extra" }
		assert.same(expected, inline.parse("**value**"))
		assert.equals(1, calls)
		inline.parse("**value**", "OpenCodeMarkdownQuote")
		assert.equals(2, calls)
	end)

	it("keys table cells by the whole reference map independent of insertion order", function()
		local calls = 0
		vim.treesitter.get_string_parser = function(...)
			calls = calls + 1
			return parser(...)
		end
		local references = { label = "/first", unused = "/other" }
		assert.equals("label (/first)", chunks_text(inline.table("[label]", references)))
		inline.table("[label]", { unused = "/other", label = "/first" })
		assert.equals(1, calls)
		references.unused = "/changed"
		inline.table("[label]", references)
		assert.equals(2, calls)
		references.label = "/second"
		assert.equals("label (/second)", chunks_text(inline.table("[label]", references)))
		assert.equals(3, calls)
		references.label = nil
		assert.equals("[label]", chunks_text(inline.table("[label]", references)))
		assert.equals(4, calls)
	end)

	it("validates only its own loaded query dependencies once on warm calls", function()
		local syntax = require("opencode.ui.syntax")
		-- Observe an unrelated code query, as a mixed transcript does before its
		-- Markdown paragraphs. Only an outer frame must refresh that dependency.
		syntax.cache_signature("lua", { min_bytes = 0 })
		local unrelated = query_get("lua", "highlights")
		for _ = 1, 2 do
			inline.parse("**owned dependency**")
			inline.parse("# Heading **owned dependency**", nil, "markdown")
			inline.table("**owned cell**")
		end
		local checked, unrelated_checks, lookups = 0, 0, 0
		syntax.query_cache_signature = function(value)
			checked = checked + 1
			if value == unrelated then unrelated_checks = unrelated_checks + 1 end
			return query_signature(value)
		end
		vim.treesitter.query.get = function(...)
			lookups = lookups + 1
			return query_get(...)
		end
		inline.parse("**owned dependency**")
		assert.equals(1, checked)
		checked = 0
		inline.parse("# Heading **owned dependency**", nil, "markdown")
		assert.equals(2, checked)
		checked = 0
		inline.table("**owned cell**")
		assert.equals(0, checked)
		assert.equals(0, unrelated_checks)
		assert.equals(0, lookups)
		-- The default path remains comprehensive for warm outer render caches.
		syntax.get_cache_generation()
		assert.is_true(unrelated_checks > 0)
		assert.is_true(lookups > 0)
	end)

	it("fully validates once per warm Markdown render and observes metadata changes between renders", function()
		local found = capture_inline_query()
		local source = ("**many paragraphs**\n\n"):rep(40)
		render.render_content(source); render.render_content(source)
		assert.is_table(found.query)
		local refreshes = 0
		require("opencode.ui.syntax").get_cache_generation = function(...)
			refreshes = refreshes + 1
			return generation_refresh(...)
		end
		found.calls = 0
		render.render_content(source)
		assert.equals(1, found.calls)
		assert.equals(1, refreshes)
		render.render_content(source)
		assert.equals(2, found.calls)
		assert.equals(2, refreshes)
		change_capture(found.query, found.index, "markup.italic")
		local changed = render.render_content(source)
		assert.is_true(has_group_at(changed, "many paragraphs", "OpenCodeMarkdownEmphasis"))
		assert.is_false(has_group_at(changed, "many paragraphs", "OpenCodeMarkdownStrong"))
	end)

	it("refreshes config changes made by a code callback before the next cached paragraph", function()
		local app = require("opencode.state")
		local source = "**before config callback**\n\n```lua\nreturn value\n```\n\n**after config callback**"
		local opts = { highlight_code = function() return {}, "ok" end }
		local parses = 0
		vim.treesitter.get_string_parser = function(value, language, ...)
			if language == "markdown_inline" then parses = parses + 1 end
			return parser(value, language, ...)
		end
		render.render_content(source, opts); render.render_content(source, opts)
		parses = 0
		local refreshes = 0
		require("opencode.ui.syntax").get_cache_generation = function(...)
			refreshes = refreshes + 1
			return generation_refresh(...)
		end
		opts.highlight_code = function()
			local config = app.get_config()
			config.syntax.min_bytes = config.syntax.min_bytes + 1
			app.set_config(config)
			return {}, "ok"
		end
		local changed = render.render_content(source, opts)
		assert.equals(2, refreshes)
		assert.equals(1, parses)
		assert.is_true(has_group_at(changed, "after config callback", "OpenCodeMarkdownStrong"))
	end)

	it("revalidates vendor metadata after a code highlighter callback", function()
		local found = capture_inline_query()
		local source = "**before callback**\n\n```lua\nreturn value\n```\n\n**after callback**"
		local opts = { highlight_code = function() return {}, "ok" end }
		render.render_content(source, opts); render.render_content(source, opts)
		assert.is_table(found.query)
		opts.highlight_code = function()
			change_capture(found.query, found.index, "markup.italic")
			return {}, "skipped"
		end
		local changed = render.render_content(source, opts)
		assert.is_true(has_group_at(changed, "before callback", "OpenCodeMarkdownStrong"))
		assert.is_true(has_group_at(changed, "after callback", "OpenCodeMarkdownEmphasis"))
	end)

	it("revalidates after a full table parse crosses a parser callback", function()
		local found, mutate = capture_inline_query(), false
		vim.treesitter.get_string_parser = function(source, language, ...)
			if mutate and language == "markdown_inline" and source == "cell" then
				mutate = false
				change_capture(found.query, found.index, "markup.italic")
			end
			return parser(source, language, ...)
		end
		local source = "**before table**\n\n| H |\n|---|\n| cell |\n\n**after table**"
		render.render_content(source); render.render_content(source)
		memo.new("markdown_table"):clear()
		mutate = true
		local changed = render.render_content(source)
		assert.is_false(mutate)
		assert.is_true(has_group_at(changed, "before table", "OpenCodeMarkdownStrong"))
		assert.is_true(has_group_at(changed, "after table", "OpenCodeMarkdownEmphasis"))
	end)

	it("fully revalidates after parsing an uncached inline span", function()
		local found, mutate = capture_inline_query(), false
		vim.treesitter.get_string_parser = function(source, language, ...)
			if mutate and language == "markdown_inline" and source == "**trigger full parse**" then
				mutate = false
				change_capture(found.query, found.index, "markup.italic")
			end
			return parser(source, language, ...)
		end
		local warm = "**before full parse**\n\n**after full parse**"
		render.render_content(warm); render.render_content(warm)
		mutate = true
		local changed = render.render_content("**before full parse**\n\n**trigger full parse**\n\n**after full parse**")
		assert.is_false(mutate)
		assert.is_true(has_group_at(changed, "before full parse", "OpenCodeMarkdownStrong"))
		assert.is_true(has_group_at(changed, "trigger full parse", "OpenCodeMarkdownEmphasis"))
		assert.is_true(has_group_at(changed, "after full parse", "OpenCodeMarkdownEmphasis"))
	end)

	it("re-executes externally stateful directives for every paragraph within a render", function()
		local calls = 0
		vim.treesitter.query.add_directive("set!", function(match, pattern, source, predicate, metadata)
			calls = calls + 1
			set_handler(match, pattern, source, predicate, metadata)
			if metadata.conceal ~= nil then metadata.conceal = calls % 3 == 0 and "!" or "" end
		end, { force = true, all = true })
		local source = ("**stateful paragraph**\n\n"):rep(9)
		local actual = render.render_content(source)
		local actual_calls = calls
		calls = 0
		inline.new_context = function() return nil end
		local expected = render.render_content(source)
		assert.is_true(calls >= 18)
		assert.equals(calls, actual_calls)
		assert.same(render.extract_lines(expected), render.extract_lines(actual))
		assert.same(expected._opencode_highlights, actual._opencode_highlights)
		assert.is_true(actual._opencode_syntax_retry)
	end)

	it("keeps table header styling out of identical body-cell cache entries", function()
		local source = "| **same** |\n|---|\n| **same** |"
		local first = render.render_content(source)
		local last = render.render_content(source)
		assert.same(first._opencode_highlights, last._opencode_highlights)
		local heading, strong = false, false
		for _, span in ipairs(last._opencode_highlights) do
			heading = heading or span.hl_group == "OpenCodeMarkdownHeading"
			strong = strong or span.hl_group == "OpenCodeMarkdownStrong"
		end
		assert.is_true(heading)
		assert.is_true(strong)
		local chunks = inline.table("**same**")
		assert.equals("OpenCodeMarkdownStrong", chunks[1].hl)
		chunks[1].hl = "ChangedHighlight"
		assert.equals("OpenCodeMarkdownStrong", inline.table("**same**")[1].hl)
	end)

	it("retries parser failures after warm results and recovers on the next call", function()
		inline.parse("**recovery**")
		inline.table("**recovery**")
		local failures = 0
		vim.treesitter.get_string_parser = function()
			failures = failures + 1
			error("parser unavailable")
		end
		for _ = 1, 2 do
			local chunks, retry = inline.parse("**recovery**")
			assert.is_true(retry)
			assert.equals("**recovery**", chunks_text(chunks))
			local _, table_retry = inline.table("**recovery**")
			assert.is_true(table_retry)
		end
		assert.equals(4, failures)
		vim.treesitter.get_string_parser = parser
		local chunks, retry = inline.parse("**recovery**")
		assert.is_false(retry)
		assert.equals("recovery", chunks_text(chunks))
		assert.equals("recovery", chunks_text(inline.table("**recovery**")))
	end)

	it("checks parser availability on warm calls and invalidates in-place config changes", function()
		local calls, checks = 0, 0
		local config = require("opencode.state").get_config()
		-- Production getters detach values; also support an integration returning
		-- one mutable config object, as required by the syntax-cache contract.
		require("opencode.state").get_config = function() return config end
		vim.treesitter.get_string_parser = function(...)
			calls = calls + 1
			return parser(...)
		end
		vim.treesitter.language.add = function(...)
			checks = checks + 1
			return language_add(...)
		end
		inline.parse("**configuration**")
		local before = checks
		inline.parse("**configuration**")
		assert.equals(1, calls)
		assert.is_true(checks > before)
		config.syntax.min_bytes = 17
		inline.parse("**configuration**")
		assert.equals(2, calls)
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		inline.parse("**configuration**")
		assert.equals(3, calls)
	end)

	it("matches cold full Markdown results after every structural streaming update", function()
		local traces = {
			{ "paragraph\n\n```lua\nlocal x", "paragraph\n\n```lua\nlocal x = 1\n```", "paragraph\n\n~~~lua\nlocal x = 1\n~~~" },
			{ "| [late] |\n|---|\n| [late] |", "| [late] |\n|---|\n| [late] |\n\n[late]: /first", "| [late] |\n|---|\n| [late] |\n\n[late]: /second" },
			{ "9) one", "9) one\n9) two", "9) one\n9) two\n   - nested **value**" },
			{ "> **Привет 世界**\n> a\tb", "> **Привет 世界**\n> a\tb\n> 👩‍💻 é", "| H |\n|---|", "| H |\n|---|\n| value |" },
		}
		for _, trace in ipairs(traces) do
			for _, source in ipairs(trace) do
				for _, width in ipairs({ 80, 13, 31 }) do
					local warm = render.render_content(source, { width = width })
					inline.clear_cache(); wrap.clear_cache()
					local cold = render.render_content(source, { width = width })
					assert.same(render.extract_lines(cold), render.extract_lines(warm))
					assert.same(cold._opencode_highlights, warm._opencode_highlights)
					for index, line in ipairs(cold) do
						assert.equals(line._opencode_preserve_blank, warm[index]._opencode_preserve_blank)
					end
				end
			end
		end
	end)

	it("invalidates warm completed Markdown and keeps externally stateful results uncached", function()
		local context = require("opencode.ui.chat.render_context")
		local cache = require("opencode.ui.chat.render_state")
		cache.clear_render_cache()
		local builds, enabled = 0, false
		local function frame()
			local ctx = context.new({ current_session = { id = "vendor-query-cache" } })
			local result = ctx:cached_nui_lines("vendor-query-completed-markdown", function()
				builds = builds + 1
				return render.render_content("&lt;")
			end)
			return table.concat(render.extract_lines(result), "\n"), result._opencode_syntax_retry
		end
		assert.equals("<", frame())
		assert.equals("<", frame())
		assert.equals(1, builds)
		vim.treesitter.query.add_predicate("eq?", function(_, _, _, predicate)
			return enabled and predicate[3] == "&lt;"
		end, { force = true, all = true })
		local value, retry = frame()
		assert.equals("&lt;", value)
		assert.is_true(retry)
		assert.equals(2, builds)
		enabled = true
		value, retry = frame()
		assert.equals("<", value)
		assert.is_true(retry)
		assert.equals(3, builds)
		vim.treesitter.query.add_predicate("eq?", eq_handler, { force = true, all = true })
		value, retry = frame()
		assert.equals("<", value)
		assert.is_false(retry)
		assert.equals(4, builds)
		frame()
		assert.equals(4, builds)
		cache.clear_render_cache()
	end)

	for _, all in ipairs({ true, false }) do
		it("recomputes an overridden predicate's external state with all=" .. tostring(all), function()
			assert.equals("<", chunks_text(inline.parse("&lt;")))
			local enabled = true
			vim.treesitter.query.add_predicate("eq?", function(_, _, _, predicate)
				return enabled and predicate[3] == "&lt;"
			end, { force = true, all = all })
			local first, retry, cacheable = inline.parse("&lt;")
			assert.equals("<", chunks_text(first))
			assert.is_false(retry)
			assert.is_false(cacheable)
			enabled = false
			assert.equals("&lt;", chunks_text(inline.parse("&lt;")))
			local rendered = render.render_content("&lt;")
			assert.is_true(rendered._opencode_syntax_retry)
			assert.equals("&lt;", table.concat(render.extract_lines(rendered), "\n"))
			enabled = true
			assert.equals("<", table.concat(render.extract_lines(render.render_content("&lt;")), "\n"))
		end)

		it("rejects a directive installed before inline/helper load with all=" .. tostring(all), function()
			local replacement = "x"
			vim.treesitter.query.add_directive("set!", function(match, pattern, source, predicate, metadata)
				set_handler(match, pattern, source, predicate, metadata)
				if predicate[2] == "conceal" then metadata.conceal = replacement end
			end, { force = true, all = all })
			-- The optional purity helper and this inline module first see the
			-- already-overridden handlers; captured-at-load identity is unsafe.
			package.loaded["opencode.ui.syntax_query"] = nil
			local fresh = dofile("lua/opencode/ui/markdown/inline.lua")
			local first, retry, cacheable = fresh.parse("*stateful*")
			assert.equals("xstatefulx", chunks_text(first))
			assert.is_false(retry)
			assert.is_false(cacheable)
			replacement = "y"
			assert.equals("ystatefuly", chunks_text(fresh.parse("*stateful*")))
			-- The table renderer has no query callbacks and stays cacheable.
			local cell, table_retry, table_cacheable = fresh.table("**stateful**")
			assert.equals("stateful", chunks_text(cell))
			assert.is_false(table_retry)
			assert.is_true(table_cacheable)
		end)
	end
end)

describe("Markdown wrapping fast path", function()
	local options, cellwidths
	before_each(function()
		wrap.clear_cache()
		options = { ambiwidth = vim.o.ambiwidth, emoji = vim.o.emoji, display = vim.o.display,
			tabstop = vim.bo.tabstop, vartabstop = vim.bo.vartabstop }
		cellwidths = vim.fn.getcellwidths()
	end)
	after_each(function()
		vim.o.ambiwidth, vim.o.emoji, vim.o.display = options.ambiwidth, options.emoji, options.display
		vim.bo.tabstop, vim.bo.vartabstop = options.tabstop, options.vartabstop
		vim.fn.setcellwidths(cellwidths)
		wrap.clear_cache()
	end)

	it("matches the original ASCII byte boundaries, punctuation and whitespace behavior", function()
		local inputs = { "", " ", "      ", "   a", "a   ", "  a   b   ", "a-b/c\\d.e,f;g:h!i?j(k)[l]{m}", "abcdefghijk" }
		local seed = 17
		for _ = 1, 150 do
			local chars = {}
			for _ = 1, 120 do
				seed = seed * 48271 % 2147483647
				chars[#chars + 1] = string.char(32 + seed % 95)
			end
			inputs[#inputs + 1] = table.concat(chars)
		end
		for _, source in ipairs(inputs) do
			for _, width in ipairs({ 0, 1, 2, 3, 7, 13.5, 80 }) do
				assert.same(reference_wrap.ranges(source, width), wrap.ranges(source, width), source .. " width=" .. width)
			end
		end
	end)

	it("avoids per-character display-width calls for printable ASCII", function()
		local original, calls = vim.fn.strdisplaywidth, 0
		vim.fn.strdisplaywidth = function(...)
			calls = calls + 1
			return original(...)
		end
		local ok, err = pcall(wrap.ranges, ("ASCII words "):rep(100), 80)
		vim.fn.strdisplaywidth = original
		assert.is_true(ok, err)
		assert.equals(0, calls)
	end)

	it("keeps Unicode, combining characters, emoji and tabs on the original algorithm", function()
		for _, source in ipairs({ "Привет 世界 hello", "é é é", "👩‍💻🙂🏳️‍🌈 text", "a\tb\t界", "a b c", "a\nb\r\001c" }) do
			for _, width in ipairs({ 1, 2, 5, 12 }) do
				assert.same(reference_wrap.ranges(source, width), wrap.ranges(source, width))
			end
		end
	end)

	it("invalidates Unicode display settings and protects cached range records", function()
		local source = "a\tb ··界"
		for _, value in ipairs({ 2, 8 }) do
			vim.bo.tabstop = value
			assert.same(reference_wrap.ranges(source, 8), wrap.ranges(source, 8))
		end
		vim.bo.vartabstop = "3,5"
		assert.same(reference_wrap.ranges(source, 8), wrap.ranges(source, 8))
		vim.o.ambiwidth = "double"
		assert.same(reference_wrap.ranges(source, 8), wrap.ranges(source, 8))
		vim.o.emoji = false
		assert.same(reference_wrap.ranges("🙂··", 3), wrap.ranges("🙂··", 3))
		vim.fn.setcellwidths({ { 0x754c, 0x754c, 1 } })
		assert.same(reference_wrap.ranges(source, 8), wrap.ranges(source, 8))
		local expected = reference_wrap.ranges("immutable ranges", 7)
		local ranges = wrap.ranges("immutable ranges", 7)
		ranges[1].text, ranges[1].byte_end = "changed", 100
		ranges[2] = nil
		assert.same(expected, wrap.ranges("immutable ranges", 7))
	end)
end)
