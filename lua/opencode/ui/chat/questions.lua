local cs = require("opencode.ui.chat.state")
return cs.factory("questions", function(view)
-- Question widget lifecycle and handlers for the chat buffer.

local M = {}

local state = view
local render = cs.module(view, require("opencode.ui.chat.render"))

local question_widget = require("opencode.ui.question_widget")
local widget_base = require("opencode.ui.widget_base")
local question_state = require("opencode.question.state")
local pending = require("opencode.session.pending")
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local actions = require("opencode.actions")
local events = require("opencode.events")
local form_external = require("opencode.ui.form_external")

---@param question table|nil
---@return boolean
local function allows_custom_answer(question)
	return type(question) == "table" and question.custom == true
end

local function schedule_render()
	render_coordinator.request({ kind = "question" })
end

local function selection_changed(request_id, focus)
	local qstate = question_state.get_question(request_id)
	events.safe_emit("question_selection_changed", {
		request_id = request_id,
		tab_index = qstate.current_tab,
		selected = question_state.get_current_selection(request_id),
	})
	events.safe_emit("interaction_changed", { kind = "question", action = "selection_changed", id = request_id })
	M.rerender_question(request_id, focus)
end

local function external_question(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status ~= "pending" or qstate.submitting then return nil, nil end
	local question = qstate.questions[qstate.current_tab]
	if not question or question.field_type ~= "external" then return nil, nil end
	return qstate, question
end

local function mark_external_ready(request_id, question)
	if not question_state.mark_external_ready(request_id, question.key) then return end
	events.safe_emit("interaction_changed", { kind = "question", action = "selection_changed", id = request_id })
	M.rerender_question(request_id)
end

function M.handle_question_external_confirm(request_id)
	local qstate, question = external_question(request_id)
	if not question then return end
	local selection = qstate.form_selections[question.key]
	if not selection.external_ready then
		if not form_external.open(question.url) then return end
		mark_external_ready(request_id, question)
		return
	end
	if not selection.is_answered then
		if not question_state.acknowledge_external(request_id, question.key) then return end
		events.safe_emit("interaction_changed", { kind = "question", action = "selection_changed", id = request_id })
	end
	M.advance_question(request_id)
end

-- Visit each visible question before opening the final submission confirmation.
function M.advance_question(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status ~= "pending" or qstate.submitting then return end
	if qstate.current_tab < #qstate.questions then
		question_state.set_tab(request_id, qstate.current_tab + 1)
	else
		local valid, invalid = question_state.are_all_answered(request_id)
		if valid then question_state.set_confirming(request_id)
		elseif #invalid > 0 then question_state.set_tab(request_id, invalid[1]) end
	end
	events.safe_emit(qstate.status == "confirming" and "question_confirming" or "question_tab_changed", {
		request_id = request_id,
		tab_index = qstate.current_tab,
	})
	M.rerender_question(request_id, true)
end

function M.cancel_confirmation(request_id)
	if not question_state.cancel_confirmation(request_id) then return false end
	events.safe_emit("interaction_changed", { kind = "question", action = "confirmation_cancelled", id = request_id })
	M.rerender_question(request_id, true)
	return true
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
---@param qstate table
---@param pos table
---@param cursor_line number
---@return number|nil option_index Zero identifies the saved custom answer.
local function get_option_index_at_cursor(request_id, qstate, pos, cursor_line)
	local meta = widget_support.get_interactive_meta(pos, qstate, "question")
	if not pos.meta_state then
		-- Compatibility for callers supplying a position without rendered metadata.
		local _, _, fallback = question_widget.get_lines_for_question(request_id, { questions = qstate.questions }, qstate, qstate.status, { width = render.get_chat_text_width(), render = render })
		meta = fallback
	end
	return widget_base.get_option_index(meta, cursor_line - pos.start_line)
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
	local selection = qstate.selections[qstate.current_tab]
	local current_option = selection and selection.custom_present and 0 or current_selection and current_selection[1]
	if current_option == option_index then
		return request_id, false
	end

	if not question_state.select_option(request_id, option_index) then
		return request_id, false
	end

	selection_changed(request_id)
	return request_id, true
end

-- ─── In-place re-render ───────────────────────────────────────────────────────

---@param request_id string
---@param focus? boolean|number Focus the current answer or a specific option.
function M.rerender_question(request_id, focus)
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

	local questions = qstate.questions
	local status = qstate.status or "pending"
	local lines, highlights, meta = question_widget.get_lines_for_question(
		request_id, { questions = questions, timestamp = qstate.timestamp }, qstate, status, { width = render.get_chat_text_width(), render = render }
	)

	if widget_support.replace_rendered_block(pos, { lines = lines, highlights = highlights }) then
		pos.status = status
		widget_support.set_interactive_meta(pos, meta, qstate, "question")
	elseif focus then
		-- A queued render can replace the position map; focus its fresh block.
		widget_support.request_focus("question", request_id)
		state.focus_question_option = focus
		cs.module(view, require("opencode.ui.chat")).do_render()
		pos = state.questions[request_id]
	end
	if focus and pos and (status == "pending" or status == "confirming") and cs.is_chat_buffer_displayed(view) then
		local offset = question_widget.get_selection_focus_offset(meta, qstate.selections[qstate.current_tab], focus)
		vim.api.nvim_win_set_cursor(state.winid, { pos.start_line + offset + 1, 0 })
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
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status ~= "confirming" then return false end
	if not question_state.begin_submission(request_id, "reply") then
		M.rerender_question(request_id)
		return false
	end
	local token = pending.token(qstate.session_id)
	local answers = question_state.get_answers(request_id)
	M.rerender_question(request_id)

	actions.reply_to_question(request_id, answers, function(err)
		vim.schedule(function()
			if not pending.is_current(token) or question_state.get_question(request_id) ~= qstate then return end
			if err then
				if not question_state.restore_submission(request_id) then
					return
				end
				question_state.set_form_error(request_id, err)
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

local function cycle_question_tab(request_id, direction)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status ~= "pending" or qstate.submitting or #qstate.questions == 0 then
		return
	end

	local tab = (qstate.current_tab - 1 + direction) % #qstate.questions + 1
	question_state.set_tab(request_id, tab)
	events.safe_emit("question_tab_changed", {
		request_id = request_id,
		tab_index = tab,
	})
	M.rerender_question(request_id, true)
end

---@param request_id string
function M.handle_question_next_tab(request_id)
	cycle_question_tab(request_id, 1)
end

---@param request_id string
function M.handle_question_prev_tab(request_id)
	cycle_question_tab(request_id, -1)
end

---@param request_id string
---@param number number
function M.handle_question_number_select(request_id, number)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.submitting then return end
	local question = qstate.questions[qstate.current_tab]
	local select = qstate.status ~= "confirming" and question_state.is_multi_question(question)
		and question_state.toggle_multi_select or question_state.select_option
	if select(request_id, number) then
		selection_changed(request_id, number)
	else
		M.rerender_question(request_id)
	end
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

	if question.field_type == "external" then
		if not form_external.copy(question.url) then return end
		mark_external_ready(request_id, question)
		return
	end
	if not allows_custom_answer(question) then
		vim.notify("Custom input not allowed for this question", vim.log.levels.WARN)
		return
	end

	local input_ui = require("opencode.ui.input")
	local token = pending.token(qstate.session_id)
	local generation = view.generation
	input_ui.show({
		view = view,
		winid = state.winid,
		float_dims = state.float_dims,
		text = selection.custom_input or "",
		persist_pending = false,
		add_history = false,
		on_send = function(text)
			if not cs.valid(view, generation) or not pending.is_current(token) or question_state.get_question(request_id) ~= qstate or qstate.status ~= "pending" or qstate.submitting then return end
			if text ~= nil then
				question_state.set_custom_input(request_id, current_tab, text)
				M.rerender_question(request_id, true)
				cs.module(view, require("opencode.ui.chat")).focus()
			end
		end,
		on_cancel = function()
			if not cs.valid(view, generation) or not pending.is_current(token) or question_state.get_question(request_id) ~= qstate then return end
			cs.module(view, require("opencode.ui.chat")).focus()
		end,
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
		local keymaps = require("opencode.util.keymap")
		local keys = (state.config or {}).keymaps
		vim.notify("Use " .. keymaps.number_labels("chat", 1, 9, keys)
			.. " to select an option (" .. keymaps.label("chat", "toggle_selection", keys) .. " is for multi-select only)", vim.log.levels.INFO)
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
	selection_changed(request_id)
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

end)
