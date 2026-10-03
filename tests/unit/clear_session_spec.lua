describe("/clear session context", function()
	it("starts a fresh server session and keeps the previous conversation available", function()
		local app = require("opencode")
		app.setup({ server = { auto_start = false }, lualine = { enabled = false } })

		local state = require("opencode.state")
		local sync = require("opencode.sync")
		local input = require("opencode.ui.input")
		local slash = require("opencode.slash")
		local lifecycle = require("opencode.lifecycle")
		local client = require("opencode.client")
		local original_connect = lifecycle.ensure_connected
		local original_create = client.create_session
		local original_notify = vim.notify
		local created, fail_creation, defer_creation, create_callback, notices = 0, true, false, nil, {}

		lifecycle.ensure_connected = function(callback) callback() end
		client.create_session = function(body, callback)
			assert.same({}, body)
			created = created + 1
			if defer_creation then create_callback = callback; return end
			if fail_creation then
				callback({ message = "server unavailable" })
			else
				callback(nil, { id = "ses_fresh", title = "Fresh conversation" })
			end
		end
		vim.notify = function(message) notices[#notices + 1] = message end

		local ok, err = pcall(function()
			local clear_command = require("opencode.command_registry").get_slash("clear")
			assert.is_not_nil(clear_command)
			assert.matches("new", clear_command.description:lower(), 1, true)

			state.set_session("ses_previous", "Previous conversation")
			input.set_pending_text("previous draft")
			sync.handle_message_updated({
				id = "old_message", sessionID = "ses_previous", role = "user", time = { created = 1 },
			})

			assert.is_true(slash.execute(slash.parse("/clear")))
			assert.is_true(vim.wait(500, function() return #notices > 0 end, 10))
			assert.equals(1, created)
			assert.equals("ses_previous", state.get_session().id)
			assert.is_true(state.is_runtime_session("ses_previous"))
			assert.is_not_nil(sync.get_message("ses_previous", "old_message"))
			assert.equals("previous draft", input.get_pending_text())

			fail_creation = false
			assert.is_true(slash.execute(slash.parse("/clear")))
			assert.is_true(vim.wait(500, function() return state.get_session().id == "ses_fresh" end, 10))
			assert.equals(2, created)
			assert.is_false(state.is_runtime_session("ses_previous"))
			assert.is_true(state.is_runtime_session("ses_fresh"))
			assert.is_not_nil(state.get_session_record("ses_previous"))
			assert.same({}, sync.get_messages("ses_fresh"))
			assert.equals("", input.get_pending_text())
			assert.equals("", require("opencode.ui.input.history").get_pending("ses_previous"))

			defer_creation = true
			input.set_pending_text("draft before clear")
			assert.is_true(slash.execute(slash.parse("/clear")))
			assert.is_not_nil(create_callback)
			input.set_pending_text("new draft during creation")
			require("opencode.ui.input.history").set_pending_parts({ { type = "file", name = "new.png" } })
			create_callback(nil, { id = "ses_next", title = "Next conversation" })
			assert.is_true(vim.wait(500, function() return state.get_session().id == "ses_next" end, 10))
			assert.equals("", input.get_pending_text())
			assert.equals("new draft during creation", require("opencode.ui.input.history").get_pending("ses_fresh"))
			assert.same({ { type = "file", name = "new.png" } },
				require("opencode.ui.input.history").get_pending_parts("ses_fresh"))

			create_callback = nil
			input.set_pending_text("same text")
			require("opencode.ui.input.history").set_pending_parts({ { type = "file", name = "before.png" } })
			assert.is_true(slash.execute(slash.parse("/clear")))
			assert.is_not_nil(create_callback)
			require("opencode.ui.input.history").set_pending_parts({ { type = "file", name = "after.png" } })
			create_callback(nil, { id = "ses_final", title = "Final conversation" })
			assert.is_true(vim.wait(500, function() return state.get_session().id == "ses_final" end, 10))
			assert.equals("", input.get_pending_text())
			assert.equals("same text", require("opencode.ui.input.history").get_pending("ses_next"))
			assert.same({ { type = "file", name = "after.png" } },
				require("opencode.ui.input.history").get_pending_parts("ses_next"))
		end)

		lifecycle.ensure_connected = original_connect
		client.create_session = original_create
		vim.notify = original_notify
		state.reset()
		sync.clear_all()
		if not ok then error(err) end
	end)
end)
