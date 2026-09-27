local syntax = require("opencode.ui.syntax")
local render = require("opencode.ui.chat.render")
local render_state = require("opencode.ui.chat.render_state")
local context = require("opencode.ui.chat.render_context")
local app = require("opencode.state")

describe("highlight cache dependency equivalence", function()
	local previous_config, cfg, original_parser, original_query, original_get_config
	local restore_predicate
	local source = "```lua\nlocal value = 1\nreturn value\n```"

	before_each(function()
		previous_config = app.get_config()
		cfg = vim.deepcopy(require("opencode.config").defaults)
		app.set_config(cfg)
		-- The normal state accessor returns a defensive copy. Exercise the
		-- supported same-table configuration case explicitly through its reader.
		original_get_config = app.get_config
		app.get_config = function() return cfg end
		original_parser, original_query = vim.treesitter.get_string_parser, vim.treesitter.query.get
		render_state.clear_render_cache()
		render_state.clear_code_cache()
	end)

	after_each(function()
		if restore_predicate then restore_predicate(); restore_predicate = nil end
		vim.treesitter.get_string_parser, vim.treesitter.query.get = original_parser, original_query
		vim.treesitter.query.set("lua", "highlights", nil)
		app.get_config = original_get_config
		app.set_config(previous_config)
		render_state.clear_render_cache()
		render_state.clear_code_cache()
	end)

	local function cached_renderer()
		local ctx = context.new({ current_session = { id = "cache-equivalence" } })
		local highlighter = ctx:code_highlighter("message", "part")
		local builds = 0
		local function get()
			-- Each transcript frame gets a fresh context; the code callback can
			-- outlive it and must still observe current syntax dependencies.
			ctx = context.new({ current_session = { id = "cache-equivalence" } })
			return ctx:cached_nui_lines("unchanged-owner-and-revision", function()
				builds = builds + 1
				return render.render_content(source, { highlight_code = highlighter })
			end)
		end
		return get, function() return builds end
	end

	local function captures(lines)
		return lines._opencode_highlights or {}
	end

	it("caches an intentional skip and detects same-table limit mutations", function()
		cfg.syntax.max_lines = 1
		local get, builds = cached_renderer()
		assert.same({}, captures(get()))
		assert.same({}, captures(get()))
		assert.equals(1, builds())
		cfg.syntax.max_lines = 500
		assert.is_true(#captures(get()) > 0)
		assert.equals(2, builds())
		cfg.syntax.assistant_markdown = false
		assert.same({}, captures(get()))
		assert.equals(3, builds())
		cfg.syntax.assistant_markdown = true
		assert.is_true(#captures(get()) > 0)
		assert.equals(4, builds())
	end)

	it("rebuilds a successful empty query when the effective query changes", function()
		vim.treesitter.query.set("lua", "highlights", "; Intentionally no captures\n")
		local get, builds = cached_renderer()
		assert.same({}, captures(get()))
		get()
		assert.equals(1, builds())
		vim.treesitter.query.set("lua", "highlights", '"return" @keyword.return')
		local result = get()
		assert.equals(2, builds())
		assert.is_true(#captures(result) > 0)
		get()
		assert.equals(2, builds())
	end)

	it("retries missing queries on ordinary updates and recovers without an event", function()
		local available = false
		vim.treesitter.query.get = function(language, kind)
			if language == "lua" and kind == "highlights" and not available then return nil end
			return original_query(language, kind)
		end
		local get, builds = cached_renderer()
		assert.same({}, captures(get()))
		assert.same({}, captures(get()))
		assert.equals(2, builds())
		available = true
		assert.is_true(#captures(get()) > 0)
		assert.equals(3, builds())
		get()
		assert.equals(3, builds())
	end)

	it("does not retain transient code parser failures", function()
		local available = false
		vim.treesitter.get_string_parser = function(value, language, opts)
			if language == "lua" and not available then error("transient parser failure") end
			return original_parser(value, language, opts)
		end
		local get, builds = cached_renderer()
		assert.same({}, captures(get()))
		assert.same({}, captures(get()))
		assert.equals(2, builds())
		available = true
		assert.is_true(#captures(get()) > 0)
		get()
		assert.equals(3, builds())
	end)

	it("refreshes an existing callback and outer result after a theme generation", function()
		local get, builds = cached_renderer()
		local before = get()
		get()
		assert.equals(1, builds())
		local generation = syntax.get_generation()
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		assert.is_true(syntax.get_generation() > generation)
		local after = get()
		assert.equals(2, builds())
		assert.same(render.extract_lines(before), render.extract_lines(after))
		get()
		assert.equals(2, builds())
	end)

	it("invalidates warm outer results and rechecks externally stateful predicates", function()
		vim.treesitter.query.set("lua", "highlights", '((identifier) @variable (#eq? @variable "value"))')
		local query = vim.treesitter.query.get("lua", "highlights")
		local handlers
		for index = 1, 100 do
			local name, value = debug.getupvalue(query._match_predicates, index)
			if name == "predicate_handlers" then handlers = value; break end
			if not name then break end
		end
		assert.is_table(handlers)
		local original = handlers["eq?"]
		restore_predicate = function()
			vim.treesitter.query.add_predicate("eq?", original, { force = true, all = true })
		end
		local get, builds = cached_renderer()
		assert.is_true(#captures(get()) > 0)
		get()
		assert.equals(1, builds())
		local allow = false
		local direct = render_state.code_highlighter("persistent-callback")
		local function direct_captures()
			return direct("local value = 1\nreturn value", "lua", { min_bytes = 0 }, { open_line = 0 })
		end
		assert.is_true(#direct_captures() > 0)
		vim.treesitter.query.add_predicate("eq?", function() return allow end, { force = true, all = false })
		-- No new frame/context is created before this long-lived callback.
		assert.same({}, direct_captures())
		assert.same({}, captures(get()))
		assert.equals(2, builds())
		allow = true
		assert.is_true(#direct_captures() > 0)
		assert.is_true(#captures(get()) > 0)
		assert.equals(3, builds())
		allow = false
		assert.same({}, captures(get()))
		assert.equals(4, builds())
		restore_predicate()
		assert.is_true(#captures(get()) > 0)
		get()
		assert.equals(5, builds())
	end)
end)
