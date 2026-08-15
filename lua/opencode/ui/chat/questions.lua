-- Question widget lifecycle and handlers for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

local question_widget = require("opencode.ui.question_widget")
local widget_base = require("opencode.ui.widget_base")
local question_state = require("opencode.question.state")
local widget_support = require("opencode.ui.chat.widget_support")
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")
local events = require("opencode.events")

---@param question table|nil
---@return boolean
local function allows_custom_answer(question)
	if type(question) ~= "table" then
		return false
	end
	if question.custom ~= nil then
		return question.custom ~= false
	end
	if question.allow_custom ~= nil then
		return question.allow_custom == true
	end
	if question.allowCustom ~= nil then
		return question.allowCustom == true
	end
	return true
end

local function schedule_render()
	render_coordinator.request({ kind = "question" })
end

-- ─── Add / update ─────────────────────────────────────────────────────────────

---@param request_id string
---@param status "answered" | "rejected"
---@param answers? table
function M.update_question_status(request_id, status, answers)
	local logger = require("opencode.logger")

	logger.debug("update_question_status: triggering re-render", {
		request_id = request_id:sub(1, 10),
		status = status,
	})

	schedule_render()
end

-- ─── Cursor query ─────────────────────────────────────────────────────────────

---@return string|nil request_id
---@return table|nil qstate
---@return table|nil pos
---@return number|nil cursor_line
local function get_pending_question_context_at_cursor()
	local request_id, pos = widget_support.find_widget_context_at_cursor(state.questions, state.winid, function(pos)
		return pos.status == "pending" or pos.status == "confirming"
	end)
	if not request_id or not pos then
		return nil, nil, nil, nil
	end
	local qstate = question_state.get_question(request_id)
	if not qstate or not (qstate.status == "pending" or qstate.status == "confirming") then
		return nil, nil, nil, nil
	end
	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1
	return request_id, qstate, pos, cursor_line
end

---@param request_id string
---@return table|nil questions
local function get_question_payload(request_id)
	local qstate = question_state.get_question(request_id)
	return qstate and qstate.questions or nil
end

---@param request_id string
---@param qstate table
---@param pos table
---@param cursor_line number
---@return number|nil option_index
local function get_option_index_at_cursor(request_id, qstate, pos, cursor_line)
	local questions = get_question_payload(request_id)
	if not questions then
		return nil
	end

	local _, _, meta = question_widget.get_lines_for_question(request_id, { questions = questions }, qstate, qstate.status)
	local option_count = meta and meta.interactive_count or 0
	if qstate.status ~= "confirming" then
		local current_question = qstate.questions and qstate.questions[qstate.current_tab]
		option_count = current_question and #(current_question.options or {}) or 0
	end
	local first_option_line = widget_base.get_focus_offset(meta)
	if option_count <= 0 or first_option_line == nil then
		return nil
	end

	local widget_line = cursor_line - pos.start_line
	if widget_line < first_option_line or widget_line >= (first_option_line + option_count) then
		return nil
	end

	return widget_line - first_option_line + 1
end

---@return string|nil request_id
---@return table|nil question_state_data
function M.get_question_at_cursor()
	local request_id, qstate = get_pending_question_context_at_cursor()
	return request_id, qstate
end

---@return string|nil request_id
---@return boolean changed
function M.sync_selected_option_from_cursor()
	local request_id, qstate, pos, cursor_line = get_pending_question_context_at_cursor()
	if not request_id or not qstate or not pos or not cursor_line then
		return nil, false
	end
	if qstate.submitting then
		return request_id, false
	end

	local option_index = get_option_index_at_cursor(request_id, qstate, pos, cursor_line)
	if not option_index then
		return request_id, false
	end

	local current_question = qstate.questions and qstate.questions[qstate.current_tab]
	if qstate.status ~= "confirming" and question_state.is_multi_question(current_question) then
		return request_id, false
	end

	local current_selection = question_state.get_current_selection(request_id)
	local current_option = current_selection and current_selection[1] or nil
	if current_option == option_index then
		return request_id, false
	end

	if not question_state.select_option(request_id, option_index) then
		return request_id, false
	end

	events.safe_emit("question_selection_changed", {
		request_id = request_id,
		tab_index = qstate.current_tab,
		selected = { option_index },
	})
	events.safe_emit("interaction_changed", {
		kind = "question",
		action = "selection_changed",
		id = request_id,
	})
	M.rerender_question(request_id)
	return request_id, true
end

-- ─── In-place re-render ───────────────────────────────────────────────────────

---@param request_id string
function M.rerender_question(request_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.questions[request_id]
	if not pos then
		return
	end

	local qstate = question_state.get_question(request_id)
	if not qstate then
		return
	end

	local questions = get_question_payload(request_id)
	if not questions then
		return
	end

	local status = qstate.status or "pending"
	local lines, highlights
	if status == "answered" then
		lines, highlights = question_widget.get_answered_lines(
			request_id,
			{ questions = questions, timestamp = qstate.timestamp },
			qstate.answers
		)
	elseif status == "rejected" then
		lines, highlights = question_widget.get_rejected_lines(request_id, {
			questions = questions,
			timestamp = qstate.timestamp,
		})
	else
		lines, highlights = question_widget.get_lines_for_question(request_id, { questions = questions }, qstate, status)
	end

	if widget_support.replace_rendered_block(pos, { lines = lines, highlights = highlights }) then
		pos.status = status
	end
end

-- ─── Submit ───────────────────────────────────────────────────────────────────

-- Detect a tagged "question not found" response so the retryable failure can
-- be explained without treating it as a user cancellation.
---@param err table|nil
---@return boolean
function M.is_question_not_found_error(err)
	if type(err) ~= "table" then
		return false
	end
	local body = err.error or err.message or ""
	if type(body) ~= "string" then
		body = tostring(body)
	end
	local lower = body:lower()
	local has_tag = lower:find("questionnotfound") ~= nil or lower:find("question request not found") ~= nil
	-- Require the QuestionNotFoundError tag/message in the body, not just a
	-- bare 404, so proxy/gateway 404s don't silently discard a valid question.
	return has_tag and err.status == 404
end

---@param request_id string
function M.submit_question_answers(request_id)
	if not question_state.begin_submission(request_id, "reply") then
		return false
	end
	local answers = question_state.get_answers(request_id)
	M.rerender_question(request_id)

	actions.reply_to_question(request_id, answers, function(err)
		vim.schedule(function()
			if err then
				if not question_state.restore_submission(request_id) then
					return
				end
				M.rerender_question(request_id)
				if M.is_question_not_found_error(err) then
					vim.notify(
						"Question reply was not accepted by the server. You can retry.",
						vim.log.levels.WARN
					)
					return
				end
				vim.notify("Failed to submit answer: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end
			if not question_state.mark_answered(request_id, answers) then
				return
			end
			events.safe_emit("question_answered", {
				request_id = request_id,
				answers = answers,
			})
			events.safe_emit("interaction_changed", {
				kind = "question",
				action = "answered",
				id = request_id,
			})
			M.update_question_status(request_id, "answered", answers)
		end)
	end)
	return true
end

-- ─── Per-question handlers ────────────────────────────────────────────────────

---@param request_id string
function M.handle_question_next_tab(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" or qstate.submitting then
		return
	end

	local next_tab = qstate.current_tab + 1
	if next_tab > #qstate.questions then
		next_tab = 1
	end

	question_state.set_tab(request_id, next_tab)
	events.safe_emit("question_tab_changed", {
		request_id = request_id,
		tab_index = next_tab,
	})
	M.rerender_question(request_id)
end

---@param request_id string
function M.handle_question_prev_tab(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" or qstate.submitting then
		return
	end

	local prev_tab = qstate.current_tab - 1
	if prev_tab < 1 then
		prev_tab = #qstate.questions
	end

	question_state.set_tab(request_id, prev_tab)
	events.safe_emit("question_tab_changed", {
		request_id = request_id,
		tab_index = prev_tab,
	})
	M.rerender_question(request_id)
end

---@param request_id string
function M.handle_question_custom_input(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" or qstate.submitting then
		return
	end

	local current_tab = qstate.current_tab
	local question = qstate.questions[current_tab]
	local selection = qstate.selections[current_tab] or {}

	if not allows_custom_answer(question) then
		vim.notify("Custom input not allowed for this question", vim.log.levels.WARN)
		return
	end

	local input_ui = require("opencode.ui.input")
	input_ui.show({
		winid = state.winid,
		float_dims = state.float_dims,
		text = selection.custom_input or "",
		persist_pending = false,
		add_history = false,
		on_send = function(text)
			if text and text ~= "" then
				question_state.set_custom_input(request_id, current_tab, text)
				if not question_state.is_multi_question(question) then
					question_state.update_selection(request_id, current_tab, {})
				end
				if #qstate.questions == 1 and not question_state.is_multi_question(question) then
					M.submit_question_answers(request_id)
				else
					M.rerender_question(request_id)
				end
				require("opencode.ui.chat").focus()
			end
		end,
		on_cancel = function()
			require("opencode.ui.chat").focus()
		end,
	})
end

---@param request_id string
function M.handle_question_message(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" or qstate.submitting then
		return
	end

	local current_tab = qstate.current_tab
	local selection = qstate.selections[current_tab] or {}
	local input_ui = require("opencode.ui.input")
	local chat = require("opencode.ui.chat")

	local function finish(text)
		question_state.set_message(request_id, current_tab, text or "")
		M.rerender_question(request_id)
		chat.focus()
	end

	input_ui.show({
		winid = state.winid,
		float_dims = state.float_dims,
		text = selection.message or "",
		persist_pending = false,
		add_history = false,
		on_send = finish,
		on_cancel = finish,
	})
end

---@param request_id string
function M.handle_question_toggle(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" or qstate.submitting then
		return
	end

	local current_tab = qstate.current_tab
	local question = qstate.questions[current_tab]

	if not question_state.is_multi_question(question) then
		vim.notify("Use 1-9 to select an option (Space is for multi-select only)", vim.log.levels.INFO)
		return
	end

	local option_index
	local cursor_request_id, cursor_qstate, pos, cursor_line = get_pending_question_context_at_cursor()
	if cursor_request_id == request_id and cursor_qstate and pos and cursor_line then
		option_index = get_option_index_at_cursor(request_id, cursor_qstate, pos, cursor_line)
	end

	local current_selection = question_state.get_current_selection(request_id)
	local current_idx = option_index or (current_selection and current_selection[1]) or 1
	question_state.toggle_multi_select(request_id, current_idx)
	events.safe_emit("question_selection_changed", {
		request_id = request_id,
		tab_index = qstate.current_tab,
		selected = question_state.get_current_selection(request_id),
	})
	events.safe_emit("interaction_changed", {
		kind = "question",
		action = "selection_changed",
		id = request_id,
	})
	M.rerender_question(request_id)
end

-- ─── Misc ─────────────────────────────────────────────────────────────────────

function M.clear_questions()
	state.questions = {}
end

function M.debug_questions()
	local logger = require("opencode.logger")
	local all_questions = question_state.get_all_active()

	logger.info("Active questions", {
		count = question_state.get_question_count(),
		active = #all_questions,
		tracked = vim.tbl_count(state.questions),
	})

	for request_id, pos in pairs(state.questions) do
		local qstate = question_state.get_question(request_id)
		if qstate then
			logger.debug("Question details", {
				request_id = request_id:sub(1, 10),
				status = qstate.status,
				current_tab = qstate.current_tab,
				question_count = #qstate.questions,
				selections = qstate.selections,
				start_line = pos.start_line,
				end_line = pos.end_line,
			})
		end
	end

	vim.notify(string.format("Debug: %d active questions logged", #all_questions), vim.log.levels.INFO)
end

---@return number
function M.get_pending_question_count()
	return #question_state.get_all_active()
end

---@return boolean
function M.has_pending_questions()
	return #question_state.get_all_active() > 0
end

return M
