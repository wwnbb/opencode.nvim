local stats = require("opencode.ui.stats")

describe("usage statistics display", function()
	it("renders token usage, activity, and session totals at narrow and wide widths", function()
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
		local narrow = table.concat(stats.render(view, 40), "\n")
		assert.is_truthy(narrow:find("opencode / stats", 1, true))
		assert.is_truthy(narrow:find("Jan - Sep 2026", 1, true))
		assert.is_truthy(narrow:find("80.4M", 1, true))
		assert.is_truthy(narrow:find("2 days  BEST STREAK", 1, true))
		assert.is_truthy(narrow:find("3  ACTIVE DAYS", 1, true))
		assert.is_truthy(narrow:find("9  SESSIONS", 1, true))

		local wide_lines = stats.render(view, 80)
		local wide = table.concat(wide_lines, "\n")
		assert.is_truthy(wide_lines[1]:find("opencode / stats", 1, true))
		assert.is_truthy(wide_lines[1]:find("Jan - Sep 2026", 1, true))
		assert.is_truthy(wide_lines[3]:find("opencode", 1, true))
		assert.is_true(wide_lines[3]:find("opencode", 1, true) > 30)
		assert.is_truthy(wide:find("BEST STREAK", 1, true))
		assert.is_truthy(wide:find("ACTIVE DAYS", 1, true))
		for _, line in ipairs(wide_lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= 80, line)
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
		assert.is_truthy(report:find("1  ACTIVE DAYS", 1, true))
	end)

	it("opens a responsive popup and closes it", function()
		local old_columns, old_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 72, 28
		local popup = stats.show({ total_tokens = 42, sessions = 1, start_date = "2026-09-01", end_date = "2026-09-25" })
		local winid = popup.winid
		assert.is_true(vim.api.nvim_win_is_valid(winid))
		assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n"):find("42", 1, true))
		vim.o.columns = 56
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.is_true(vim.api.nvim_win_get_width(winid) < 66)
		stats.close()
		assert.is_false(vim.api.nvim_win_is_valid(winid))
		local closed_outside = stats.show({ total_tokens = 1 })
		vim.api.nvim_win_close(closed_outside.winid, true)
		vim.api.nvim_exec_autocmds("VimResized", {})
		local replacement = stats.show({ total_tokens = 2 })
		assert.is_true(vim.api.nvim_win_is_valid(replacement.winid))
		stats.close()
		vim.o.columns, vim.o.lines = old_columns, old_lines
	end)
end)
