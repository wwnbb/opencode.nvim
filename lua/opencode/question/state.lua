-- opencode.nvim - Question state management module
-- Tracks active questions, selections, and user answers

local M = {}

-- Active questions storage: { [request_id] = question_state }
local active_questions = {}

-- Question state structure:
-- {
--   request_id = string,
--   session_id = string,
--   questions = array of question objects,
--   current_tab = number (current question index),
--   selections = { [tab_index] = { selected_indices = {}, custom_input = "" } },
--   status = "pending" | "answered" | "rejected",
--   timestamp = number,
-- }

-- Add a new question to track
---@param request_id string The question request ID from server
---@param session_id string Session ID
---@param questions_data table Array of question objects from server
function M.add_question(request_id, session_id, questions_data)
	local qstate = {
		request_id = request_id,
		session_id = session_id,
		questions = questions_data,
		current_tab = 1,
		selections = {},
		status = "pending",
		timestamp = os.time(),
	}

	-- Initialize selections for each question
	for i = 1, #questions_data do
		qstate.selections[i] = {
			selected_indices = {},
			custom_input = "",
		}
	end

	active_questions[request_id] = qstate

	-- Emit event for UI
	local events = require("opencode.events")
	events.emit("question_pending", {
		request_id = request_id,
		questions_count = #questions_data,
	})
end

-- Get a question state by request ID
---@param request_id string
---@return table|nil
function M.get_question(request_id)
	return active_questions[request_id]
end

-- Get all active questions
---@return table Array of question states
function M.get_all_active()
	local result = {}
	for _, qstate in pairs(active_questions) do
		if qstate.status == "pending" then
			table.insert(result, qstate)
		end
	end
	return result
end

-- Update selection for a specific question tab
---@param request_id string
---@param tab_index number
---@param selected_indices table Array of selected option indices
function M.update_selection(request_id, tab_index, selected_indices)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	if not qstate.selections[tab_index] then
		return false
	end

	qstate.selections[tab_index].selected_indices = selected_indices
	return true
end

-- Set custom input for a specific question tab
---@param request_id string
---@param tab_index number
---@param text string Custom input text
function M.set_custom_input(request_id, tab_index, text)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	if not qstate.selections[tab_index] then
		return false
	end

	qstate.selections[tab_index].custom_input = text
	return true
end

-- Select a single option (for single-select questions)
---@param request_id string
---@param option_index number 1-based option index
function M.select_option(request_id, option_index)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	local tab_index = qstate.current_tab
	if not qstate.selections[tab_index] then
		return false
	end

	-- Get question type
	local question = qstate.questions[tab_index]
	if not question then
		return false
	end

	-- For single-select, replace selection
	-- For multi-select, this would toggle - but we use toggle_multi_select for that
	qstate.selections[tab_index].selected_indices = { option_index }

	-- Emit update event
	local events = require("opencode.events")
	events.emit("question_selection_changed", {
		request_id = request_id,
		tab_index = tab_index,
		selected = { option_index },
	})

	return true
end

-- Toggle multi-select option
---@param request_id string
---@param option_index number 1-based option index
function M.toggle_multi_select(request_id, option_index)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	local tab_index = qstate.current_tab
	if not qstate.selections[tab_index] then
		return false
	end

	local selected = qstate.selections[tab_index].selected_indices
	local found = false

	for i, idx in ipairs(selected) do
		if idx == option_index then
			table.remove(selected, i)
			found = true
			break
		end
	end

	if not found then
		table.insert(selected, option_index)
	end

	-- Emit update event
	local events = require("opencode.events")
	events.emit("question_selection_changed", {
		request_id = request_id,
		tab_index = tab_index,
		selected = selected,
	})

	return true
end

-- Move selection up/down
---@param request_id string
---@param direction "up" | "down"
function M.move_selection(request_id, direction)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	local tab_index = qstate.current_tab
	if not qstate.selections[tab_index] then
		return false
	end

	local question = qstate.questions[tab_index]
	if not question or not question.options then
		return false
	end

	local selected = qstate.selections[tab_index].selected_indices
	local current = selected[1] or 0
	local option_count = #question.options

	local new_index
	if direction == "up" then
		new_index = current > 1 and current - 1 or option_count
	else
		new_index = current < option_count and current + 1 or 1
	end

	qstate.selections[tab_index].selected_indices = { new_index }

	-- Emit update event
	local events = require("opencode.events")
	events.emit("question_selection_changed", {
		request_id = request_id,
		tab_index = tab_index,
		selected = { new_index },
	})

	return true
end

-- Get current selection for a question
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

-- Set active tab
---@param request_id string
---@param tab_index number
function M.set_tab(request_id, tab_index)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	if tab_index < 1 or tab_index > #qstate.questions then
		return false
	end

	qstate.current_tab = tab_index

	-- Emit update event
	local events = require("opencode.events")
	events.emit("question_tab_changed", {
		request_id = request_id,
		tab_index = tab_index,
	})

	return true
end

-- Get formatted answers for submission
---@param request_id string
---@return table|nil Array of answer arrays
function M.get_answers(request_id)
	local qstate = active_questions[request_id]
	if not qstate then
		return nil
	end

	local answers = {}

	for i, question in ipairs(qstate.questions) do
		local selection = qstate.selections[i]
		if not selection then
			goto continue
		end

		local answer = {}

		-- Add selected options
		for _, idx in ipairs(selection.selected_indices) do
			local option = question.options[idx]
			if option then
				table.insert(answer, option.value or option.label or option)
			end
		end

		-- Add custom input if present
		if selection.custom_input and selection.custom_input ~= "" then
			table.insert(answer, selection.custom_input)
		end

		-- Default to empty answer if nothing selected
		if #answer == 0 then
			answer = { "" }
		end

		table.insert(answers, answer)

		::continue::
	end

	return answers
end

-- Mark question as answered
---@param request_id string
---@param answers table Optional answers array
function M.mark_answered(request_id, answers)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	qstate.status = "answered"
	qstate.answers = answers or M.get_answers(request_id)
	qstate.answered_at = os.time()

	-- Emit event
	local events = require("opencode.events")
	events.emit("question_answered", {
		request_id = request_id,
		answers = qstate.answers,
	})

	return true
end

-- Mark question as rejected
---@param request_id string
function M.mark_rejected(request_id)
	local qstate = active_questions[request_id]
	if not qstate then
		return false
	end

	qstate.status = "rejected"
	qstate.rejected_at = os.time()

	-- Emit event
	local events = require("opencode.events")
	events.emit("question_rejected", {
		request_id = request_id,
	})

	return true
end

-- Remove a question from tracking
---@param request_id string
function M.remove_question(request_id)
	if active_questions[request_id] then
		active_questions[request_id] = nil
		return true
	end
	return false
end

-- Check if a request ID exists
---@param request_id string
---@return boolean
function M.has_question(request_id)
	return active_questions[request_id] ~= nil
end

-- Get question count
---@return number
function M.get_question_count()
	local count = 0
	for _ in pairs(active_questions) do
		count = count + 1
	end
	return count
end

-- Clear all questions (e.g., on session change)
function M.clear_all()
	local events = require("opencode.events")
	for request_id, _ in pairs(active_questions) do
		events.emit("question_removed", { request_id = request_id })
	end
	active_questions = {}
end

return M
