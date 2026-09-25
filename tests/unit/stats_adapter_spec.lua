describe("usage statistics adapter", function()
	local stats = require("opencode.stats")

	it("requests usage since January 1 of the local year", function()
		local now = os.time({ year = 2026, month = 9, day = 25, hour = 12 })
		local query = stats.query(now)
		assert.equals(os.time({ year = 2026, month = 1, day = 1, hour = 0 }) * 1000, query.from)
		assert.equals("none", query.tools)
		assert.is_string(query.timezone)
	end)

	it("sums token categories and preserves step activity for the calendar", function()
		local from = os.time({ year = 2026, month = 1, day = 1, hour = 12 }) * 1000
		local to = os.time({ year = 2026, month = 9, day = 25, hour = 12 }) * 1000
		local view = stats.from_api({
			range = { from = from, to = to },
			sessions = 74,
			activeDays = 5,
			streak = 5,
			tokens = { input = 40, output = 20, reasoning = 10, cache = { read = 8, write = 2 } },
			activity = {
				{ date = "2026-09-23", steps = 3 },
				{ date = "2026-09-23", steps = 2 },
				{ date = "2026-09-24", steps = 0 },
			},
		})

		assert.equals(80, view.total_tokens)
		assert.equals(74, view.sessions)
		assert.equals(5, view.active_days)
		assert.equals(5, view.best_streak)
		assert.equals(5, view.daily["2026-09-23"])
		assert.equals(0, view.daily["2026-09-24"])
		assert.equals("2026-01-01", view.start_date)
		assert.equals("2026-09-25", view.end_date)
	end)

	it("rejects incomplete server data instead of showing fabricated zero usage", function()
		local view, err = stats.from_api({ tokens = {} })
		assert.is_nil(view)
		assert.equals("Invalid usage statistics response", err)
	end)
end)
