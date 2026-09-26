describe("/btw public API session ownership", function()
	it("uses the captured session and rejects deleted owners before or after connection", function()
		local app = require("opencode")
		app.setup({ server = { auto_start = false }, lualine = { enabled = false } })
		local state = require("opencode.state")
		local lifecycle = require("opencode.lifecycle")
		local original_connect = lifecycle.ensure_connected
		local original_btw = package.loaded["opencode.btw"]
		local original_notify = vim.notify
		local queued, asked, notices = {}, {}, {}
		lifecycle.ensure_connected = function(callback) queued[#queued + 1] = callback end
		package.loaded["opencode.btw"] = {
			ask = function(session_id, question)
				asked[#asked + 1] = { session_id, question }
			end,
		}
		vim.notify = function(message) notices[#notices + 1] = message end

		local ok, err = pcall(function()
			state.set_session("ses_one", "One")
			state.set_session("ses_two", "Two")
			assert.is_true(app.ask_btw("first", "ses_one"))
			queued[1]()
			assert.same({ { "ses_one", "first" } }, asked)

			state.remove_session("ses_one")
			assert.is_false(app.ask_btw("after delete", "ses_one"))
			assert.equals(1, #queued)
			assert.matches("Session was deleted", notices[#notices], 1, true)

			state.set_session("ses_three", "Three")
			assert.is_true(app.ask_btw("while connecting", "ses_three"))
			state.remove_session("ses_three")
			queued[2]()
			assert.same({ { "ses_one", "first" } }, asked)
			assert.matches("Session was deleted", notices[#notices], 1, true)
		end)

		lifecycle.ensure_connected = original_connect
		package.loaded["opencode.btw"] = original_btw
		vim.notify = original_notify
		if not ok then error(err) end
	end)
end)
