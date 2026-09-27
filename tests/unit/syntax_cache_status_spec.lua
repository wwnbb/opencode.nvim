local syntax = require("opencode.ui.syntax")
local render_state = require("opencode.ui.chat.render_state")
local render = require("opencode.ui.chat.render")
local app = require("opencode.state")

describe("syntax result status and source caching", function()
	local saved, config
	local source = "local value = 1\nreturn value"
	local block = { open_line = 0 }

	before_each(function()
		config = vim.deepcopy(require("opencode.config").defaults)
		saved = { config = app.get_config, highlight = syntax.highlight_text,
			parser = vim.treesitter.get_string_parser, query = vim.treesitter.query.get,
			add = vim.treesitter.language.add }
		app.get_config = function() return config end
		render_state.clear_code_cache()
	end)

	after_each(function()
		app.get_config, syntax.highlight_text = saved.config, saved.highlight
		vim.treesitter.get_string_parser, vim.treesitter.query.get = saved.parser, saved.query
		vim.treesitter.language.add = saved.add
		vim.treesitter.query.set("lua", "highlights", nil)
		render_state.clear_code_cache()
	end)

	local function result_status(text, lang, opts)
		local captures, status = syntax.highlight_text(text, lang or "lua", opts or { min_bytes = 0 })
		return status, captures
	end

	it("distinguishes intentional skips from a successful empty capture set", function()
		assert.equals("skipped", result_status(""))
		assert.equals("skipped", result_status(source, "plaintext"))
		assert.equals("skipped", result_status(source, "lua", { min_bytes = 100 }))
		assert.equals("skipped", result_status(source, "lua", { max_bytes = 2 }))
		assert.equals("skipped", result_status(source, "lua", { max_lines = 1 }))
		config.syntax.tools = false
		assert.equals("skipped", result_status(source))
		config.syntax.tools = true
		vim.treesitter.query.set("lua", "highlights", '(number) @number')
		local status, captures = result_status("local identifier")
		assert.equals("ok", status)
		assert.same({}, captures)
		local success, highlights = result_status(source)
		assert.equals("ok", success)
		assert.is_true(#highlights > 0)
	end)

	it("retries unavailable parsers and queries including explicit parser rejection", function()
		vim.treesitter.language.add = function() return false end
		assert.equals("retry", result_status(source))
		vim.treesitter.language.add = function() error("missing parser") end
		assert.equals("retry", result_status(source))
		vim.treesitter.language.add = saved.add
		vim.treesitter.query.get = function() return nil end
		assert.equals("retry", result_status(source))
		vim.treesitter.query.get = function() error("query unavailable") end
		assert.equals("retry", result_status(source))
	end)

	it("does not mistake failed or absent parse trees and capture failures for empty success", function()
		for _, parser in ipairs({
			function() error("parser creation") end,
			function() return { parse = function() error("parse failure") end } end,
			function() return { parse = function() return {} end } end,
			function() return { parse = function() return { { root = function() return nil end } } end } end,
			function() return { parse = function() return { { root = function() error("root failure") end } } end } end,
		}) do
			vim.treesitter.get_string_parser = parser
			assert.equals("retry", result_status(source))
		end
		vim.treesitter.get_string_parser = saved.parser
		vim.treesitter.query.get = function()
			return { captures = {}, iter_captures = function() error("capture failure") end }
		end
		assert.equals("retry", result_status(source))
	end)

	it("caches valid empty results and configured skips without repeating highlight work", function()
		local calls = 0
		syntax.highlight_text = function(...)
			calls = calls + 1
			return saved.highlight(...)
		end
		local highlight = render_state.code_highlighter("empty-and-skipped")
		vim.treesitter.query.set("lua", "highlights", '(number) @number')
		for _ = 1, 3 do
			local captures, status = highlight("local identifier", "lua", { min_bytes = 0 }, block)
			assert.same({}, captures)
			assert.equals("ok", status)
		end
		assert.equals(1, calls)
		config.syntax.max_bytes = 2
		for _ = 1, 3 do
			local captures, status = highlight(source, "lua", { min_bytes = 0 }, block)
			assert.same({}, captures)
			assert.equals("skipped", status)
		end
		assert.equals(2, calls)
		assert.equals(1, render_state.code_cache_stats().entries)
	end)

	it("refreshes persistent callbacks for priority, limits, scope, language aliases and theme", function()
		local calls = 0
		syntax.highlight_text = function(...)
			calls = calls + 1
			return saved.highlight(...)
		end
		local highlight = render_state.code_highlighter("dependencies")
		local opts = { scope = "tools", min_bytes = 0, priority = 200 }
		config.syntax.languages.example = "lua"
		local first = highlight(source, "example", opts, block)
		highlight(source, "example", opts, block)
		assert.equals(1, calls)
		opts.priority = 300
		local changed = highlight(source, "example", opts, block)
		assert.equals(100, changed[1].priority - first[1].priority)
		opts.max_bytes = 2
		assert.equals("skipped", select(2, highlight(source, "example", opts, block)))
		opts.max_bytes = nil
		opts.scope = "assistant_markdown"
		highlight(source, "example", opts, block)
		config.syntax.languages.example = "missing_opencode_parser"
		assert.equals("retry", select(2, highlight(source, "example", opts, block)))
		config.syntax.languages.example = "lua"
		highlight(source, "example", opts, block)
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		highlight(source, "example", opts, block)
		assert.equals(7, calls)
	end)

	it("keeps legacy empty callbacks retryable but propagates explicit success and skips", function()
		local calls, status = 0, nil
		syntax.highlight_text = function()
			calls = calls + 1
			return {}, status
		end
		local highlight = render_state.code_highlighter("legacy")
		highlight(source, "lua", {}, block)
		highlight(source, "lua", {}, block)
		assert.equals(2, calls)
		status = "ok"
		highlight(source, "lua", {}, block)
		highlight(source, "lua", {}, block)
		assert.equals(3, calls)
		for _, value in ipairs({ "legacy", "ok", "skipped", "retry" }) do
			local opts = { highlight_code = function() return {}, value ~= "legacy" and value or nil end }
			local _, retry = syntax.highlight_markdown_fenced_blocks("```lua\nreturn 1\n```", opts)
			assert.equals(value == "legacy" or value == "retry", retry)
			local rendered = render.render_content("```lua\nreturn 1\n```", opts)
			assert.equals(retry, rendered._opencode_syntax_retry)
		end
	end)

	it("propagates retry through offset helpers and raw tool panels", function()
		syntax.highlight_text = function() return {}, "retry" end
		local output = { highlights = {} }
		syntax.add_highlights(output, source, "lua")
		assert.is_true(output._opencode_syntax_retry)
		output = { highlights = {} }
		syntax.add_markdown_highlights(output, "```lua\nreturn 1\n```", {})
		assert.is_true(output._opencode_syntax_retry)
		local panels = require("opencode.ui.chat.tool_panel")
		local panel = panels.create_panel()
		output = panel.result()
		panels.add_raw_body(output, source, { panel = panel, prefix = panels.PANEL_PREFIX, language = "lua" })
		assert.is_true(output._opencode_syntax_retry)
	end)
end)
