local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state

local chat_tasks = require("opencode.ui.chat.tasks")
local chat_todos = require("opencode.ui.chat.todos")
local chat_questions = require("opencode.ui.chat.questions")
local chat_permissions = require("opencode.ui.chat.permissions")
local chat_edits = require("opencode.ui.chat.edits")

local question_state = require("opencode.question.state")
local permission_state = require("opencode.permission.state")
local edit_state = require("opencode.edit.state")
local actions = require("opencode.actions")

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

---@param kind "question" | "permission" | "edit"
---@param pos table|nil
---@return boolean
local function is_widget_cursor_target(kind, pos)
	if not pos then
		return false
	end

	if kind == "question" then
		return pos.status == "pending" or pos.status == "confirming"
	end
	if kind == "permission" then
		return pos.status == "pending"
	end
	return pos.status ~= "sent"
end

---@return number|nil min_line
---@return number|nil max_line
local function interactive_widget_bounds()
	local min_line = nil
	local max_line = nil
	local widget_kinds = { "question", "permission", "edit" }
	for _, kind in ipairs(widget_kinds) do
		local positions = kind == "question" and state.questions or kind == "permission" and state.permissions or state.edits
		for _, pos in pairs(positions) do
			if is_widget_cursor_target(kind, pos) then
				min_line = min_line and math.min(min_line, pos.start_line) or pos.start_line
				max_line = max_line and math.max(max_line, pos.end_line) or pos.end_line
			end
		end
	end
	return min_line, max_line
end

function M.sync_widget_selection_from_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end
	local min_line, max_line = interactive_widget_bounds()
	if not min_line or not max_line then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(state.winid)[1] - 1
	if cursor_line < min_line or cursor_line > max_line then
		return
	end
	chat_questions.sync_selected_option_from_cursor()
	chat_permissions.sync_selected_option_from_cursor()
	chat_edits.sync_selected_file_from_cursor()
end

---@param direction "up" | "down"
function M.handle_question_navigation(direction)
	local key = direction == "up" and "k" or "j"
	vim.cmd("normal! " .. key)

	M.sync_widget_selection_from_cursor()
end

---@param number number
function M.handle_question_number_select(number)
	local request_id = chat_questions.get_question_at_cursor()
	if request_id then
		local qstate = question_state.get_question(request_id)
		local current_question = qstate and qstate.questions and qstate.questions[qstate.current_tab]
		local changed
		if qstate and qstate.status ~= "confirming" and question_state.is_multi_question(current_question) then
			changed = question_state.toggle_multi_select(request_id, number)
		else
			changed = question_state.select_option(request_id, number)
		end
		if changed then
			emit("question_selection_changed", {
				request_id = request_id,
				tab_index = qstate and qstate.current_tab or nil,
				selected = question_state.get_current_selection(request_id),
			})
			emit("interaction_changed", {
				kind = "question",
				action = "selection_changed",
				id = request_id,
			})
		end
		chat_questions.rerender_question(request_id)
		return
	end

	local perm_id = chat_permissions.get_permission_at_cursor()
	if perm_id and number >= 1 and number <= 3 then
		if permission_state.select_option(perm_id, number) then
			emit("permission_selection_changed", {
				permission_id = perm_id,
				selected = number,
			})
			emit("interaction_changed", {
				kind = "permission",
				action = "selection_changed",
				id = perm_id,
			})
		end
		chat_permissions.rerender_permission(perm_id)
		return
	end

	local eid = chat_edits.get_edit_at_cursor()
	if eid then
		local estate = edit_state.get_edit(eid)
		if estate and number >= 1 and number <= #estate.files then
			edit_state.move_selection_to(eid, number)
			chat_edits.rerender_edit(eid)
		end
		return
	end

	vim.api.nvim_feedkeys(tostring(number), "n", false)
end

function M.handle_question_confirm()
	local todo_session_id = chat_todos.get_dock_at_cursor()
	if todo_session_id then
		chat_todos.toggle_dock(todo_session_id)
		return
	end

	local task_part_id = chat_tasks.get_task_at_cursor()
	if task_part_id then
		chat_tasks.handle_task_toggle(task_part_id)
		return
	end

	local request_id, qstate = chat_questions.get_question_at_cursor()
	if request_id then
		if qstate.status == "confirming" then
			local current_selection = question_state.get_current_selection(request_id)
			local choice = current_selection and current_selection[1] or 1
			if choice == 1 then
				chat_questions.submit_question_answers(request_id)
			else
				question_state.cancel_confirmation(request_id)
				emit("interaction_changed", {
					kind = "question",
					action = "confirmation_cancelled",
					id = request_id,
				})
				chat_questions.rerender_question(request_id)
			end
			return
		end

		local current_tab = qstate.current_tab
		local total_count = #qstate.questions
		local current_selection = qstate.selections[current_tab]
		local is_current_answered = current_selection and current_selection.is_answered

		if not is_current_answered then
			local _, total = question_state.get_answered_count(request_id)
			if total > 1 then
				local answered, _ = question_state.get_answered_count(request_id)
				vim.notify(
					string.format(
						"Question block: %d/%d answered. Please select an answer for this question.",
						answered,
						total
					),
					vim.log.levels.WARN
				)
			else
				vim.notify("Please select an answer before submitting.", vim.log.levels.WARN)
			end
			return
		end

		if not question_state.is_ready_to_advance(request_id) then
			question_state.mark_ready_to_advance(request_id)
			chat_questions.rerender_question(request_id)
			return
		end

		local all_answered, unanswered_indices = question_state.are_all_answered(request_id)
		if not all_answered then
			if #unanswered_indices > 0 then
				question_state.set_tab(request_id, unanswered_indices[1])
				emit("question_tab_changed", {
					request_id = request_id,
					tab_index = unanswered_indices[1],
				})
				chat_questions.rerender_question(request_id)
			end
			return
		end

		if total_count > 1 then
			question_state.set_confirming(request_id)
			emit("question_confirming", {
				request_id = request_id,
			})
			chat_questions.rerender_question(request_id)
		else
			chat_questions.submit_question_answers(request_id)
		end
		return
	end

	local perm_id, pstate = chat_permissions.get_permission_at_cursor()
	if perm_id and pstate then
		chat_permissions.handle_permission_confirm(perm_id, pstate)
		return
	end

	local eid = chat_edits.get_edit_at_cursor()
	if eid then
		if edit_state.is_readonly(eid) then
			chat_edits.handle_edit_accept_all()
			return
		end

		chat_edits.sync_selected_file_from_cursor()
		local file = edit_state.get_selected_file(eid)
		if file and file.filepath and file.filepath ~= "" then
			vim.cmd("edit " .. vim.fn.fnameescape(file.filepath))
		end
		return
	end

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
end

function M.handle_question_cancel()
	local request_id, qstate = chat_questions.get_question_at_cursor()
	if request_id then
		if qstate.status == "confirming" then
			question_state.cancel_confirmation(request_id)
			emit("interaction_changed", {
				kind = "question",
				action = "confirmation_cancelled",
				id = request_id,
			})
			chat_questions.rerender_question(request_id)
			return
		end

		local current_session = require("opencode.state").get_session()
		local session_id = qstate.session_id or current_session.id
		actions.reject_question(session_id, request_id, function(err)
			vim.schedule(function()
				if err then
					vim.notify("Failed to cancel question: " .. tostring(err), vim.log.levels.ERROR)
					return
				end
				question_state.mark_rejected(request_id)
				emit("interaction_changed", {
					kind = "question",
					action = "rejected",
					id = request_id,
				})
				chat_questions.update_question_status(request_id, "rejected")
			end)
		end)
		return
	end

	local perm_id = chat_permissions.get_permission_at_cursor()
	if perm_id then
		chat_permissions.handle_permission_reject(perm_id)
		return
	end

	local eid = chat_edits.get_edit_at_cursor()
	if eid then
		chat_edits.handle_edit_reject_all()
		return
	end

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end

function M.handle_question_next_tab()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
		return
	end
	chat_questions.handle_question_next_tab(request_id)
end

function M.handle_question_prev_tab()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "n", false)
		return
	end
	chat_questions.handle_question_prev_tab(request_id)
end

function M.handle_question_custom_input()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys("c", "n", false)
		return
	end
	chat_questions.handle_question_custom_input(request_id)
end

function M.handle_widget_message()
	local request_id = chat_questions.get_question_at_cursor()
	if request_id then
		chat_questions.handle_question_message(request_id)
		return
	end

	local perm_id = chat_permissions.get_permission_at_cursor()
	if perm_id then
		chat_permissions.handle_permission_message(perm_id)
		return
	end

	local edit_id = chat_edits.get_edit_at_cursor()
	if edit_id then
		chat_edits.handle_edit_message()
		return
	end

	vim.api.nvim_feedkeys("m", "n", false)
end

function M.handle_question_toggle()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>", true, false, true), "n", false)
		return
	end
	chat_questions.handle_question_toggle(request_id)
end

return M
