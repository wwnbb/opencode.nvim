describe("opencode public initialization", function()
	local state = require("opencode.state")
	local app, saved_app, original_require, original_notify, notices

	before_each(function()
		saved_app, original_require, original_notify = package.loaded["opencode"], require, vim.notify
		package.loaded["opencode"] = nil
		app = require("opencode")
		state.reset()
		notices = {}
		vim.notify = function(message) notices[#notices + 1] = message end
	end)

	after_each(function()
		_G.require, vim.notify = original_require, original_notify
		package.loaded["opencode"] = saved_app
		state.reset()
	end)

	it("reports connection state after setup and false before setup", function()
		state.set_connection("connected")
		assert.is_false(app.is_connected())
		app.setup({ server = { auto_start = false }, lualine = { enabled = false } })
		for _, connection in ipairs({ "idle", "connecting", "connected", "error" }) do
			state.set_connection(connection)
			assert.equals(connection == "connected", app.is_connected())
		end
	end)

	it("keeps public actions guarded after lifecycle loading fails", function()
		_G.require = function(name)
			if name == "opencode.lifecycle" then error("simulated lifecycle load failure") end
			return original_require(name)
		end
		app.setup({ server = { auto_start = false }, lualine = { enabled = false } })
		_G.require = original_require
		assert.matches("Failed to load opencode lifecycle:", notices[#notices], 1, true)
		assert.is_false(app.is_connected())
		assert.is_nil(app.open())
		assert.is_false(app.start())
		assert.equals("OpenCode not initialized", notices[#notices])
	end)
end)
