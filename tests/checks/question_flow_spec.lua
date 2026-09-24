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
	local previous, bufnr, old_reply, old_reject, old_show, old_notify, notifications

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
		old_reply, old_reject, old_show, old_notify = actions.reply_to_question, actions.reject_question, input.show, vim.notify
		notifications = {}
		vim.notify = function(message, level) notifications[#notifications + 1] = { message = tostring(message), level = level } end
	end)

	after_each(function()
		actions.reply_to_question, actions.reject_question, input.show, vim.notify = old_reply, old_reject, old_show, old_notify
		require("opencode.events.bus").clear()
		forms.clear_all(); app_state.reset()
		chat_state.bufnr, chat_state.winid, chat_state.visible = previous.bufnr, previous.winid, previous.visible
		chat_state.tabpage, chat_state.questions, chat_state.session_stack = previous.tabpage, previous.questions, previous.session_stack
		chat_state.render_scheduled, chat_state.render_in_progress = previous.render_scheduled, previous.render_in_progress
		if vim.api.nvim_buf_is_valid(previous.current_buf) then vim.api.nvim_win_set_buf(0, previous.current_buf) end
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
	end)

	it("submits a selected boolean value by field key", function()
		local calls = {}
		actions.reply_to_question = function(id, answer, callback) calls[#calls + 1] = { id = id, answer = answer, callback = callback } end
		add_form("bool-form", { { key = "confirm", title = "Continue?", type = "boolean", required = true } })
		mount("bool-form")
		interactions.handle_question_number_select(2)
		assert.equals(1, #calls)
		assert.equals("bool-form", calls[1].id)
		assert.same({ confirm = false }, calls[1].answer)
		calls[1].callback(nil, true)
		wait_for(function() return forms.get_question("bool-form").status == "answered" end)
	end)

	it("sends a custom string after the input is submitted", function()
		local shown, reply
		input.show = function(opts) shown = opts end
		actions.reply_to_question = function(id, answer, callback) reply = { id = id, answer = answer, callback = callback } end
		add_form("string-form", { { key = "description", title = "Describe it", type = "string", required = true } })
		mount("string-form")
		interactions.handle_question_confirm()
		assert.is_function(shown.on_send)
		assert.is_nil(reply)
		shown.on_send("custom answer")
		assert.same({ description = "custom answer" }, reply.answer)
		assert.is_true(forms.get_question("string-form").submitting)
	end)

	it("keeps form submissions retryable after an HTTP error", function()
		local callbacks = {}
		actions.reply_to_question = function(_, _, callback) callbacks[#callbacks + 1] = callback end
		add_form("retry-form", { { key = "confirm", title = "Retry?", type = "boolean", required = true } })
		forms.select_option("retry-form", 1)
		mount("retry-form")
		assert.is_true(chat_forms.submit_question_answers("retry-form"))
		assert.is_false(chat_forms.submit_question_answers("retry-form"))
		assert.equals(1, #callbacks)
		assert.is_truthy(buffer_text():find("Submitting answer", 1, true))
		callbacks[1]({ status = 404, message = "QuestionNotFoundError: Question request not found" })
		wait_for(function() return not forms.get_question("retry-form").submitting end)
		assert.equals("pending", forms.get_question("retry-form").status)
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
		mount("cancel-form")
		assert.is_true(chat_forms.submit_question_answers("cancel-form"))
		bus.emit("v2_interaction", { id = "cancel-event", type = "form.cancelled", data = { id = "cancel-form", sessionID = "question-session" } })
		assert.equals("rejected", forms.get_question("cancel-form").status)
		callback(nil, true)
		vim.wait(30)
		assert.equals("rejected", forms.get_question("cancel-form").status)
	end)

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
