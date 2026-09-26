describe("/btw side questions", function()
	local saved, original_notify
	local requests, shown, notices, refreshes
	local btw

	before_each(function()
		saved = {}
		for _, name in ipairs({ "opencode.btw", "opencode.client", "opencode.ui.btw", "opencode.ui.chat" }) do
			saved[name] = package.loaded[name]
			package.loaded[name] = nil
		end
		requests, shown, notices, refreshes = {}, {}, {}, 0
		package.loaded["opencode.client"] = {
			generate_text = function(session_id, prompt, callback)
				requests[#requests + 1] = { session_id = session_id, prompt = prompt, callback = callback }
			end,
		}
		package.loaded["opencode.ui.btw"] = {
			show = function(question, answer) shown[#shown + 1] = { question, answer } end,
			close = function() end,
		}
		package.loaded["opencode.ui.chat"] = { update_winbar = function() refreshes = refreshes + 1 end }
		original_notify = vim.notify
		vim.notify = function(message, level) notices[#notices + 1] = { message, level } end
		btw = require("opencode.btw")
	end)

	after_each(function()
		btw.reset()
		require("opencode.session.selection").clear_session("ses_one")
		require("opencode.session.selection").clear_session("ses_two")
		vim.notify = original_notify
		for _, name in ipairs({ "opencode.btw", "opencode.client", "opencode.ui.btw", "opencode.ui.chat" }) do
			package.loaded[name] = saved[name]
		end
	end)

	it("uses the current session in a transient, tool-free request and shows the answer", function()
		assert.is_true(btw.ask("ses_one", "  how is your day?  "))
		assert.equals(1, btw.pending_count())
		assert.equals(1, btw.pending_count("ses_one"))
		assert.equals("ses_one", requests[1].session_id)
		assert.equals(
			"The user is asking a quick side question about the conversation so far. "
				.. "Answer directly and concisely in markdown from what you already know. "
				.. "Do not call any tools and do not take any actions.\n\nhow is your day?",
			requests[1].prompt
		)
		requests[1].callback(nil, "  Day good.  ")
		assert.equals(0, btw.pending_count())
		assert.same({ { "how is your day?", "Day good." } }, shown)
		assert.is_true(refreshes >= 2)
	end)

	it("tracks concurrent questions and ignores stale replies after reset", function()
		assert.is_true(btw.ask("ses_one", "first"))
		assert.is_true(btw.ask("ses_two", "second"))
		assert.equals(2, btw.pending_count())
		requests[1].callback({ message = "Unavailable" })
		assert.equals(1, btw.pending_count())
		assert.matches("/btw failed: Unavailable", notices[1][1], 1, true)
		btw.reset()
		requests[2].callback(nil, "late")
		assert.equals(0, btw.pending_count())
		assert.same({}, shown)
	end)

	it("cancels only the deleted session's pending answer", function()
		assert.is_true(btw.ask("ses_one", "first"))
		assert.is_true(btw.ask("ses_two", "second"))
		require("opencode.cleanup").clear_session("ses_one")
		assert.equals(0, btw.pending_count("ses_one"))
		assert.equals(1, btw.pending_count("ses_two"))
		requests[1].callback(nil, "stale answer")
		assert.same({}, shown)
		requests[2].callback(nil, "current answer")
		assert.same({ { "second", "current answer" } }, shown)
		assert.equals(0, btw.pending_count())
	end)

	it("does not generate after selection preparation for a deleted session", function()
		local selection = require("opencode.session.selection")
		local original_prepare = selection.prepare
		local prepared_callback
		selection.prepare = function(_, _, _, callback)
			prepared_callback = callback
		end
		package.loaded["opencode.client"].get_session = function(_, callback)
			callback(nil, { id = "ses_one", agent = "build", model = { providerID = "provider", id = "old" } })
		end
		selection.choose("ses_one", "model", { providerID = "provider", modelID = "new" })
		local ok, err = pcall(function()
			assert.is_true(btw.ask("ses_one", "why?"))
			assert.is_function(prepared_callback)
			require("opencode.cleanup").clear_session("ses_one")
			prepared_callback(nil)
			assert.equals(0, #requests)
			assert.equals(0, btw.pending_count())
			assert.same({}, shown)
		end)
		selection.prepare = original_prepare
		if not ok then error(err) end
	end)

	it("prepares a locally selected model before transient generation", function()
		local selection = require("opencode.session.selection")
		local original_prepare = selection.prepare
		local prepared
		selection.prepare = function(session_id, desired, _, callback, known)
			prepared = { session_id = session_id, desired = desired, known = known }
			callback(nil)
		end
		package.loaded["opencode.client"].get_session = function(_, callback)
			callback(nil, { id = "ses_one", agent = "build", model = { providerID = "provider", id = "old" } })
		end
		selection.choose("ses_one", "model", { providerID = "provider", modelID = "new" })
		selection.choose("ses_one", "variant", "fast")
		local ok, err = pcall(function()
			assert.is_true(btw.ask("ses_one", "why?"))
			assert.equals("ses_one", prepared.session_id)
			assert.same({ providerID = "provider", id = "new", variant = "fast" }, prepared.desired.model)
			assert.equals("build", prepared.desired.agent)
			assert.equals("old", prepared.known.model.id)
			assert.equals(1, #requests)
		end)
		selection.prepare = original_prepare
		if not ok then error(err) end
		requests[1].callback(nil, "Done")
	end)

	it("applies a local agent choice when the session has no stored model", function()
		local selection = require("opencode.session.selection")
		local switched
		package.loaded["opencode.client"].get_session = function(_, callback)
			callback(nil, { id = "ses_one", agent = "build" })
		end
		package.loaded["opencode.client"].switch_agent = function(session_id, agent, callback)
			switched = { session_id, agent }
			callback(nil)
		end
		selection.choose("ses_one", "agent", "plan")
		assert.is_true(btw.ask("ses_one", "why?"))
		assert.same({ "ses_one", "plan" }, switched)
		assert.equals(1, #requests)
		requests[1].callback(nil, "Answer")
	end)

	it("rejects missing sessions and empty questions without issuing a request", function()
		assert.is_false(btw.ask(nil, "why?"))
		assert.is_false(btw.ask("ses_one", "   "))
		assert.equals(0, #requests)
		assert.equals(2, #notices)
	end)
end)

describe("/btw command entry", function()
	local slash = require("opencode.slash")
	local actions = require("opencode.actions")
	local state = require("opencode.state")
	local original_ask, original_session, original_view

	before_each(function()
		original_ask = actions.ask_btw
		original_session = state.get_session
		original_view = package.loaded["opencode.ui.btw"]
		slash.register_defaults()
	end)

	after_each(function()
		actions.ask_btw = original_ask
		state.get_session = original_session
		package.loaded["opencode.ui.btw"] = original_view
	end)

	it("routes explicit text and keeps the opening session for a bare /btw dialog", function()
		local asked, prompted, submit = {}, 0, nil
		actions.ask_btw = function(question, session_id) asked[#asked + 1] = { question, session_id } end
		local active_id = "ses_one"
		state.get_session = function() return { id = active_id } end
		package.loaded["opencode.ui.btw"] = { prompt = function(on_submit)
			prompted = prompted + 1
			submit = on_submit
		end }
		assert.is_true(slash.execute(slash.parse("/btw from composer")))
		assert.is_true(slash.execute(slash.parse("/btw")))
		active_id = "ses_two"
		submit("from dialog")
		assert.equals(1, prompted)
		assert.same({ { "from composer" }, { "from dialog", "ses_one" } }, asked)
		assert.equals("btw", require("opencode.ui.input.slash_commands").available_commands("btw")[1].name)
	end)

	it("keeps multiline side questions intact", function()
		local question
		actions.ask_btw = function(value) question = value end
		local parsed = slash.parse("/btw first line\nsecond line\nthird line")
		assert.equals("first line\nsecond line\nthird line", parsed.args)
		assert.is_true(slash.execute(parsed))
		assert.equals(parsed.args, question)
	end)

	it("keeps the opening session for a palette side question", function()
		local commands, submit, asked = {}, nil, nil
		local active_id = "ses_one"
		state.get_session = function() return { id = active_id } end
		actions.ask_btw = function(question, session_id) asked = { question, session_id } end
		package.loaded["opencode.ui.btw"] = { prompt = function(on_submit) submit = on_submit end }
		require("opencode.ui.palette.session").register({
			register = function(command) commands[command.id] = command end,
		})
		commands["session.aside"].run()
		active_id = "ses_two"
		submit("from palette")
		assert.same({ "from palette", "ses_one" }, asked)
	end)

	it("uses generic Enter dispatch for /btw arguments, selection, and ordinary text", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
		local send_count, select_count, mode = 0, 0, "submit"
		require("opencode.ui.input.keymaps").setup(bufnr, { keymaps = {} }, {
			autocomplete_visible = function() return false end,
			command_enter_mode = function() return mode end,
			command_enter_select = function() select_count = select_count + 1 end,
			send = function() send_count = send_count + 1 end,
		})
		local enter = vim.fn.maparg("<CR>", "i", false, true).callback
		assert.equals("", enter())
		assert.is_true(vim.wait(100, function() return send_count == 1 end, 5))
		mode = "select"
		assert.equals("", enter())
		assert.is_true(vim.wait(100, function() return select_count == 1 end, 5))
		mode = nil
		assert.equals(vim.api.nvim_replace_termcodes("<CR>", true, false, true), enter())
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)
end)
