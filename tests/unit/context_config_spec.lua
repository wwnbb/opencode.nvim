local config = require("opencode.config")

describe("context placeholder configuration", function()
	it("defaults to 24 KiB and accepts a custom budget without changing inputs", function()
		assert.equals(24576, config.merge().context.max_bytes)
		local opts = { context = { max_bytes = 1024 } }
		local merged = config.merge(opts)
		assert.equals(1024, merged.context.max_bytes)
		merged.context.max_bytes = 4096
		assert.equals(1024, opts.context.max_bytes)
		assert.equals(24576, config.defaults.context.max_bytes)
	end)

	it("rejects malformed context settings and invalid byte budgets", function()
		assert.has_error(function() config.merge({ context = false }) end,
			"opencode.nvim: context must be a table")
		for _, value in ipairs({ false, "24576", 0, 1023, 1024.5, math.huge, 0 / 0 }) do
			assert.has_error(function() config.merge({ context = { max_bytes = value } }) end,
				"opencode.nvim: context.max_bytes must be an integer >= 1024")
		end
	end)
end)
