describe("/stats slash command", function()
	local slash = require("opencode.slash")
	local actions = require("opencode.actions")
	local original_get_stats, original_ui

	before_each(function()
		original_get_stats = actions.get_usage_stats
		original_ui = package.loaded["opencode.ui.stats"]
		slash.register_defaults()
	end)

	after_each(function()
		actions.get_usage_stats = original_get_stats
		package.loaded["opencode.ui.stats"] = original_ui
	end)

	it("shows the server usage report without sending a prompt", function()
		local requested, shown = 0, nil
		actions.get_usage_stats = function(callback)
			requested = requested + 1
			callback(nil, {
				range = { from = os.time({ year = 2026, month = 1, day = 1, hour = 12 }) * 1000,
					to = os.time({ year = 2026, month = 9, day = 25, hour = 12 }) * 1000 },
				sessions = 4, activeDays = 2, streak = 2,
				tokens = { input = 10, output = 5, reasoning = 2, cache = { read = 3, write = 1 } },
				activity = { { date = "2026-09-25", steps = 3 } },
			})
		end
		package.loaded["opencode.ui.stats"] = { show = function(view) shown = view end }

		assert.is_true(slash.execute(slash.parse("/stats")))
		assert.equals(1, requested)
		assert.equals(21, shown.total_tokens)
		assert.equals(4, shown.sessions)
		assert.equals(3, shown.daily["2026-09-25"])
	end)
end)
