describe("thinking rendering", function()
	it("honors merged config, truncates, wraps, and uses the chat tabstop", function()
		local thinking = require("opencode.ui.thinking")
		local render = require("opencode.ui.chat.render")
		local app_state = require("opencode.state")
		local chat_state = require("opencode.ui.chat.state").state

		local previous_config = app_state.get_config()
		local previous_bufnr = chat_state.bufnr
		local previous_winid = chat_state.winid
		local winid = vim.api.nvim_get_current_win()
		local previous_win_buf = vim.api.nvim_win_get_buf(winid)
		local previous_width = vim.api.nvim_win_get_width(winid)
		local chat_bufnr = vim.api.nvim_create_buf(false, true)
		local foreign_bufnr = vim.api.nvim_create_buf(false, true)

		local function cleanup()
			app_state.set_config(previous_config)
			chat_state.bufnr = previous_bufnr
			chat_state.winid = previous_winid
			if vim.api.nvim_win_is_valid(winid) then
				vim.api.nvim_win_set_buf(winid, previous_win_buf)
				vim.api.nvim_win_set_width(winid, previous_width)
			end
			for _, bufnr in ipairs({ chat_bufnr, foreign_bufnr }) do
				if vim.api.nvim_buf_is_valid(bufnr) then
					vim.api.nvim_buf_delete(bufnr, { force = true })
				end
			end
		end

		local ok, err = xpcall(function()
			app_state.set_config({ thinking = { enabled = false } })
			assert(not thinking.is_enabled(), "thinking.enabled should come from app state")
			assert(#render.render_reasoning("hidden reasoning") == 0, "disabled thinking should not render")

			app_state.set_config({
				thinking = {
					enabled = true,
					max_height = 1,
					truncate = true,
					icon = "R>",
					highlight = "String",
					header_highlight = "ErrorMsg",
				},
			})
			-- Formatter helpers keep icon/topic/truncation behavior for non-chat callers.
			local formatted = thinking.format_reasoning(
				"**Plan**\nthis is a deliberately long reasoning line that must wrap\nsecond line"
			)
			assert(formatted[1] == "R> Plan", "custom thinking icon/topic was not formatted")
			assert(formatted[#formatted - 1] == "...", "thinking content should be truncated")
			local formatted_highlights = thinking.get_highlights(0, #formatted)
			assert(formatted_highlights[1].hl_group == "ErrorMsg", "custom header highlight was not applied")
			assert(formatted_highlights[2].hl_group == "String", "custom content highlight was not applied")

			vim.api.nvim_win_set_buf(winid, foreign_bufnr)
			vim.api.nvim_win_set_width(winid, 24)
			chat_state.bufnr = chat_bufnr
			chat_state.winid = winid
			vim.bo[chat_bufnr].tabstop = 2
			vim.bo[foreign_bufnr].tabstop = 8

			-- Chat thoughts are collapsed by default, independently of the legacy formatter.
			local rendered = render.render_reasoning("**Plan**\n\nthis is a deliberately long reasoning line that must wrap\nsecond line", {
				time = { created = 100, completed = 316 },
			})
			local rendered_lines = render.extract_lines(rendered)
			assert(vim.trim(rendered_lines[1]) == "+ Thought: Plan · 216ms", "collapsed thought should show topic and duration")
			assert(#rendered_lines == 2, "collapsed thought should hide its body")
			local expanded = render.render_reasoning("a deliberately long reasoning line that must wrap\nsecond line", { expanded = true })
			local expanded_lines = render.extract_lines(expanded)
			assert(vim.trim(expanded_lines[1]) == "- Thought", "expanded thought should use the minus marker")
			assert(expanded_lines[3]:find("▏  ", 1, true) == 1, "expanded reasoning needs a left border")
			assert(table.concat(expanded_lines, "\n"):find("second line", 1, true), "expanded thought must not truncate content")

			local chat_tabbed = render.wrap_text_with_ranges("a\tb", 4)
			assert(#chat_tabbed == 1, "wrapping should use the chat buffer tabstop, not the current buffer")
			local panel = require("opencode.ui.panel").create_helpers({ prefix = "▏  " })
			vim.bo[chat_bufnr].tabstop = 8
			vim.bo[foreign_bufnr].tabstop = 2
			local panel_prefix = "▏  "
			local function assert_panel_rows(rows, label)
				assert(#rows > 1, label .. " should wrap")
				for _, row in ipairs(rows) do
					assert(row.line:sub(1, #panel_prefix) == panel_prefix, label .. " lost its panel prefix")
					local row_width
					vim.api.nvim_buf_call(chat_bufnr, function()
						row_width = vim.fn.strdisplaywidth(row.line)
					end)
					assert(row_width <= render.get_chat_text_width(), label .. " row should fit the chat buffer width")
				end
			end
			local tabbed_line = "Testing:\t/Users/admin/work/lua/opencode.nvim/tests/unit/transport_spec.lua"
			local panel_result = { lines = {}, highlights = {} }
			local _, _, panel_rows = panel.add_line(panel_result, tabbed_line, nil, { width = render.get_chat_text_width() })
			assert_panel_rows(panel_rows, "add_line tabbed output")

			local raw_result = { lines = {}, highlights = {} }
			local _, _, raw_rows = panel.add_raw_line(raw_result, tabbed_line, nil, {
				width = render.get_chat_text_width(),
				body_prefix = "$ ",
			})
			assert_panel_rows(raw_rows, "add_raw_line tabbed output")

			local large_result = { lines = {}, highlights = {} }
			local _, _, large_rows = panel.add_raw_line(large_result, string.rep("x", 4096), nil, {
				width = render.get_chat_text_width(),
			})
			assert(#large_rows > 1, "large panel output should produce wrapped rows")
			for _, row in ipairs(large_rows) do
				assert(row.line:sub(1, #panel_prefix) == panel_prefix, "large output lost its panel prefix")
			end

			local initial_col_chunks = render.wrap_text_with_ranges("\tX", 5, { initial_col = 3 })
			assert(#initial_col_chunks == 2, "tab width should honor the supplied initial column")
			assert(initial_col_chunks[1].byte_end == 1 and initial_col_chunks[2].byte_start == 1, "tab byte ranges changed")
			local unicode_chunks = render.wrap_text_with_ranges("a界éb", 3)
			assert(unicode_chunks[1].text == "a界", "wide Unicode characters should retain their display width")
			assert(unicode_chunks[2].text == "éb", "combining characters should retain their byte range")

			vim.bo[chat_bufnr].tabstop = 2
			vim.bo[foreign_bufnr].tabstop = 8
			chat_state.bufnr = nil
			local fallback_tabbed = render.wrap_text_with_ranges("a\tb", 4)
			assert(#fallback_tabbed > 1, "tabstop lookup should have a safe current-buffer fallback")

			app_state.set_config({ thinking = { truncate = false, max_height = 1 } })
			local not_truncated = thinking.format_reasoning("one\ntwo")
			for _, line in ipairs(not_truncated) do
				assert(line ~= "...", "truncate=false should omit the truncation marker")
			end
		end, debug.traceback)

		cleanup()
		if not ok then
			error(err, 0)
		end
	end)
end)
