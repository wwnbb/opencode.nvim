describe("input catalog sync", function()
	local input = require("opencode.ui.input")
	local events = require("opencode.events")
	local client = require("opencode.client")
	local saved, replies
	local catalogs = {
		get_config_providers = {
			providers = { { id = "p", name = "Provider", models = { m = { name = "Model" } } } },
			default = { p = "m" },
		},
		list_agents = { { id = "build", name = "Build" } },
		list_commands = {}, list_skills = {}, get_mcp_status = {}, get_config = {},
	}

	local function flush_scheduled()
		local done = false
		vim.schedule(function() done = true end)
		assert.is_true(vim.wait(500, function() return done end, 5))
	end

	before_each(function()
		saved, replies = {}, {}
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false } })
		require("opencode.sync").clear_all()
		for method in pairs(catalogs) do
			saved[method] = client[method]
			client[method] = function(callback) replies[method] = callback end
		end
	end)

	after_each(function()
		input.close(false)
		require("opencode.cleanup").reset_all()
		flush_scheduled()
		for method, original in pairs(saved) do client[method] = original end
	end)

	it("updates the open info bar once for a burst of catalog responses", function()
		events.emit("connected")
		input.show({ text = "Draft survives catalog loading" })
		flush_scheduled()
		local focus = vim.api.nvim_get_current_win()
		local info_buf = vim.api.nvim_win_get_buf(input.get_winids()[2])
		local before = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)[1]
		local updates = 0
		assert.is_true(vim.api.nvim_buf_attach(info_buf, false, {
			on_lines = function() updates = updates + 1 end,
		}))

		for method, data in pairs(catalogs) do replies[method](nil, data) end
		flush_scheduled()

		local after = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)[1]
		assert.not_equals(before, after)
		assert.is_truthy(after:find("Build Model Provider", 1, true), after)
		assert.equals(1, updates)
		assert.equals(focus, vim.api.nvim_get_current_win())
		assert.same({ "Draft survives catalog loading" },
			vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(focus), 0, -1, false))
	end)
end)
