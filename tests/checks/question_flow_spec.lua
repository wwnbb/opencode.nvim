-- Native v2 form routing and chat interaction checks.

local function wait_for(predicate)
	assert(vim.wait(500, predicate, 10))
end

describe("opencode native form flow", function()
	local app_state = require("opencode.state")
	local forms = require("opencode.question.state")
	local chat_state = require("opencode.ui.chat.state").state
	local widget = require("opencode.ui.question_widget")
	local widget_base = require("opencode.ui.widget_base")
	local chat_forms = require("opencode.ui.chat.questions")
	local interactions = require("opencode.ui.chat.interactions")
	local actions = require("opencode.actions")
	local input = require("opencode.ui.input")
	local previous, bufnr, old_reply, old_reject, old_show, old_notify, old_open, notifications

	local function add_form(id, fields)
		return forms.add_form({ id = id, sessionID = "question-session", title = "User input", fields = fields })
	end

	local function mount(id)
		local item = forms.get_question(id)
		local lines, _, meta = widget.get_lines_for_question(id, { questions = item.questions }, item, item.status)
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false
		chat_state.questions = { [id] = { start_line = 0, end_line = #lines - 1, status = item.status } }
		vim.api.nvim_win_set_cursor(chat_state.winid, { math.min((widget_base.get_focus_offset(meta) or 0) + 1, #lines), 0 })
	end

	local function buffer_text()
		return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	end

	local function key(lhs)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "xt", false)
	end

	local function setup_keymaps()
		local saved_config = chat_state.config
		chat_state.config = vim.deepcopy(require("opencode.config").defaults.chat)
		require("opencode.ui.chat.keymaps").setup_buffer(bufnr, {})
		chat_state.config = saved_config
	end

	before_each(function()
		if input.is_visible() then input.close(false) end
		forms.clear_all(); app_state.reset()
		app_state.upsert_session({ id = "question-session", directory = "/tmp/__opencode_question_session__" })
		app_state.set_session("question-session", "Question Session")
		previous = {
			bufnr = chat_state.bufnr, winid = chat_state.winid, visible = chat_state.visible,
			tabpage = chat_state.tabpage, questions = chat_state.questions,
			session_stack = chat_state.session_stack, render_scheduled = chat_state.render_scheduled,
			render_in_progress = chat_state.render_in_progress,
			current_buf = vim.api.nvim_get_current_buf(),
		}
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(0, bufnr)
		chat_state.bufnr, chat_state.winid = bufnr, vim.api.nvim_get_current_win()
		chat_state.visible, chat_state.tabpage = true, vim.api.nvim_get_current_tabpage()
		chat_state.questions, chat_state.session_stack = {}, {}
		chat_state.render_scheduled, chat_state.render_in_progress = false, false
		old_reply, old_reject, old_show, old_notify, old_open = actions.reply_to_question, actions.reject_question, input.show, vim.notify, vim.ui.open
		notifications = {}
		vim.notify = function(message, level) notifications[#notifications + 1] = { message = tostring(message), level = level } end
	end)

	after_each(function()
		actions.reply_to_question, actions.reject_question, input.show, vim.notify, vim.ui.open = old_reply, old_reject, old_show, old_notify, old_open
		require("opencode.events.bus").clear()
		forms.clear_all(); app_state.reset()
		chat_state.bufnr, chat_state.winid, chat_state.visible = previous.bufnr, previous.winid, previous.visible
		chat_state.tabpage, chat_state.questions, chat_state.session_stack = previous.tabpage, previous.questions, previous.session_stack
		chat_state.render_scheduled, chat_state.render_in_progress = previous.render_scheduled, previous.render_in_progress
		if vim.api.nvim_buf_is_valid(previous.current_buf) then vim.api.nvim_win_set_buf(0, previous.current_buf) end
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
	end)

	it("moves to each numbered answer without approving it", function()
		local options, calls = {}, 0
		for i = 1, 9 do options[i] = { label = "Answer " .. i, value = tostring(i) } end
		actions.reply_to_question = function() calls = calls + 1 end
		local item = add_form("digits", { { key = "choice", type = "string", required = true, options = options } })
		mount("digits")
		for i = 1, 9 do
			assert.is_true(interactions.handle_question_number_select(i))
			assert.is_truthy(vim.api.nvim_get_current_line():find(i .. ". Answer " .. i, 1, true))
			interactions.sync_widget_selection_from_cursor()
			assert.same({ i }, forms.get_current_selection("digits"))
			assert.equals("pending", item.status)
		end
		assert.equals(0, calls)
	end)

	it("uses Enter to visit the next question even when all answers have defaults", function()
		local calls = 0
		actions.reply_to_question = function() calls = calls + 1 end
		local fields = {}
		for i = 1, 3 do fields[i] = { key = "q" .. i, title = "Question " .. i, type = "boolean", default = false } end
		local item = add_form("tabs", fields)
		mount("tabs")
		for i = 2, 3 do
			interactions.handle_question_confirm()
			assert.equals(i, item.current_tab)
			assert.equals("pending", item.status)
		end
		interactions.handle_question_confirm()
		assert.equals("confirming", item.status)
		assert.equals(0, calls)
		interactions.handle_question_number_select(2)
		interactions.handle_question_confirm()
		assert.equals("pending", item.status)
		assert.equals(3, item.current_tab)
		assert.same({ q1 = false, q2 = false, q3 = false }, forms.get_answers("tabs"))
		assert.equals(0, calls)
	end)

	for _, count in ipairs({ 0, 2 }) do
		it("cycles question tabs safely with " .. count .. " visible fields", function()
			setup_keymaps()
			local fields = {}
			for i = 1, count do fields[i] = { key = "q" .. i, type = "boolean", default = false } end
			local item = add_form("cycle-tabs", fields)
			mount("cycle-tabs")
			local answers = forms.get_answers("cycle-tabs")
			key("<S-Tab>")
			assert.equals(math.max(1, count), item.current_tab)
			key("<Tab>")
			assert.equals(1, item.current_tab)
			assert.same(answers, forms.get_answers("cycle-tabs"))
		end)
	end

	it("does not skip an unanswered required question", function()
		local item = add_form("required", {
			{ key = "first", type = "boolean", required = true },
			{ key = "second", type = "boolean", required = true },
		})
		mount("required")
		interactions.handle_question_confirm()
		assert.equals(1, item.current_tab)
		interactions.handle_question_number_select(2)
		interactions.handle_question_confirm()
		assert.equals(2, item.current_tab)
		assert.equals("pending", item.status)
		assert.is_false(item.selections[2].is_answered)
		interactions.handle_question_confirm()
		assert.equals("pending", item.status)
		interactions.handle_question_number_select(1)
		interactions.handle_question_confirm()
		assert.equals("confirming", item.status)
	end)

	it("keeps multiple selections while moving the cursor and requires confirmation", function()
		local calls = 0
		actions.reply_to_question = function() calls = calls + 1 end
		local item = add_form("multi", { { key = "choices", type = "multiselect", required = true,
			options = { { label = "One", value = "one" }, { label = "Two", value = "two" } } } })
		mount("multi")
		interactions.handle_question_number_select(1)
		interactions.handle_question_number_select(2)
		assert.is_truthy(vim.api.nvim_get_current_line():find("2. Two", 1, true))
		interactions.sync_widget_selection_from_cursor()
		assert.same({ choices = { "one", "two" } }, forms.get_answers("multi"))
		interactions.handle_question_number_select(9)
		assert.same({ 1, 2 }, forms.get_current_selection("multi"))
		interactions.handle_question_confirm()
		assert.equals("confirming", item.status)
		assert.equals(0, calls)
	end)

	it("maps digits, Enter and Escape to selection, confirmation and review", function()
		setup_keymaps()
		local calls = 0
		actions.reply_to_question = function() calls = calls + 1 end
		actions.reject_question = function() error("Escape must return to answers") end
		local item = add_form("keys", { { key = "ok", type = "boolean", required = true } })
		mount("keys")
		key("2")
		assert.same({ ok = false }, forms.get_answers("keys"))
		key("<CR>")
		assert.equals("confirming", item.status)
		key("<Esc>")
		assert.equals("pending", item.status)
		assert.equals(1, item.current_tab)
		assert.is_truthy(vim.api.nvim_get_current_line():find("2. No", 1, true))
		assert.same({ ok = false }, forms.get_answers("keys"))
		assert.equals(0, calls)
	end)

	it("reselects a saved custom answer with j/k without submitting or losing the draft", function()
		setup_keymaps()
		local shown, replies = nil, {}
		input.show = function(opts) shown = opts end
		actions.reply_to_question = function(_, answer) replies[#replies + 1] = answer end
		local item = add_form("custom-choice", { { key = "choice", type = "string", custom = true, required = true,
			options = { { label = "One", value = "one" }, { label = "Two", value = "two" } } } })
		mount("custom-choice")
		key("c")
		shown.on_send("Some Answer")
		assert.same({ choice = "Some Answer" }, forms.get_answers("custom-choice"))
		key("2")
		assert.same({ choice = "two" }, forms.get_answers("custom-choice"))
		assert.is_false(item.selections[1].custom_present)
		assert.is_nil(buffer_text():find("❯ Custom:", 1, true))
		key("j"); key("j")
		assert.is_truthy(vim.api.nvim_get_current_line():find("Custom: Some Answer", 1, true))
		assert.same({ choice = "Some Answer" }, forms.get_answers("custom-choice"))
		assert.same({}, forms.get_current_selection("custom-choice"))
		key("k"); key("k")
		assert.same({ choice = "two" }, forms.get_answers("custom-choice"))
		assert.equals("Some Answer", item.selections[1].custom_input)
		key("j"); key("j")
		assert.same({ choice = "Some Answer" }, forms.get_answers("custom-choice"))
		assert.same({}, replies)
		key("<CR>")
		assert.equals("confirming", item.status)
		assert.is_truthy(buffer_text():find("choice: Some Answer", 1, true))
		assert.is_nil(buffer_text():find("choice: Two", 1, true))
		key("<CR>")
		assert.same({ { choice = "Some Answer" } }, replies)
	end)

	it("toggles a saved custom multiselect at the cursor without losing its text", function()
		setup_keymaps()
		local item = add_form("custom-multi", { { key = "choices", type = "multiselect", custom = true, required = true,
			options = { { label = "One", value = "one" } } } })
		forms.set_custom_input("custom-multi", 1, "Other")
		mount("custom-multi")
		key("j"); key("j")
		assert.is_truthy(vim.api.nvim_get_current_line():find("Custom: Other", 1, true))
		key("<Space>")
		assert.is_false(item.selections[1].is_answered)
		assert.same({}, forms.get_answers("custom-multi"))
		assert.equals("Other", item.selections[1].custom_input)
		key("<Space>")
		assert.same({ choices = { "Other" } }, forms.get_answers("custom-multi"))
		key("1")
		key("1")
		assert.is_true(item.selections[1].is_answered)
		assert.same({ choices = { "Other" } }, forms.get_answers("custom-multi"))
	end)

	it("selects a boolean by number and submits only after confirmation", function()
		local calls = {}
		actions.reply_to_question = function(id, answer, callback) calls[#calls + 1] = { id = id, answer = answer, callback = callback } end
		add_form("bool-form", { { key = "confirm", title = "Continue?", type = "boolean", required = true } })
		mount("bool-form")
		interactions.handle_question_number_select(2)
		assert.equals(0, #calls)
		assert.equals("pending", forms.get_question("bool-form").status)
		assert.is_truthy(vim.api.nvim_get_current_line():find("2. No", 1, true))
		interactions.sync_widget_selection_from_cursor()
		assert.same({ confirm = false }, forms.get_answers("bool-form"))
		assert.is_false(chat_forms.submit_question_answers("bool-form"))
		interactions.handle_question_confirm()
		assert.equals("confirming", forms.get_question("bool-form").status)
		assert.equals(0, #calls)
		interactions.handle_question_confirm()
		assert.equals(1, #calls)
		assert.equals("bool-form", calls[1].id)
		assert.same({ confirm = false }, calls[1].answer)
		calls[1].callback(nil, true)
		wait_for(function() return forms.get_question("bool-form").status == "answered" end)
	end)

	it("requires confirmation after entering a custom string", function()
		local shown, reply
		input.show = function(opts) shown = opts end
		actions.reply_to_question = function(id, answer, callback) reply = { id = id, answer = answer, callback = callback } end
		add_form("string-form", { { key = "description", title = "Describe it", type = "string", required = true } })
		mount("string-form")
		interactions.handle_question_confirm()
		assert.is_function(shown.on_send)
		assert.is_nil(reply)
		shown.on_send("custom answer")
		assert.is_nil(reply)
		assert.equals("pending", forms.get_question("string-form").status)
		interactions.handle_question_confirm()
		assert.equals("confirming", forms.get_question("string-form").status)
		assert.is_nil(reply)
		interactions.handle_question_confirm()
		assert.same({ description = "custom answer" }, reply.answer)
		assert.is_true(forms.get_question("string-form").submitting)
	end)

	for _, reset in ipairs({ "owner", "close", "reconnect" }) do
		it("does not send an old custom input after " .. reset, function()
			local shown, calls = nil, 0
			input.show = function(opts) shown = opts end
			actions.reply_to_question = function() calls = calls + 1 end
			local fields = { { key = "description", type = "string", required = true } }
			add_form("input-form", fields)
			mount("input-form")
			chat_forms.handle_question_custom_input("input-form")
			assert.is_function(shown.on_send)
			local pending = require("opencode.session.pending")
			if reset == "owner" then forms.clear_all(); add_form("input-form", fields)
			elseif reset == "close" then pending.clear_session("question-session")
			else pending.invalidate() end
			shown.on_send("Answer for the old form")
			assert.is_nil(forms.get_answers("input-form").description)
			assert.equals(0, calls)
		end)
	end

	it("opens an external link, waits for confirmation, then submits it with text", function()
		local opens, calls = {}, {}
		vim.ui.open = function(url) opens[#opens + 1] = url; return {} end
		actions.reply_to_question = function(id, answer, callback) calls[#calls + 1] = { id = id, answer = answer, callback = callback } end
		local item = add_form("external-form", {
			{ key = "authorization", type = "external", url = "https://example.com/authorize" },
			{ key = "note", type = "string", required = true },
		})
		forms.set_custom_input("external-form", 2, "done")
		mount("external-form")
		assert.is_false(forms.validate_form("external-form"))
		interactions.handle_question_confirm()
		assert.same({ "https://example.com/authorize" }, opens)
		assert.is_true(item.form_selections.authorization.external_ready)
		assert.is_nil(forms.get_answers("external-form").authorization)
		assert.equals(0, #calls)
		interactions.handle_question_confirm()
		assert.is_true(item.form_selections.authorization.is_answered)
		assert.same({ authorization = true, note = "done" }, forms.get_answers("external-form"))
		assert.equals("note", item.questions[item.current_tab].key)
		interactions.handle_question_confirm()
		assert.equals("confirming", item.status)
		assert.is_truthy(buffer_text():find("Acknowledged", 1, true))
		interactions.handle_question_confirm()
		assert.equals(1, #calls)
		assert.same({ authorization = true, note = "done" }, calls[1].answer)
		assert.equals(1, #opens)
	end)

	it("copies an external URL when the opener fails and still requires confirmation", function()
		vim.ui.open = function() return nil, "no handler" end
		local item = add_form("copy-form", { { key = "authorization", type = "external", url = "https://example.com/manual" } })
		mount("copy-form")
		interactions.handle_question_confirm()
		assert.is_false(item.form_selections.authorization.external_ready)
		assert.is_nil(forms.get_answers("copy-form").authorization)
		chat_forms.handle_question_custom_input("copy-form")
		assert.is_true(item.form_selections.authorization.external_ready)
		assert.is_nil(forms.get_answers("copy-form").authorization)
		interactions.handle_question_confirm()
		assert.same({ authorization = true }, forms.get_answers("copy-form"))
		assert.equals("confirming", item.status)
	end)

	it("keeps form submissions retryable after an HTTP error", function()
		local callbacks = {}
		actions.reply_to_question = function(_, _, callback) callbacks[#callbacks + 1] = callback end
		add_form("retry-form", { { key = "confirm", title = "Retry?", type = "boolean", required = true } })
		forms.select_option("retry-form", 1)
		forms.set_confirming("retry-form")
		mount("retry-form")
		assert.is_true(chat_forms.submit_question_answers("retry-form"))
		assert.is_false(chat_forms.submit_question_answers("retry-form"))
		assert.equals(1, #callbacks)
		assert.is_truthy(buffer_text():find("Submitting answer", 1, true))
		callbacks[1]({ status = 404, message = "QuestionNotFoundError: Question request not found" })
		wait_for(function() return not forms.get_question("retry-form").submitting end)
		assert.equals("confirming", forms.get_question("retry-form").status)
		assert.is_true(#notifications > 0)
		assert.is_true(chat_forms.submit_question_answers("retry-form"))
		assert.equals(2, #callbacks)
	end)

	it("keeps a server cancellation terminal when a reply callback arrives late", function()
		local callback
		actions.reply_to_question = function(_, _, done) callback = done end
		local bus = require("opencode.events.bus")
		bus.clear()
		require("opencode.events.handlers.interactions_v2").setup(bus)
		add_form("cancel-form", { { key = "confirm", title = "Continue?", type = "boolean", required = true } })
		forms.select_option("cancel-form", 1)
		forms.set_confirming("cancel-form")
		mount("cancel-form")
		assert.is_true(chat_forms.submit_question_answers("cancel-form"))
		require("tests.helpers.schedule").with(function(flush)
			bus.emit("v2_interaction", { id = "cancel-event", type = "form.cancelled", data = { id = "cancel-form", sessionID = "question-session" } })
			assert.equals("rejected", forms.get_question("cancel-form").status)
			callback(nil, true)
			flush()
			assert.equals("rejected", forms.get_question("cancel-form").status)
		end)
	end)

	for _, cancelling in ipairs({ false, true }) do
		for _, failed in ipairs({ false, true }) do
			it("ignores a queued " .. (cancelling and "cancellation" or "answer") .. (failed and " error" or " success") .. " for a replaced form", function()
				local callback
				actions.reply_to_question = function(_, _, done) callback = done end
				actions.reject_question = function(_, _, done) callback = done end
				local fields = { { key = "confirm", type = "boolean", required = true } }
				add_form("replaced-form", fields)
				forms.select_option("replaced-form", 1)
				if not cancelling then forms.set_confirming("replaced-form") end
				mount("replaced-form")
				if cancelling then interactions.handle_question_cancel()
				else assert.is_true(chat_forms.submit_question_answers("replaced-form")) end
				assert.is_function(callback)
				require("tests.helpers.schedule").with(function(flush)
					callback(failed and { message = "Old request failed" } or nil)
					forms.clear_all()
					local replacement = add_form("replaced-form", fields)
					assert.is_true(forms.begin_submission("replaced-form", "reject"))
					flush()
					assert.equals("pending", replacement.status)
					assert.is_true(replacement.submitting)
					assert.is_nil(replacement.server_error)
					assert.same({}, notifications)
				end)
			end)
		end
	end

	for _, cancelling in ipairs({ false, true }) do
		for _, failed in ipairs({ false, true }) do
			it("ignores an invalidated queued " .. (cancelling and "cancel" or "reply") .. (failed and " failure" or " success") .. " for the same form", function()
				local callback
				actions.reply_to_question = function(_, _, done) callback = done end
				actions.reject_question = function(_, _, done) callback = done end
				local item = add_form("same-form", { { key = "confirm", type = "boolean", required = true } })
				forms.select_option("same-form", 1)
				if not cancelling then forms.set_confirming("same-form") end
				mount("same-form")
				if cancelling then interactions.handle_question_cancel()
				else assert.is_true(chat_forms.submit_question_answers("same-form")) end
				require("tests.helpers.schedule").with(function(flush)
					callback(failed and { message = "Old request failed" } or nil)
					require("opencode.session.pending").clear_session("question-session")
					flush()
					assert.equals(cancelling and "pending" or "confirming", item.status)
					assert.is_true(item.submitting)
					assert.is_nil(item.server_error)
					assert.same({}, notifications)
				end)
			end)
		end
	end

	it("routes form replies and cancellation through the owning session", function()
		local client = require("opencode.client")
		add_form("owner-form", { { key = "ok", title = "Owner?", type = "boolean", required = true } })
		local reply_opts, reject_opts, reject_session
		local original_reply, original_reject = client.reply_to_question, client.reject_question
		client.reply_to_question = function(_, _, opts) reply_opts = opts end
		client.reject_question = function(sid, _, opts) reject_session, reject_opts = sid, opts end
		actions.reply_to_question("owner-form", { ok = true }, function() end)
		actions.reject_question("wrong-session", "owner-form", function() end)
		client.reply_to_question, client.reject_question = original_reply, original_reject
		local directory = app_state.get_session_directory("question-session")
		assert.equals("question-session", reply_opts.session_id)
		assert.equals("question-session", reject_session)
		assert.equals(directory, reply_opts.directory)
		assert.equals(directory, reject_opts.directory)
	end)

	it("blocks the composer while a form needs input", function()
		add_form("blocking-form", { { key = "ok", title = "Answer first", type = "boolean", required = true } })
		mount("blocking-form")
		local chat = require("opencode.ui.chat")
		assert.is_false(chat.focus_input())
		assert.is_false(input.is_visible())
		assert.is_true(forms.begin_submission("blocking-form", "reject"))
		assert.is_false(chat.focus_input())
		assert.is_true(#notifications >= 2)
	end)
end)

describe("question focus during queued renders", function()
	local chat_surface = require("tests.helpers.chat_surface")
	local chat = require("opencode.ui.chat")
	local forms = require("opencode.question.state")
	local interactions = require("opencode.ui.chat.interactions")
	local state = require("opencode.ui.chat.state").state
	local surface
	before_each(function()
		forms.clear_all()
		surface = chat_surface.setup()
		require("opencode.state").set_session("focus-session", "Focus")
	end)
	after_each(function()
		forms.clear_all()
		chat_surface.restore(surface)
	end)
	for _, answer in ipairs({ "option", "custom", "multi" }) do
		it("keeps the saved " .. answer .. " answer visible when focusing the widget again", function()
			local item = forms.add_form({ id = "return-focus", sessionID = "focus-session", fields = {
				{ key = "choice", type = answer == "multi" and "multiselect" or "string", custom = true, required = true,
					options = { { label = "One", value = "one" }, { label = "Two", value = "two" } } },
				{ key = "next", type = "boolean", required = true },
			} })
			if answer == "custom" then forms.set_custom_input("return-focus", 1, "Saved custom")
			elseif answer == "multi" then forms.toggle_multi_select("return-focus", 2)
			else forms.select_option("return-focus", 2) end
			local expected = forms.get_answers("return-focus")
			chat.do_render()
			local pos = state.questions["return-focus"]
			vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + 2, 0 })
			interactions.handle_question_confirm()
			assert.equals(2, item.current_tab)
			interactions.handle_question_prev_tab()
			assert.equals(1, item.current_tab)
			assert.same(expected, forms.get_answers("return-focus"))
			require("opencode.ui.chat.widget_support").request_focus("question", "return-focus", item.status)
			chat.do_render()
			assert.same(expected, forms.get_answers("return-focus"))
			assert.is_truthy(vim.api.nvim_get_current_line():find(answer == "custom" and "Custom: Saved custom" or "2. Two", 1, true))
			local text = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
			assert.is_truthy(text:find(answer == "custom" and "❯ Custom: Saved custom" or answer == "multi" and "☑ 2. Two" or "❯ 2. Two", 1, true))
		end)
	end
	it("preserves the chosen answer and returns the cursor after confirmation", function()
		local item = forms.add_form({ id = "focus", sessionID = "focus-session", fields = {
			{ key = "ok", type = "boolean", required = true },
		} })
		chat.do_render()
		local pos = state.questions.focus
		vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + 2, 0 })
		state.render_scheduled = true
		interactions.handle_question_number_select(2)
		assert.same({ ok = false }, forms.get_answers("focus"))
		assert.is_truthy(vim.api.nvim_get_current_line():find("2. No", 1, true))
		state.render_scheduled = true
		interactions.handle_question_confirm()
		assert.equals("confirming", item.status)
		assert.is_truthy(vim.api.nvim_get_current_line():find("Yes, submit", 1, true))
		state.render_scheduled = true
		interactions.handle_question_cancel()
		assert.equals("pending", item.status)
		assert.same({ ok = false }, forms.get_answers("focus"))
		assert.is_truthy(vim.api.nvim_get_current_line():find("2. No", 1, true))
	end)
end)
