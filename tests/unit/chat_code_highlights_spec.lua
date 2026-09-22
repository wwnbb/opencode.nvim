local syntax = require("opencode.ui.syntax")
local render = require("opencode.ui.chat.render")
local render_state = require("opencode.ui.chat.render_state")
local state = require("opencode.state")
local view = require("opencode.ui.chat.state").state
local defaults = require("opencode.config").defaults

describe("chat code highlighting", function()
	local config, original_highlight, bufnr, winid, old_buf, old_win
	before_each(function()
		config, original_highlight = state.get_config(), syntax.highlight_text
		state.set_config(vim.deepcopy(defaults))
		render_state.clear_code_cache()
		old_buf, old_win = view.bufnr, view.winid
		vim.o.columns = 160
		bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, false, { relative = "editor", row = 0, col = 0, width = 120, height = 10 })
		view.bufnr, view.winid = bufnr, winid
		assert.is_true(pcall(vim.treesitter.language.add, "lua"), "Lua parser is required for these tests")
		assert.is_not_nil(vim.treesitter.query.get("lua", "highlights"))
	end)
	after_each(function()
		syntax.highlight_text = original_highlight
		render_state.clear_code_cache()
		state.set_config(config)
		view.bufnr, view.winid = old_buf, old_win
		vim.api.nvim_win_close(winid, true)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)

	local function highlighted_text(lines, group)
		local fragments = {}
		for _, hl in ipairs(lines._opencode_highlights or {}) do
			if not group or hl.hl_group:find(group, 1, true) then
				fragments[#fragments + 1] = lines[hl.line + 1]:content():sub(hl.col_start + 1, hl.col_end)
			end
		end
		return table.concat(fragments, "|")
	end

	it("highlights short open blocks and deindents fences in source coordinates", function()
		local lines = render.render_content("  ```lua\r\n  return 1")
		assert.is_true(highlighted_text(lines, "@keyword"):find("return", 1, true) ~= nil)
		assert.is_false(lines._opencode_plain_append)
		assert.equals("  return 1", lines[2]:content())
	end)

	it("maps user code through wrapping and truncation without highlighting the placeholder", function()
		local source = "@example.lua\n```lua\n--[[\nhidden one\nhidden two\nhidden three\nhidden four\nhidden five\nПривет 世界 😀 comment\n]]\nreturn 1\n```"
		for _, width in ipairs({ 40, 80, 120 }) do
			vim.api.nvim_win_set_config(winid, { width = width })
			local lines = render.render_user_message(source, "build", nil, { max_lines = 10 })
			assert.is_true(highlighted_text(lines, "@keyword"):find("return", 1, true) ~= nil)
			assert.is_true(highlighted_text(lines, "@comment"):find("]]", 1, true) ~= nil)
			for _, hl in ipairs(lines._opencode_highlights) do
				assert.is_true(hl.col_start >= #"┃  ")
				assert.is_nil(lines[hl.line + 1]:content():find("lines hidden", 1, true))
			end
			local wrapped = render.render_user_message("```lua\n\tlocal value = \"Привет 世界 😀 " .. string.rep("long ", 24) .. "\"\n```", "build")
			assert.is_true(highlighted_text(wrapped, "@keyword"):find("local", 1, true) ~= nil)
			assert.is_true(highlighted_text(wrapped, "@string"):find("Привет", 1, true) ~= nil)
		end
	end)

	it("honors role switches, legacy switch and per-block limits", function()
		local source = "```lua\nreturn 1\n```"
		local cfg = vim.deepcopy(defaults)
		for _, disable in ipairs({ "user_markdown", "enabled" }) do
			cfg.syntax[disable] = false; state.set_config(cfg)
			assert.same({}, render.render_user_message(source)._opencode_highlights)
			cfg.syntax[disable] = true
		end
		cfg.markdown.enable_code_highlight = false; state.set_config(cfg)
		assert.same({}, render.render_content(source)._opencode_highlights)
		assert.same({}, render.render_user_message(source)._opencode_highlights)
		cfg.markdown.enable_code_highlight = true
		cfg.syntax.max_lines = 1; state.set_config(cfg)
		assert.is_true(#render.render_content(source .. "\n" .. source)._opencode_highlights > 0)
		assert.same({}, render.render_content("```lua\nreturn 1\nreturn 2")._opencode_highlights)
		cfg.syntax.max_bytes = 3; state.set_config(cfg)
		assert.same({}, render.render_content(source)._opencode_highlights)
		assert.same({}, render.render_content("```missing_parser\nreturn 1")._opencode_highlights)
	end)

	it("reuses unchanged source across resize and only reparses the growing block", function()
		local calls = 0
		syntax.highlight_text = function(...)
			calls = calls + 1
			return original_highlight(...)
		end
		local function draw(tail)
			return render.render_content("```lua\nreturn 1\n```\n```lua\n" .. tail, {
				highlight_code = render_state.code_highlighter("session/message/part"),
			})
		end
		draw("local n = 1"); assert.equals(2, calls)
		vim.api.nvim_win_set_config(winid, { width = 40 })
		render_state.clear_render_cache()
		draw("local n = 1"); assert.equals(2, calls)
		draw("local n = 12"); assert.equals(3, calls)
		assert.equals(2, render_state.code_cache_stats().entries)
		vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "default" })
		draw("local n = 12"); assert.equals(5, calls)
	end)

	it("bounds cache entries and retained bytes and retries unavailable highlights", function()
		syntax.highlight_text = function(text)
			return text == "missing" and {} or { { line = 0, col_start = 0, end_col = 1, hl_group = "String" } }
		end
		for i = 1, 150 do
			render_state.code_highlighter(tostring(i))(string.rep("a", 70000), "lua", {}, { open_line = 0 })
		end
		local stats = render_state.code_cache_stats()
		assert.is_true(stats.bytes <= stats.max_bytes)
		assert.is_true(stats.entries <= stats.max_entries)
		render_state.clear_code_cache()
		local highlighter = render_state.code_highlighter("test")
		highlighter("missing", "lua", {}, { open_line = 0 })
		assert.equals(0, render_state.code_cache_stats().entries)
		for i = 1, 100 do highlighter(tostring(i), "lua", {}, { open_line = 0 }) end
		assert.equals(1, render_state.code_cache_stats().entries)
	end)

	it("does not hide newly available syntax behind the rendered-line cache", function()
		local context = require("opencode.ui.chat.render_context").new()
		render_state.clear_render_cache()
		local available = false
		local function build()
			return render.render_content("```lua\nreturn 1", { highlight_code = function(...)
				return available and original_highlight(...) or {}
			end })
		end
		assert.equals(0, #context:cached_nui_lines("recover-parser", build)._opencode_highlights)
		available = true
		assert.is_true(#context:cached_nui_lines("recover-parser", build)._opencode_highlights > 0)
	end)

	it("preserves query offset directives in the streamed capture path", function()
		vim.treesitter.query.set("lua", "highlights", "((identifier) @variable (#offset! @variable 0 1 0 -1))")
		local ok, result = pcall(syntax.highlight_text, "local name = 1", "lua", { min_bytes = 0 })
		vim.treesitter.query.set("lua", "highlights", nil)
		assert.is_true(ok, result)
		assert.equals(1, #result)
		assert.equals(7, result[1].col_start)
		assert.equals(9, result[1].end_col)
	end)
end)
