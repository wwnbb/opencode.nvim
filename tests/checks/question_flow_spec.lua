-- Question request routing, lifecycle, and interaction checks.
-- Run with: ./tests/run.sh checks

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_true(value, message)
	if not value then
		error(message)
	end
end

local function wait_for(predicate, message)
	assert_true(vim.wait(500, predicate, 10), message)
end

describe("opencode question flow", function()
	local app_state = require("opencode.state")
	local question_state = require("opencode.question.state")
	local chat_state = require("opencode.ui.chat.state").state
	local question_widget = require("opencode.ui.question_widget")
	local widget_base = require("opencode.ui.widget_base")
	local chat_questions = require("opencode.ui.chat.questions")
	local interactions = require("opencode.ui.chat.interactions")
	local actions = require("opencode.actions")
	local input = require("opencode.ui.input")

	local previous
	local bufnr
	local original_reply
	local original_reject
	local original_input_show
	local original_notify
	local notifications

	local function add_question(request_id, questions)
		return question_state.add_question(request_id, "question-session", questions, { timestamp = os.time() })
	end

	local function mount_question(request_id)
		local qstate = question_state.get_question(request_id)
		local lines, _, meta = question_widget.get_lines_for_question(
			request_id,
			{ questions = qstate.questions },
			qstate,
			qstate.status
		)
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false
		chat_state.questions = {
			[request_id] = {
				start_line = 0,
				end_line = #lines - 1,
				status = qstate.status,
			},
		}
		local focus_offset = widget_base.get_focus_offset(meta) or 0
		vim.api.nvim_win_set_cursor(chat_state.winid, { math.min(focus_offset + 1, #lines), 0 })
	end

	local function buffer_text()
		return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	end

	before_each(function()
		if input.is_visible() then
			input.close(false)
		end
		question_state.clear_all()
		app_state.reset()
		app_state.upsert_session({ id = "question-session", directory = "/tmp/__opencode_question_session__" })
		app_state.set_session("question-session", "Question Session")

		previous = {
			bufnr = chat_state.bufnr,
			winid = chat_state.winid,
			visible = chat_state.visible,
			tabpage = chat_state.tabpage,
			questions = chat_state.questions,
			session_stack = chat_state.session_stack,
			render_scheduled = chat_state.render_scheduled,
			render_in_progress = chat_state.render_in_progress,
		}
		previous.current_buf = vim.api.nvim_get_current_buf()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_win_set_buf(0, bufnr)
		chat_state.bufnr = bufnr
		chat_state.winid = vim.api.nvim_get_current_win()
		chat_state.visible = true
		chat_state.tabpage = vim.api.nvim_get_current_tabpage()
		chat_state.questions = {}
		chat_state.session_stack = {}
		chat_state.render_scheduled = false
		chat_state.render_in_progress = false

		original_reply = actions.reply_to_question
		original_reject = actions.reject_question
		original_input_show = input.show
		original_notify = vim.notify
		notifications = {}
		vim.notify = function(message, level)
			table.insert(notifications, { message = tostring(message), level = level })
		end
	end)

	after_each(function()
		actions.reply_to_question = original_reply
		actions.reject_question = original_reject
		input.show = original_input_show
		vim.notify = original_notify
		require("opencode.events.bus").clear()
		require("opencode.events.bus").clear_history()
		question_state.clear_all()
		app_state.reset()
		chat_state.bufnr = previous.bufnr
		chat_state.winid = previous.winid
		chat_state.visible = previous.visible
		chat_state.tabpage = previous.tabpage
		chat_state.questions = previous.questions
		chat_state.session_stack = previous.session_stack
		chat_state.render_scheduled = previous.render_scheduled
		chat_state.render_in_progress = previous.render_in_progress
		if vim.api.nvim_buf_is_valid(previous.current_buf) then
			vim.api.nvim_win_set_buf(0, previous.current_buf)
		end
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
	end)

	it("submits a single non-multiple option by number or one Enter", function()
		local calls = {}
		actions.reply_to_question = function(request_id, answers, callback)
			table.insert(calls, { request_id = request_id, answers = answers, callback = callback })
		end

		add_question("question-enter", {
			{ question = "Pick one", options = { { label = "A", value = "a" }, { label = "B", value = "b" } } },
		})
		mount_question("question-enter")
		local request_id, changed = chat_questions.sync_selected_option_from_cursor()
		assert_eq(request_id, "question-enter", "cursor selection should target the question")
		assert_true(changed, "cursor movement should select the pointed option")
		assert_eq(#calls, 0, "cursor selection must not submit")

		interactions.handle_question_confirm()
		assert_eq(#calls, 1, "one Enter should submit an already selected single option")
		assert_eq(calls[1].answers[1][1], "a", "Enter should submit the selected value")
		calls[1].callback(nil, true)
		wait_for(function()
			return question_state.get_question("question-enter").status == "answered"
		end, "successful Enter submission should resolve as answered")

		question_state.clear_all()
		add_question("question-number", {
			{ question = "Pick one", options = { { label = "A", value = "a" }, { label = "B", value = "b" } } },
		})
		mount_question("question-number")
		interactions.handle_question_number_select(2)
		assert_eq(#calls, 2, "number selection should submit a single non-multiple question immediately")
		assert_eq(calls[2].answers[1][1], "b", "number selection should submit the numbered value")
	end)

	it("submits custom input immediately only for a single non-multiple question", function()
		local shown
		local captured
		input.show = function(opts)
			shown = opts
		end
		actions.reply_to_question = function(request_id, answers, callback)
			captured = { request_id = request_id, answers = answers, callback = callback }
		end

		add_question("question-custom", {
			{
				question = "Describe it",
				custom = true,
				options = { { label = "Known", value = "known" } },
			},
		})
		mount_question("question-custom")
		chat_questions.handle_question_custom_input("question-custom")
		assert_true(shown and type(shown.on_send) == "function", "custom input should open the question input")
		shown.on_send("custom answer")

		assert_true(captured ~= nil, "confirming custom input should submit immediately")
		assert_eq(captured.answers[1][1], "custom answer", "custom input should preserve answer serialization")
		assert_true(question_state.get_question("question-custom").submitting, "custom reply should lock while in flight")
	end)

	it("keeps multi-select and multi-question flows behind confirmation", function()
		local calls = 0
		actions.reply_to_question = function()
			calls = calls + 1
		end

		add_question("question-multiple", {
			{
				question = "Pick several",
				multiple = true,
				options = { { label = "A", value = "a" }, { label = "B", value = "b" } },
			},
		})
		mount_question("question-multiple")
		interactions.handle_question_number_select(1)
		assert_eq(calls, 0, "multi-select number keys should toggle without submitting")
		interactions.handle_question_confirm()
		interactions.handle_question_confirm()
		assert_eq(question_state.get_question("question-multiple").status, "confirming", "multi-select should show confirmation")
		assert_eq(calls, 0, "multi-select should not submit before confirmation")
		interactions.handle_question_confirm()
		assert_eq(calls, 1, "confirmation Enter should submit multi-select answers")

		question_state.clear_all()
		add_question("question-block", {
			{ question = "First", options = { { label = "A", value = "a" } } },
			{ question = "Second", options = { { label = "B", value = "b" } } },
		})
		question_state.select_option("question-block", 1)
		question_state.set_tab("question-block", 2)
		question_state.select_option("question-block", 1)
		mount_question("question-block")
		interactions.handle_question_confirm()
		interactions.handle_question_confirm()
		assert_eq(question_state.get_question("question-block").status, "confirming", "question blocks should show confirmation")
		assert_eq(calls, 1, "question blocks should not submit before final confirmation")
	end)

	it("uses number 2 to return from single multi-select confirmation without submitting", function()
		local calls = 0
		actions.reply_to_question = function()
			calls = calls + 1
		end

		add_question("question-confirm-no", {
			{
				question = "Pick several",
				multiple = true,
				options = { { label = "A", value = "a" } },
			},
		})
		question_state.toggle_multi_select("question-confirm-no", 1)
		question_state.mark_ready_to_advance("question-confirm-no")
		question_state.set_confirming("question-confirm-no")
		mount_question("question-confirm-no")

		interactions.handle_question_number_select(2)
		assert_eq(calls, 0, "number 2 must not submit from confirmation")
		assert_eq(question_state.get_current_selection("question-confirm-no")[1], 2, "number 2 should select review")
		interactions.handle_question_confirm()
		assert_eq(calls, 0, "review confirmation should not submit")
		assert_eq(question_state.get_question("question-confirm-no").status, "pending", "Enter should return to review")
	end)

	it("uses number 1 to select submission and waits for Enter", function()
		local calls = 0
		actions.reply_to_question = function()
			calls = calls + 1
		end

		add_question("question-confirm-yes", {
			{
				question = "Pick several",
				multiple = true,
				options = { { label = "A", value = "a" } },
			},
		})
		question_state.toggle_multi_select("question-confirm-yes", 1)
		question_state.mark_ready_to_advance("question-confirm-yes")
		question_state.set_confirming("question-confirm-yes")
		mount_question("question-confirm-yes")

		interactions.handle_question_number_select(1)
		assert_eq(calls, 0, "number 1 must only select submission")
		interactions.handle_question_confirm()
		assert_eq(calls, 1, "Enter should submit the selected confirmation")
	end)

	it("prevents duplicate replies and restores retry after failures including 404", function()
		local calls = {}
		actions.reply_to_question = function(request_id, answers, callback)
			table.insert(calls, { request_id = request_id, answers = answers, callback = callback })
		end

		add_question("question-retry", {
			{ question = "Retry?", options = { { label = "Yes", value = "yes" } } },
		})
		question_state.select_option("question-retry", 1)
		mount_question("question-retry")
		assert_true(chat_questions.submit_question_answers("question-retry"), "first submission should start")
		assert_true(not chat_questions.submit_question_answers("question-retry"), "duplicate submission should be ignored")
		assert_eq(#calls, 1, "only one HTTP reply should be in flight")
		assert_true(buffer_text():find("Submitting answer", 1, true) ~= nil, "in-flight reply should render submitting")
		local _, _, meta = question_widget.get_lines_for_question(
			"question-retry",
			{ questions = question_state.get_question("question-retry").questions },
			question_state.get_question("question-retry"),
			"pending"
		)
		assert_eq(meta.interactive_count, 0, "submitting state should be non-interactive")

		calls[1].callback({ status = 404, message = "QuestionNotFoundError: Question request not found" })
		wait_for(function()
			return not question_state.get_question("question-retry").submitting
		end, "failed reply should restore interaction")
		assert_eq(question_state.get_question("question-retry").status, "pending", "404 must not become cancellation")
		assert_true(not buffer_text():find("Cancelled", 1, true), "404 must not render cancelled")
		assert_true(#notifications > 0, "404 should notify the user")

		assert_true(chat_questions.submit_question_answers("question-retry"), "failed reply should be retryable")
		assert_eq(#calls, 2, "retry should issue a new HTTP reply")
	end)

	it("renders cancellation progress separately from answer submission", function()
		local callback
		actions.reject_question = function(_, _, cb)
			callback = cb
		end

		add_question("question-reject-render", {
			{ question = "Cancel?", options = { { label = "Yes", value = "yes" } } },
		})
		mount_question("question-reject-render")
		interactions.handle_question_cancel()

		local qstate = question_state.get_question("question-reject-render")
		assert_true(qstate.submitting, "reject should lock the question while in flight")
		assert_eq(qstate.submission_kind, "reject", "reject should record its in-flight kind")
		assert_true(buffer_text():find("Cancelling question", 1, true) ~= nil, "reject should render cancellation progress")
		assert_true(not buffer_text():find("Submitting answer", 1, true), "reject must not render answer submission text")
		assert_true(callback ~= nil, "reject should issue the HTTP request")
	end)

	it("restores reject interactivity after 404 and other errors without cancellation", function()
		local callbacks = {}
		actions.reject_question = function(_, _, callback)
			table.insert(callbacks, callback)
		end

		add_question("question-reject-retry", {
			{ question = "Cancel?", options = { { label = "Yes", value = "yes" } } },
		})
		mount_question("question-reject-retry")
		interactions.handle_question_cancel()
		callbacks[1]({ status = 404, message = "QuestionNotFoundError: Question request not found" })
		wait_for(function()
			return not question_state.get_question("question-reject-retry").submitting
		end, "reject 404 should restore interaction")
		local qstate = question_state.get_question("question-reject-retry")
		assert_eq(qstate.status, "pending", "reject 404 must remain pending")
		assert_eq(qstate.submission_kind, nil, "reject 404 should clear the in-flight kind")
		assert_true(not buffer_text():find("Cancelled", 1, true), "reject 404 must not render cancelled")
		assert_true(question_state.select_option("question-reject-retry", 1), "reject 404 should restore selection")

		mount_question("question-reject-retry")
		interactions.handle_question_cancel()
		callbacks[2]({ status = 500, message = "routing failed" })
		wait_for(function()
			return not question_state.get_question("question-reject-retry").submitting
		end, "reject error should restore interaction")
		qstate = question_state.get_question("question-reject-retry")
		assert_eq(qstate.status, "pending", "reject error must remain pending")
		assert_eq(qstate.submission_kind, nil, "reject error should clear the in-flight kind")
		assert_true(not buffer_text():find("Cancelled", 1, true), "reject error must not render cancelled")
	end)

	it("keeps the first explicit terminal result when callbacks and SSE arrive late", function()
		local callbacks = {}
		actions.reply_to_question = function(_, _, callback)
			table.insert(callbacks, callback)
		end
		local bus = require("opencode.events.bus")
		bus.clear()
		require("opencode.events.handlers.question").setup(bus)

		add_question("question-server-reject", {
			{ question = "Reject first?", options = { { label = "Yes", value = "yes" } } },
		})
		question_state.select_option("question-server-reject", 1)
		mount_question("question-server-reject")
		chat_questions.submit_question_answers("question-server-reject")
		bus.emit("question_rejected", { requestID = "question-server-reject" })
		wait_for(function()
			return question_state.get_question("question-server-reject").status == "rejected"
		end, "server rejection should win while reply is in flight")
		callbacks[1](nil, true)
		vim.wait(30)
		assert_eq(question_state.get_question("question-server-reject").status, "rejected", "late reply callback must not overwrite rejection")

		question_state.clear_all()
		add_question("question-answer-first", {
			{ question = "Answer first?", options = { { label = "Yes", value = "yes" } } },
		})
		question_state.select_option("question-answer-first", 1)
		mount_question("question-answer-first")
		chat_questions.submit_question_answers("question-answer-first")
		callbacks[2](nil, true)
		wait_for(function()
			return question_state.get_question("question-answer-first").status == "answered"
		end, "successful reply should resolve as answered")
		bus.emit("question_rejected", { requestID = "question-answer-first" })
		vim.wait(30)
		assert_eq(question_state.get_question("question-answer-first").status, "answered", "late rejection must not render cancellation")
	end)

	it("scopes question client and action requests to the owner directory", function()
		local http = require("opencode.client.http")
		local client = require("opencode.client")
		local original_post = http.post
		local original_get = http.get
		local posts = {}
		local gets = {}
		http.post = function(path, body, callback, opts)
			table.insert(posts, { path = path, body = body, callback = callback, opts = opts })
		end
		http.get = function(path, callback, opts)
			table.insert(gets, { path = path, callback = callback, opts = opts })
		end

		client.reply_to_question("question-client", { { "a" } }, { directory = "/tmp/question-client" }, function() end)
		client.reply_to_question("question-client-compat", { { "b" } }, function() end)
		client.list_questions({ directory = "/tmp/question-list" }, function() end)
		client.list_questions(function() end)
		client.reject_question("session", "question-reject", { directory = "/tmp/question-reject" }, function() end)
		client.reject_question("session", "question-reject-compat", function() end)

		http.post = original_post
		http.get = original_get
		assert_eq(posts[1].opts.headers["x-opencode-directory"], "/tmp/question-client", "reply should send directory header")
		assert_eq(posts[1].opts.query.directory, "/tmp/question-client", "reply should send directory query")
		assert_eq(posts[2].opts, nil, "callback-only reply should remain compatible")
		assert_eq(gets[1].opts.headers["x-opencode-directory"], "/tmp/question-list", "list should send directory header")
		assert_eq(gets[1].opts.query.directory, "/tmp/question-list", "list should send directory query")
		assert_eq(gets[2].opts, nil, "callback-only list should remain compatible")
		assert_eq(posts[3].opts.headers["x-opencode-directory"], "/tmp/question-reject", "reject should send directory header")
		assert_eq(posts[3].opts.query.directory, "/tmp/question-reject", "reject should send directory query")
		assert_eq(posts[4].opts, nil, "callback-only reject should remain compatible")

		add_question("question-action", {
			{ question = "Owner?", options = { { label = "Yes", value = "yes" } } },
		})
		local reply_opts
		local reject_opts
		local original_client_reply = client.reply_to_question
		local original_client_reject = client.reject_question
		client.reply_to_question = function(_, _, opts)
			reply_opts = opts
		end
		client.reject_question = function(_, _, opts)
			reject_opts = opts
		end
		actions.reply_to_question("question-action", { { "yes" } }, function() end)
		actions.reject_question("wrong-session", "question-action", function() end)
		client.reply_to_question = original_client_reply
		client.reject_question = original_client_reject

		local owner_directory = app_state.get_session_directory("question-session")
		assert_eq(reply_opts.directory, owner_directory, "reply action should use question owner directory")
		assert_eq(reject_opts.directory, owner_directory, "reject action should prefer question owner over fallback session")
	end)

	it("scopes missed-question recovery to the tool session directory", function()
		local bus = require("opencode.events.bus")
		local client = require("opencode.client")
		local original_list = client.list_questions
		local captured_opts
		local questions = {
			{ question = "Recovered?", options = { { label = "Yes", value = "yes" } } },
		}
		client.list_questions = function(opts, callback)
			captured_opts = opts
			callback(nil, {
				{
					id = "question-recovered",
					sessionID = "question-session",
					messageID = "message-recovered",
					callID = "call-recovered",
					questions = questions,
				},
			})
		end
		bus.clear()
		require("opencode.events.handlers.question").setup(bus)
		bus.emit("tool_update", {
			tool_name = "question",
			status = "running",
			session_id = "question-session",
			message_id = "message-recovered",
			call_id = "call-recovered",
			input = { questions = questions },
		})
		wait_for(function()
			return question_state.has_question("question-recovered")
		end, "question should recover from the scoped pending list")
		client.list_questions = original_list

		assert_eq(
			captured_opts.directory,
			app_state.get_session_directory("question-session"),
			"recovery list should use the tool session directory"
		)
	end)

	it("blocks the normal composer for pending, confirming, and submitting questions", function()
		add_question("question-composer", {
			{ question = "Answer first", options = { { label = "Yes", value = "yes" } } },
		})
		mount_question("question-composer")
		local chat = require("opencode.ui.chat")
		assert_true(not chat.focus_input(), "pending question should block the composer")
		assert_true(not input.is_visible(), "blocked composer should remain closed")

		assert_true(question_state.set_confirming("question-composer"), "question should enter confirmation")
		assert_true(not chat.focus_input(), "confirming question should block the composer")
		assert_true(question_state.begin_submission("question-composer"), "question should enter submitting state")
		assert_true(not chat.focus_input(), "submitting question should block the composer")
		assert_true(not input.is_visible(), "submitting question must not open the composer")
		assert_eq(#notifications, 3, "each blocked composer attempt should notify concisely")
	end)
end)
