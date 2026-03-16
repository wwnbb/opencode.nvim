-- Question widget lifecycle and handlers for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

local question_widget = require("opencode.ui.question_widget")
local widget_base = require("opencode.ui.widget_base")
local question_state = require("opencode.question.state")
local widget_support = require("opencode.ui.chat.widget_support")

local function schedule_render()
	require("opencode.ui.chat").schedule_render()
end

-- ─── Pending queue ────────────────────────────────────────────────────────────

function M.process_pending_questions()
	if #state.pending_questions == 0 then
		return
	end

	local logger = require("opencode.logger")
	logger.debug("Processing pending questions", { count = #state.pending_questions })

	local pending = state.pending_questions
	state.pending_questions = {}

	for _, pq in ipairs(pending) do
		local qstate = question_state.get_question(pq.request_id)
		if qstate and qstate.status == "pending" then
			M.add_question_message(pq.request_id, pq.questions, pq.status)
			logger.debug("Displayed pending question", { request_id = pq.request_id:sub(1, 10) })
		else
			logger.debug("Skipping stale pending question", {
				request_id = pq.request_id:sub(1, 10),
				reason = qstate and qstate.status or "not found",
			})
		end
	end
end

-- ─── Add / update ─────────────────────────────────────────────────────────────

---@param request_id string
---@param questions table
---@param status "pending" | "answered" | "rejected"
function M.add_question_message(request_id, questions, status)
	local logger = require("opencode.logger")

	logger.debug("add_question_message called", {
		request_id = request_id:sub(1, 10),
		has_bufnr = state.bufnr ~= nil,
		bufnr_valid = state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr),
		visible = state.visible,
	})

	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not state.visible then
		table.insert(state.pending_questions, {
			request_id = request_id,
			questions = questions,
			status = status,
			timestamp = os.time(),
		})
		logger.debug("Question queued (chat not visible)", {
			request_id = request_id:sub(1, 10),
			pending_count = #state.pending_questions,
		})
		return
	end

	local qstate = question_state.get_question(request_id)
	if not qstate then
		logger.warn("Question state not found", { request_id = request_id:sub(1, 10) })
		return
	end

	local already_exists = false
	for _, msg in ipairs(state.messages) do
		if msg.type == "question" and msg.request_id == request_id then
			already_exists = true
			msg.status = status
			break
		end
	end

	if not already_exists then
		table.insert(state.messages, {
			role = "system",
			type = "question",
			request_id = request_id,
			questions = questions,
			status = status,
			timestamp = os.time(),
			id = "question_" .. request_id,
			source_session_id = qstate.session_id,
		})
		logger.debug("Question added to state.messages", {
			request_id = request_id:sub(1, 10),
			status = status,
		})
	else
		logger.debug("Question already in state.messages, updated status", {
			request_id = request_id:sub(1, 10),
			status = status,
		})
	end

	widget_support.request_focus("question", request_id, status)

	schedule_render()

	logger.debug("Question render scheduled", { request_id = request_id:sub(1, 10) })
end

---@param request_id string
---@param status "answered" | "rejected"
---@param answers? table
function M.update_question_status(request_id, status, answers)
	local logger = require("opencode.logger")

	local found = false
	for _, msg in ipairs(state.messages) do
		if msg.type == "question" and msg.request_id == request_id then
			msg.status = status
			msg.answers = answers
			found = true
			break
		end
	end

	if not found then
		logger.debug("update_question_status: question not found in state.messages", {
			request_id = request_id:sub(1, 10),
		})
		return
	end

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
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil, nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1

	for request_id, pos in pairs(state.questions) do
		if
			cursor_line >= pos.start_line
			and cursor_line <= pos.end_line
			and (pos.status == "pending" or pos.status == "confirming")
		then
			local qstate = question_state.get_question(request_id)
			if qstate and (qstate.status == "pending" or qstate.status == "confirming") then
				return request_id, qstate, pos, cursor_line
			end
		end
	end

	return nil, nil, nil, nil
end

---@param request_id string
---@return table|nil questions
local function get_question_payload(request_id)
	for _, msg in ipairs(state.messages) do
		if msg.type == "question" and msg.request_id == request_id then
			return msg.questions
		end
	end

	return nil
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

	local questions = get_question_payload(request_id)
	if not questions then
		return request_id, false
	end

	local _, _, meta = question_widget.get_lines_for_question(request_id, { questions = questions }, qstate, qstate.status)
	local option_count = meta and meta.interactive_count or 0
	local first_option_line = widget_base.get_focus_offset(meta)
	if option_count <= 0 or first_option_line == nil then
		return request_id, false
	end

	local widget_line = cursor_line - pos.start_line
	if widget_line < first_option_line or widget_line >= (first_option_line + option_count) then
		return request_id, false
	end

	local option_index = widget_line - first_option_line + 1
	local current_selection = question_state.get_current_selection(request_id)
	local current_option = current_selection and current_selection[1] or nil
	if current_option == option_index then
		return request_id, false
	end

	if not question_state.select_option(request_id, option_index) then
		return request_id, false
	end

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

	local lines, highlights, _ =
		question_widget.get_lines_for_question(request_id, { questions = questions }, qstate, qstate.status)

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, lines)

	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + #lines)
	for _, hl in ipairs(highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(
			state.bufnr,
			chat_hl_ns,
			pos.start_line + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	state.questions[request_id].end_line = pos.start_line + #lines - 1
	state.questions[request_id].status = qstate.status
end

-- ─── Submit ───────────────────────────────────────────────────────────────────

---@param request_id string
function M.submit_question_answers(request_id)
	local answers = question_state.get_answers(request_id)

	local client = require("opencode.client")
	local qstate = question_state.get_question(request_id)
	local session_id = (qstate and qstate.session_id) or require("opencode.state").get_session().id

	client.reply_to_question(session_id, request_id, answers, function(err, success)
		vim.schedule(function()
			if err then
				vim.notify("Failed to submit answer: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end
			question_state.mark_answered(request_id, answers)
			M.update_question_status(request_id, "answered", answers)
		end)
	end)
end

-- ─── Per-question handlers ────────────────────────────────────────────────────

---@param request_id string
function M.handle_question_next_tab(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" then
		return
	end

	local next_tab = qstate.current_tab + 1
	if next_tab > #qstate.questions then
		next_tab = 1
	end

	question_state.set_tab(request_id, next_tab)
	M.rerender_question(request_id)
end

---@param request_id string
function M.handle_question_prev_tab(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" then
		return
	end

	local prev_tab = qstate.current_tab - 1
	if prev_tab < 1 then
		prev_tab = #qstate.questions
	end

	question_state.set_tab(request_id, prev_tab)
	M.rerender_question(request_id)
end

---@param request_id string
function M.handle_question_custom_input(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" then
		return
	end

	local current_tab = qstate.current_tab
	local question = qstate.questions[current_tab]

	if not question.allow_custom and not question.allowCustom then
		vim.notify("Custom input not allowed for this question", vim.log.levels.WARN)
		return
	end

	local input_ui = require("opencode.ui.input")
	input_ui.show({
		winid = state.winid,
		float_dims = state.float_dims,
		on_send = function(text)
			if text and text ~= "" then
				question_state.set_custom_input(request_id, current_tab, text)
				if question.type ~= "multi" then
					question_state.update_selection(request_id, current_tab, {})
				end
				M.rerender_question(request_id)
				require("opencode.ui.chat").focus()
			end
		end,
		on_cancel = function()
			require("opencode.ui.chat").focus()
		end,
	})
end

---@param request_id string
function M.handle_question_toggle(request_id)
	local qstate = question_state.get_question(request_id)
	if not qstate or qstate.status == "confirming" then
		return
	end

	local current_tab = qstate.current_tab
	local question = qstate.questions[current_tab]

	if question.type ~= "multi" then
		vim.notify("Use 1-9 to select an option (Space is for multi-select only)", vim.log.levels.INFO)
		return
	end

	local current_selection = question_state.get_current_selection(request_id)
	local current_idx = current_selection and current_selection[1] or 1
	question_state.toggle_multi_select(request_id, current_idx)
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
	return #state.pending_questions
end

---@return boolean
function M.has_pending_questions()
	return #state.pending_questions > 0
end

return M
