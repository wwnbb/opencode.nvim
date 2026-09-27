local calendar = require("opencode.ui.stats_calendar")

local function marks_in_group(marks, group)
	local selected = {}
	for _, mark in ipairs(marks) do
		if mark.group == group then selected[#selected + 1] = mark end
	end
	return selected
end

describe("TUI usage activity calendar", function()
	it("starts weeks on Monday and leaves dates outside the range empty", function()
		local lines, marks = calendar.render({
			start_date = "2026-01-01", -- Thursday
			end_date = "2026-01-11", -- Sunday
			daily = {
				["2026-01-01"] = 1,
				["2026-01-05"] = 2,
				["2026-01-06"] = 3,
				["2026-01-11"] = 4,
			},
		}, 30)
		local indent = 11 -- two weeks occupy eight of the thirty columns
		assert.equals(8, #lines)
		assert.equals("Jan", lines[1]:sub(indent + 5, indent + 7))
		assert.equals("M", lines[2]:sub(indent + 1, indent + 1))
		assert.equals("T", lines[5]:sub(indent + 1, indent + 1))
		assert.equals(1, #marks_in_group(marks, "OpenCodeStatsLevel1"))
		assert.equals(1, #marks_in_group(marks, "OpenCodeStatsLevel2"))
		assert.equals(1, #marks_in_group(marks, "OpenCodeStatsLevel3"))
		assert.equals(1, #marks_in_group(marks, "OpenCodeStatsLevel4"))
		local first = marks_in_group(marks, "OpenCodeStatsLevel1")[1]
		assert.equals(4, first.line) -- Thursday is the fifth rendered line
		assert.equals(indent + 4, first.col)
		local second = marks_in_group(marks, "OpenCodeStatsLevel2")[1]
		assert.equals(1, second.line) -- Monday of the next week
		assert.equals(indent + 6, second.col)
		assert.equals(7, #marks_in_group(marks, "OpenCodeStatsInactive"))
	end)

	it("places month labels at the week whose Thursday enters the next month", function()
		local lines = calendar.render({ start_date = "2026-01-01", end_date = "2026-02-15" }, 40)
		local indent = math.floor((40 - (4 + 7 * 2)) / 2)
		assert.equals("Jan", lines[1]:sub(indent + 5, indent + 7))
		assert.equals("Feb", lines[1]:sub(indent + 15, indent + 17))
		-- In 2024, Thursday February 1 belongs to the January 29 week.
		-- Wednesday would place February a full week too late.
		local boundary = calendar.render({ start_date = "2024-01-01", end_date = "2024-02-18" }, 40)
		assert.equals("Jan", boundary[1]:sub(indent + 5, indent + 7))
		assert.equals("Feb", boundary[1]:sub(indent + 13, indent + 15))
	end)

	it("handles leap days and ranks distinct positive step counts like the TUI", function()
		local lines, marks = calendar.render({
			start_date = "2024-02-21",
			end_date = "2024-03-15",
			daily = {
				["2024-02-29"] = 7,
				["2024-03-01"] = 7,
				["2024-03-04"] = 30,
			},
		}, 30)
		assert.is_truthy(lines[1]:find("Feb", 1, true))
		assert.is_truthy(lines[1]:find("Mar", 1, true))
		assert.equals(2, #marks_in_group(marks, "OpenCodeStatsLevel2"))
		assert.equals(1, #marks_in_group(marks, "OpenCodeStatsLevel4"))
		assert.equals(0, #marks_in_group(marks, "OpenCodeStatsLevel1"))
	end)

	it("clips old weeks and keeps display widths and UTF-8 extmark byte columns valid", function()
		local lines, marks = calendar.render({
			start_date = "2026-01-01",
			end_date = "2026-09-25",
			daily = { ["2026-09-24"] = 1 },
		}, 24)
		assert.equals(9, #lines)
		assert.is_truthy(lines[9]:find("Your last 10 weeks", 1, true))
		for _, line in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= 24, line)
		end
		for _, mark in ipairs(marks) do
			assert.is_true(mark.line >= 0 and mark.line < #lines)
			assert.is_true(mark.col >= 0 and mark.end_col <= #lines[mark.line + 1])
			assert.is_true(mark.end_col > mark.col)
		end
		local active = marks_in_group(marks, "OpenCodeStatsLevel4")[1]
		assert.equals("■", lines[active.line + 1]:sub(active.col + 1, active.end_col))
	end)
end)
