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
			local config = thinking.get_config()
			assert(config.throttle_ms == 100, "thinking config should retain default fields")

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

			local wrapped = render.render_reasoning(
				"**Plan**\nthis is a deliberately long reasoning line that must wrap\nsecond line"
			)
			local wrapped_lines = render.extract_lines(wrapped)
			assert(#wrapped_lines > #formatted, "reasoning should wrap to the chat width")
			assert(table.concat(wrapped_lines, "\n"):find("R> Plan", 1, true), "wrapped reasoning lost its custom header")
			for _, line in ipairs(wrapped_lines) do
				assert(
					vim.fn.strdisplaywidth(line) <= render.get_chat_text_width(),
					"reasoning line exceeded the chat display width"
				)
			end

			local chat_tabbed = render.wrap_text_with_ranges("a\tb", 4)
			assert(#chat_tabbed == 1, "wrapping should use the chat buffer tabstop, not the current buffer")
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
