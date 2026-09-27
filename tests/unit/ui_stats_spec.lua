local stats = require("opencode.ui.stats")

describe("usage statistics display", function()
	it("matches the TUI wordmark, token art, labels, and footer", function()
		local view = {
			total_tokens = 80400000,
			sessions = 9,
			start_date = "2026-01-01",
			end_date = "2026-09-25",
			daily = {
				["2026-09-22"] = 2,
				["2026-09-23"] = 7,
				["2026-09-25"] = 1,
			},
		}
		local narrow = table.concat(stats.render(view, 20), "\n")
		assert.is_truthy(narrow:find("opencode / stats", 1, true))
		assert.is_truthy(narrow:find("Jan – Sep 2026", 1, true))
		assert.is_truthy(narrow:find("80.4M", 1, true))
		local stacked = stats.render(view, 43)
		assert.is_truthy(stacked[1]:find("opencode / stats", 1, true))
		assert.is_truthy(stacked[2]:find("Jan – Sep 2026", 1, true))

		local wide_lines = stats.render(view, 110)
		local wide = table.concat(wide_lines, "\n")
		assert.is_truthy(wide_lines[1]:find("opencode / stats", 1, true))
		assert.is_truthy(wide_lines[1]:find("Jan – Sep 2026", 1, true))

		local logo_row
		for index, line in ipairs(wide_lines) do
			if line:find("█▀▀█ █▀▀█ █▀▀█ █▀▀▄", 1, true) then
				logo_row = index
				assert.is_truthy(line:find("█▀▀▀ █▀▀█ █▀▀█ █▀▀█", 1, true))
				break
			end
		end
		assert.is_truthy(logo_row, "the TUI's block wordmark is missing")
		assert.is_truthy(wide_lines[logo_row + 1]:find("█▀▀▀", 1, true))
		assert.is_truthy(wide_lines[logo_row + 2]:find("▀▀▀▀ █▀▀▀ ▀▀▀▀", 1, true))

		local numeral = {
			"██████  ██████      ██  ██  ██      ██",
			"██  ██  ██  ██      ██  ██  ████  ████",
			"██████  ██  ██      ██████  ██  ██  ██",
			"██  ██  ██  ██          ██  ██      ██",
			"██████  ██████  ██      ██  ██      ██",
		}
		local number_row
		for index, line in ipairs(wide_lines) do
			if line:find(numeral[1], 1, true) then
				number_row = index
				break
			end
		end
		assert.is_truthy(number_row, "the TUI's five-row token numeral is missing")
		assert.equals(5, number_row - logo_row)
		for index, expected in ipairs(numeral) do
			assert.is_truthy(wide_lines[number_row + index - 1]:find(expected, 1, true))
		end
		assert.equals("", wide_lines[number_row + 5])
		assert.is_truthy(wide_lines[number_row + 6]:find("TOKENS", 1, true))

		local summary_row
		for index, line in ipairs(wide_lines) do
			if line:find("best streak", 1, true) and line:find("active days", 1, true)
				and line:find("sessions", 1, true) then
				summary_row = index
				break
			end
		end
		assert.is_truthy(summary_row, "the three lowercase summary labels are missing")
		assert.is_truthy(wide_lines[summary_row - 1]:match("2 days%s+3%s+9%s*$"))
		assert.is_nil(wide:find("BEST STREAK", 1, true))
		assert.is_nil(wide:lower():find("close", 1, true))
		assert.is_nil(wide:find("Esc", 1, true))
		assert.is_truthy(wide_lines[#wide_lines]:find("opencode.ai", 1, true))
		assert.equals(110, vim.fn.strdisplaywidth(wide_lines[#wide_lines]))
		for _, line in ipairs(wide_lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= 110, line)
		end
	end)

	it("marks zero activity separately from days with steps", function()
		local lines, marks = stats.render({
			end_date = "2026-09-25",
			daily = { ["2026-09-24"] = 8, ["2026-09-25"] = 0 },
		}, 36)
		local groups = {}
		for _, mark in ipairs(marks) do
			assert.is_true(mark.end_col <= #lines[mark.line + 1])
			groups[mark.group] = true
		end
		assert.is_true(groups.OpenCodeStatsInactive)
		assert.is_true(groups.OpenCodeStatsLevel4)
		local report = table.concat(lines, "\n")
		assert.is_truthy(report:find("active days", 1, true))
		assert.is_truthy(report:find("1 days", 1, true))
	end)

	it("covers the editor grid without a border, resizes, and restores focus", function()
		local old_columns, old_lines = vim.o.columns, vim.o.lines
		local previous_winid = vim.api.nvim_get_current_win()
		local previous_bufnr = vim.api.nvim_get_current_buf()
		vim.o.columns, vim.o.lines = 72, 28
		local screen = stats.show({ total_tokens = 42, sessions = 1, start_date = "2026-09-01", end_date = "2026-09-25" })
		local winid = screen.winid
		local function assert_full_screen(target_winid)
			local config = vim.api.nvim_win_get_config(target_winid)
			assert.equals("editor", config.relative)
			assert.equals(0, config.row)
			assert.equals(0, config.col)
			assert.equals("none", config.border)
			assert.is_nil(config.title)
			assert.equals(vim.o.columns, vim.api.nvim_win_get_width(target_winid))
			assert.equals(vim.o.lines - vim.o.cmdheight, vim.api.nvim_win_get_height(target_winid))
		end
		assert.is_true(vim.api.nvim_win_is_valid(winid))
		assert.equals(winid, vim.api.nvim_get_current_win())
		assert_full_screen(winid)
		local screen_lines = table.concat(vim.api.nvim_buf_get_lines(screen.bufnr, 0, -1, false), "\n")
		assert.is_truthy(screen_lines:find("opencode.ai", 1, true))
		assert.is_nil(screen_lines:lower():find("close", 1, true))
		vim.o.columns, vim.o.lines = 56, 20
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert_full_screen(winid)
		for _, line in ipairs(vim.api.nvim_buf_get_lines(screen.bufnr, 0, -1, false)) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= vim.o.columns, line)
		end
		stats.close()
		assert.is_false(vim.api.nvim_win_is_valid(winid))
		assert.equals(previous_winid, vim.api.nvim_get_current_win())
		assert.equals(previous_bufnr, vim.api.nvim_get_current_buf())
		local closed_outside = stats.show({ total_tokens = 1 })
		vim.api.nvim_win_close(closed_outside.winid, true)
		vim.api.nvim_exec_autocmds("VimResized", {})
		local replacement = stats.show({ total_tokens = 2 })
		local replacement_winid = replacement.winid
		assert.is_true(vim.api.nvim_win_is_valid(replacement_winid))
		assert_full_screen(replacement_winid)
		vim.api.nvim_feedkeys("q", "xt", false)
		assert.is_false(vim.api.nvim_win_is_valid(replacement_winid))
		local escape_screen = stats.show({ total_tokens = 3 })
		local escape_winid = escape_screen.winid
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
		assert.is_false(vim.api.nvim_win_is_valid(escape_winid))
		assert.equals(previous_winid, vim.api.nvim_get_current_win())
		vim.o.columns, vim.o.lines = old_columns, old_lines
	end)
end)
