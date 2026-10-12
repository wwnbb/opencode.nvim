-- Native v2 form state and widget navigation.

local M = {}
local forms = require("opencode.question.forms")
local pending = require("opencode.session.pending")

local active_questions = {}
local generation = 0

---Recovery generation, incremented when transient question state is reset.
function M.get_generation()
	return generation
end

---@param question table|nil
---@return boolean
local function is_multi_question(question)
	return type(question) == "table" and question.multiple == true
end

M.is_multi_question = is_multi_question

---@param qstate table|nil
---@return boolean
local function can_interact(qstate)
	return qstate ~= nil
		and not qstate.submitting
		and qstate.status ~= "answered"
		and qstate.status ~= "rejected"
end

local function new_form_state(form, context)
	local tool = type(form.metadata) == "table" and form.metadata.tool or nil
	local qstate = {
		request_id = form.id,
		session_id = form.sessionID,
		message_id = type(tool) == "table" and tool.messageID or nil,
		call_id = type(tool) == "table" and (tool.id or tool.callID) or nil,
		questions = {},
		current_tab = 1,
		selections = {},
		status = "pending",
		submitting = false,
		timestamp = context and context.timestamp or os.time(),
	}
	forms.init(qstate, form, context)
	active_questions[form.id] = qstate
	return qstate
end

local function sync_draft(qstate)
	if qstate.status ~= "confirming" then
		forms.pull(qstate)
		forms.rebuild(qstate)
		qstate.server_error = nil
		qstate.field_errors = {}
	end
	return true
end

-- Opening or copying a link only makes an external step ready. The user must
-- explicitly acknowledge completion before it becomes a typed form answer.
function M.mark_external_ready(request_id, key)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) or qstate.status ~= "pending" then return false end
	if not forms.mark_external_ready(qstate, key) then return false end
	qstate.server_error = nil
	qstate.field_errors = {}
	return true
end

function M.acknowledge_external(request_id, key)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) or qstate.status ~= "pending" then return false end
	if not forms.acknowledge_external(qstate, key) then return false end
	return sync_draft(qstate)
end

---@param request_id string
---@return table|nil
function M.get_question(request_id)
	return active_questions[request_id]
end

---@return table Array of question states
function M.get_all_active()
	local result = {}
	for _, qstate in pairs(active_questions) do
		if qstate.status == "pending" or qstate.status == "confirming" then
			table.insert(result, qstate)
		end
	end
	return result
end

---@return table Array of question states sorted by timestamp
function M.get_all()
	local result = {}
	for _, qstate in pairs(active_questions) do
		table.insert(result, qstate)
	end
	table.sort(result, function(a, b) return a.timestamp < b.timestamp end)
	return result
end

---@param request_id string
---@param tab_index number
---@param selected_indices table Array of selected option indices
function M.update_selection(request_id, tab_index, selected_indices)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) then
		return false
	end

	local selection = qstate.selections[tab_index]
	if not selection then
		return false
	end

	selection.selected_indices = selected_indices
	if is_multi_question(qstate.questions[tab_index]) then
		selection.is_answered = #selected_indices > 0 or selection.custom_present == true
	elseif #selected_indices > 0 then
		selection.custom_present = false
		selection.is_answered = true
	end
	return sync_draft(qstate)
end

---@param request_id string
---@param tab_index number
---@param text string Custom input text
function M.set_custom_input(request_id, tab_index, text)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) then
		return false
	end

	if not forms.set_custom_input(qstate, tab_index, text) then return false end
	return sync_draft(qstate)
end

---@param request_id string
---@param option_index number 1-based option index; 0 selects the saved custom answer.
function M.select_option(request_id, option_index)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) then
		return false
	end

	local tab_index = qstate.current_tab
	if not qstate.selections[tab_index] then
		return false
	end

	if qstate.status == "confirming" then
		if option_index < 1 or option_index > 2 then
			return false
		end
		qstate.selections[tab_index].selected_indices = { option_index }
		return true
	end

	local question = qstate.questions[tab_index]
	if not question then
		return false
	end
	if question.field_type == "external" then return false end
	local selection = qstate.selections[tab_index]
	if option_index == 0 then
		if not question.custom or not selection.custom_input or selection.custom_input == "" then return false end
		return M.set_custom_input(request_id, tab_index, selection.custom_input)
	end

	if option_index < 1 or option_index > #(question.options or {}) then
		return false
	end

	selection.selected_indices = { option_index }
	if not is_multi_question(question) then selection.custom_present = false end
	selection.is_answered = true

	return sync_draft(qstate)
end

---@param request_id string
---@param option_index number 1-based option index; 0 toggles the saved custom answer.
function M.toggle_multi_select(request_id, option_index)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) then
		return false
	end

	local tab_index = qstate.current_tab
	local question = qstate.questions[tab_index]
	if not is_multi_question(question) or option_index < 0 or option_index > #(question.options or {}) then
		return false
	end
	local selection = qstate.selections[tab_index]
	if not selection then
		return false
	end

	local selected = selection.selected_indices
	if option_index == 0 then
		if not question.custom or not selection.custom_input or selection.custom_input == "" then return false end
		selection.custom_present = not selection.custom_present
	else
		local index = vim.fn.index(selected, option_index) + 1
		if index > 0 then table.remove(selected, index)
		else table.insert(selected, option_index) end
	end

	selection.is_answered = #selected > 0 or selection.custom_present == true

	return sync_draft(qstate)
end

---@param request_id string
---@return table|nil Selected indices array
function M.get_current_selection(request_id)
	local qstate = active_questions[request_id]
	if not qstate then
		return nil
	end

	local tab_index = qstate.current_tab
	if not qstate.selections[tab_index] then
		return nil
	end

	return qstate.selections[tab_index].selected_indices
end

---@param request_id string
---@param tab_index number
function M.set_tab(request_id, tab_index)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) then
		return false
	end

	if tab_index < 1 or tab_index > #qstate.questions then
		return false
	end

	qstate.current_tab = tab_index

	return true
end

---@param request_id string
---@return boolean all_answered
---@return number[] unanswered_indices Array of unanswered question indices
function M.are_all_answered(request_id)
	local qstate = active_questions[request_id]
	if not qstate then
		return false, {}
	end
	local valid, errors = forms.validate(qstate)
	local indices = {}
	for index, question in ipairs(qstate.questions) do
		if errors[question.key] then indices[#indices + 1] = index end
	end
	return valid, indices
end

---@param request_id string
---@return number answered_count
---@return number total_count
function M.get_answered_count(request_id)
	local qstate = active_questions[request_id]
	if not qstate then
		return 0, 0
	end

	local answered = 0
	for i = 1, #qstate.questions do
		local selection = qstate.selections[i]
		if selection and selection.is_answered then
			answered = answered + 1
		end
	end

	return answered, #qstate.questions
end

---@param request_id string
function M.set_confirming(request_id)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) or qstate.status ~= "pending" then
		return false
	end

	qstate.last_tab_before_confirm = qstate.current_tab
	qstate.status = "confirming"

	-- Confirmation uses a temporary tab: 1 = Yes, 2 = No.
	local temp_tab_idx = #qstate.questions + 1
	qstate.selections[temp_tab_idx] = {
		selected_indices = { 1 },
		custom_input = "",
		is_answered = true,
	}
	qstate.current_tab = temp_tab_idx

	return true
end

---@param request_id string
function M.cancel_confirmation(request_id)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) or qstate.status ~= "confirming" then
		return false
	end

	qstate.status = "pending"

	local temp_tab_idx = #qstate.questions + 1
	qstate.selections[temp_tab_idx] = nil

	local return_tab = qstate.last_tab_before_confirm or #qstate.questions
	qstate.current_tab = return_tab
	qstate.last_tab_before_confirm = nil

	return true
end

---@param request_id string
---@return table<string, any>|nil Answers indexed by field key
function M.get_answers(request_id)
	local qstate = active_questions[request_id]
	if not qstate then
		return nil
	end
	return forms.answer(qstate)
end

function M.validate_form(request_id)
	local qstate = active_questions[request_id]
	if not qstate then return false end
	return forms.validate(qstate)
end

-- Lock a question while its reply or rejection request is in flight.
---@param request_id string
---@param kind? "reply"|"reject"
---@return boolean
function M.begin_submission(request_id, kind)
	local qstate = active_questions[request_id]
	if not can_interact(qstate) then
		return false
	end
	if kind ~= "reject" and not M.validate_form(request_id) then return false end

	qstate.submitting = true
	qstate.submission_token = pending.token(qstate.session_id)
	qstate.submission_kind = kind == "reject" and "reject" or "reply"
	return true
end

-- Restore the current pending/confirmation view after an HTTP failure.
---@param request_id string
---@return boolean
function M.restore_submission(request_id)
	local qstate = active_questions[request_id]
	if not qstate or not qstate.submitting or qstate.status == "answered" or qstate.status == "rejected" then
		return false
	end

	qstate.submitting = false
	qstate.submission_token = nil
	qstate.submission_kind = nil
	return true
end

---@param request_id string
---@param answers? table<string, any> Answers indexed by field key
function M.mark_answered(request_id, answers)
	local qstate = active_questions[request_id]
	if not qstate or qstate.status == "answered" or qstate.status == "rejected" then
		return false
	end

	qstate.status = "answered"
	qstate.submitting = false
	qstate.submission_kind = nil
	qstate.answers = answers or M.get_answers(request_id)
	qstate.answered_at = os.time()
	forms.rebuild(qstate)
	qstate.display_answers = forms.display_answers(qstate, qstate.answers)

	return true
end

---@param request_id string
function M.mark_rejected(request_id)
	local qstate = active_questions[request_id]
	if not qstate or qstate.status == "answered" or qstate.status == "rejected" then
		return false
	end

	qstate.status = "rejected"
	qstate.submitting = false
	qstate.submission_kind = nil
	qstate.rejected_at = os.time()

	return true
end

---@param request_id string
function M.remove_question(request_id)
	if active_questions[request_id] then
		active_questions[request_id] = nil
		return true
	end
	return false
end

---@param request_id string
---@return boolean
function M.has_question(request_id)
	return active_questions[request_id] ~= nil
end

---@return number
function M.get_question_count()
	local count = 0
	for _ in pairs(active_questions) do
		count = count + 1
	end
	return count
end

---@param session_id string
function M.clear_session(session_id)
	local removed = {}
	for request_id, qstate in pairs(active_questions) do
		if qstate.session_id == session_id then
			table.insert(removed, request_id)
			active_questions[request_id] = nil
		end
	end
	return removed
end

function M.clear_all()
	generation = generation + 1
	local removed = {}
	for request_id, _ in pairs(active_questions) do
		table.insert(removed, request_id)
	end
	active_questions = {}
	return removed
end

-- Native forms share this owner and the established widget navigation. Drafts
-- are indexed by field key; the visible tab list is only a projection.
function M.add_form(form, context)
	local current = active_questions[form.id]
	if current then
		if current.submission_token and not pending.is_current(current.submission_token) then M.restore_submission(form.id) end
		return current
	end
	return new_form_state(form, context)
end

function M.set_form_error(id, err)
	local item = active_questions[id]
	if not item or item.status == "answered" or item.status == "rejected" then return end
	item.server_error = type(err) == "table" and err.message or tostring(err)
	M.restore_submission(id)
end

function M.apply_form_detail(detail)
	local item = M.add_form(detail)
	if detail.state.status == "answered" then M.mark_answered(detail.id, detail.state.answer)
	elseif detail.state.status == "cancelled" then M.mark_rejected(detail.id) end
	return item
end

return M
