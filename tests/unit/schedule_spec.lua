local schedule = require("opencode.util.schedule")

describe("scheduled callbacks", function()
	local notify
	before_each(function() notify = vim.notify end)
	after_each(function() vim.notify = notify end)

	it("preserves argument count including middle and trailing nil values", function()
		local received
		schedule.schedule_callback(function(...)
			received = { n = select("#", ...), ... }
		end, "one", nil, "three", nil)
		assert.is_true(vim.wait(500, function() return received ~= nil end, 10))
		assert.same({ n = 4, [1] = "one", [3] = "three" }, received)
	end)

	it("reports callback errors with their label", function()
		local notifications = {}
		vim.notify = function(message, level)
			notifications[#notifications + 1] = { message = message, level = level }
		end
		schedule.schedule_pcall("schedule test label", function() error("schedule boom") end)
		assert.is_true(vim.wait(500, function() return #notifications > 0 end, 10))
		assert.is_truthy(notifications[1].message:find("schedule test label", 1, true))
		assert.is_truthy(notifications[1].message:find("schedule boom", 1, true))
		assert.equals(vim.log.levels.ERROR, notifications[1].level)
	end)
end)
