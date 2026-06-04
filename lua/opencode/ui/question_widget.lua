-- opencode.nvim - Question widget module
-- Renders interactive questions inline in the chat buffer.

local M = {}

local panel = require("opencode.ui.panel")
local widget_base = require("opencode.ui.widget_base")

local PANEL_PREFIX = "▏  "
local PANEL_BLANK_PREFIX = "▏"
local PANEL_BORDER_HL = "OpenCodeQuestionMuted"

local icons = {
	selected = "❯",
	unselected = " ",
	multi_selected = "☑",
	multi_unselected = "☐",
}

local panel_helpers = panel.create_helpers({
	prefix = PANEL_PREFIX,
	blank_prefix = PANEL_BLANK_PREFIX,
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeQuestionOutput",
})
local get_hl = panel_helpers.get_hl
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = function(result, text, hl_group)
	return panel_helpers.add_raw_line(result, text, hl_group, { wrap = false })
end
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator
local highlight_panel_text = panel_helpers.highlight_text

local function set_panel_hl(name, fg_source, fallback, extra_opts)
	panel_helpers.set_hl(name, fg_source, fallback, extra_opts)
end

local function ensure_highlights()
	set_panel_hl("OpenCodeQuestionMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeQuestionHeader", "Title", "Normal", { bold = true })
	set_panel_hl("OpenCodeQuestionTitle", "Label", "Title", { bold = true })
	set_panel_hl("OpenCodeQuestionOutput", "Normal", nil)
	set_panel_hl("OpenCodeQuestionSelected", "Normal", "CursorLine", { bold = true })
	set_panel_hl("OpenCodeQuestionAnswer", "String", "Normal")
	set_panel_hl("OpenCodeQuestionError", "DiagnosticError", "ErrorMsg")

	vim.api.nvim_set_hl(0, "OpenCodeQuestionSelectedMarker", {
		fg = get_hl("Special").fg or get_hl("Title").fg,
		bg = get_hl("CursorLine").bg,
		bold = true,
	})
end

---@param value any
---@return string
local function trim_string(value)
	if type(value) ~= "string" then
		return ""
	end
	return vim.trim(value)
end

---@param question_data table
---@return table
local function get_questions(question_data)
	if type(question_data) ~= "table" then
		return {}
	end
	return question_data.questions or question_data
end

---@param question table|nil
---@param fallback string|nil
---@return string
local function get_question_title(question, fallback)
	if type(question) ~= "table" then
		return fallback or "Question"
	end

	local title = trim_string(question.header)
	if title ~= "" then
		return title
	end

	title = trim_string(question.title)
	if title ~= "" then
		return title
	end

	title = trim_string(question.question)
	if title ~= "" then
		return title:match("^[^\n]+") or title
	end

	return fallback or "Question"
end

---@param option any
---@param fallback string
---@return string
local function get_option_label(option, fallback)
	if type(option) == "string" then
		return option
	end
	if type(option) == "table" then
		return tostring(option.label or option.value or fallback)
	end
	return tostring(option or fallback)
end

---@param selected_indices table
---@param index number
---@return boolean
local function is_selected(selected_indices, index)
	for _, selected in ipairs(selected_indices or {}) do
		if selected == index then
			return true
		end
	end
	return false
end

---@param question table|nil
---@return boolean
local function is_multi_question(question)
	return type(question) == "table" and (question.type == "multi" or question.multiple == true)
end

---@param result table
---@param title string
---@param status string
---@param suffix string|nil
local function add_header(result, title, status, suffix)
	local header = "# Question"
	if title ~= "" then
		header = header .. " " .. title
	end
	if suffix and suffix ~= "" then
		header = header .. " " .. suffix
	end

	local hl_group = "OpenCodeQuestionHeader"
	if status == "answered" then
		hl_group = "OpenCodeQuestionAnswer"
	elseif status == "rejected" then
		hl_group = "OpenCodeQuestionError"
	end

	local _, _, rows = add_panel_line(result, header, hl_group)
	if title ~= "" then
		highlight_panel_text(result, rows, title, "OpenCodeQuestionTitle")
	end
end

---@param result table
---@param text string|nil
---@param hl_group string
local function append_text_lines(result, text, hl_group)
	if type(text) ~= "string" or text == "" then
		return
	end

	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		if line == "" then
			add_panel_blank(result)
		else
			add_panel_line(result, line, hl_group)
		end
	end
end

---@param result table
---@param text string|nil
local function append_message_lines(result, text)
	local message = trim_string(text)
	if message == "" then
		return
	end

	for i, part in ipairs(vim.split(message, "\n", { plain = true })) do
		local prefix = i == 1 and "Message: " or "         "
		add_panel_line(result, prefix .. part, "OpenCodeQuestionMuted")
	end
end

---@param option_count number
---@param is_multi boolean
---@param allow_custom boolean
---@param ready_to_advance boolean
---@param has_multiple boolean
---@param answered_count number
---@param total_count number
---@return string
local function format_hint(
	option_count,
	is_multi,
	allow_custom,
	ready_to_advance,
	has_multiple,
	answered_count,
	total_count
)
	local parts = {}
	if ready_to_advance then
		table.insert(parts, "Enter again to continue")
	else
		if option_count > 0 then
			table.insert(parts, string.format("1-%d select", math.min(option_count, 9)))
			table.insert(parts, "↑↓ move")
		else
			table.insert(parts, "select an answer")
		end
		if is_multi then
			table.insert(parts, "Space toggle")
		end
		table.insert(parts, "Enter twice submit")
	end

	if has_multiple then
		table.insert(parts, string.format("%d/%d answered", answered_count, total_count))
		table.insert(parts, "Tab/S-Tab review")
	end
	if allow_custom then
		table.insert(parts, "c custom")
	end
	table.insert(parts, "m message")
	table.insert(parts, "Esc cancel")
	return table.concat(parts, " · ")
end

---@param result table
---@param questions table
---@param current_tab number
---@param selection_state table
local function append_tab_bar(result, questions, current_tab, selection_state)
	if #questions <= 1 then
		return
	end

	local parts = {}
	local spans = {}
	local offset = 0
	for i, question in ipairs(questions) do
		local selection = selection_state.selections and selection_state.selections[i]
		local answered = selection and selection.is_answered
		local label = tostring(i) .. " " .. get_question_title(question, "Q" .. tostring(i))
		if answered then
			label = label .. " ✓"
		end
		local text = i == current_tab and ("[" .. label .. "]") or (" " .. label .. " ")
		table.insert(parts, text)
		table.insert(spans, {
			start_col = offset,
			end_col = offset + #text,
			hl_group = i == current_tab and "OpenCodeQuestionSelected"
				or (answered and "OpenCodeQuestionAnswer" or "OpenCodeQuestionMuted"),
		})
		offset = offset + #text + 1
	end

	local line_index = add_panel_raw_line(result, table.concat(parts, " "), "OpenCodeQuestionMuted")
	for _, span in ipairs(spans) do
		table.insert(result.highlights, {
			line = line_index,
			col_start = #PANEL_PREFIX + span.start_col,
			col_end = #PANEL_PREFIX + span.end_col,
			hl_group = span.hl_group,
		})
	end
end

---@param selection table
---@param question table
---@return string[]
local function collect_selection_answers(selection, question)
	local answer_parts = {}
	if type(selection) ~= "table" then
		return answer_parts
	end

	for _, idx in ipairs(selection.selected_indices or {}) do
		local option = question.options and question.options[idx]
		if option then
			table.insert(answer_parts, get_option_label(option, tostring(idx)))
		end
	end
	if selection.custom_input and selection.custom_input ~= "" then
		table.insert(answer_parts, selection.custom_input)
	end

	local message = trim_string(selection.message)
	if message ~= "" then
		table.insert(answer_parts, "Message: " .. message:gsub("%s*\n%s*", " / "))
	end
	return answer_parts
end

-- Get formatted lines for a question.
---@param _request_id string
---@param question_data table
---@param selection_state table
---@param status "pending"|"answered"|"rejected"|"confirming"
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_lines_for_question(_request_id, question_data, selection_state, status)
	ensure_highlights()
	if status == "confirming" then
		return M.get_confirmation_lines(_request_id, question_data, selection_state)
	end

	local result = { lines = {}, highlights = {} }
	local questions = get_questions(question_data)
	local current_tab = selection_state.current_tab or 1
	local current_question = questions[current_tab]
	local selections = selection_state.selections and selection_state.selections[current_tab] or {}

	if not current_question then
		return result.lines, result.highlights, widget_base.make_meta()
	end

	local title = get_question_title(current_question, "Question")
	local suffix = #questions > 1 and string.format("(%d/%d)", current_tab, #questions) or nil
	add_panel_blank(result)
	add_header(result, title, status or "pending", suffix)
	add_panel_blank(result)

	append_tab_bar(result, questions, current_tab, selection_state)
	if #questions > 1 then
		add_panel_blank(result)
	end

	local body = trim_string(current_question.question)
	if body ~= "" and body ~= title then
		append_text_lines(result, current_question.question, "OpenCodeQuestionOutput")
	elseif body == "" and title ~= "" then
		add_panel_line(result, title, "OpenCodeQuestionTitle")
	end

	if selections.message and selections.message ~= "" then
		add_panel_blank(result)
		append_message_lines(result, selections.message)
	end

	add_panel_blank(result)

	local option_count = 0
	local first_option_line = #result.lines
	local selected_indices = selections.selected_indices or {}
	local is_multi = is_multi_question(current_question)
	local allow_custom = current_question.allow_custom or current_question.allowCustom

	if current_question.options and #current_question.options > 0 then
		option_count = #current_question.options

		for i, option in ipairs(current_question.options) do
			local selected = is_selected(selected_indices, i)
			local option_label = get_option_label(option, tostring(i))
			local marker
			if is_multi then
				marker = selected and icons.multi_selected or icons.multi_unselected
			else
				marker = selected and icons.selected or icons.unselected
			end

			local option_text = string.format("%s %d. %s", marker, i, option_label)
			local _, _, rows = add_panel_raw_line(
				result,
				option_text,
				selected and "OpenCodeQuestionSelected" or "OpenCodeQuestionOutput"
			)
			if selected then
				highlight_panel_text(result, rows, marker, "OpenCodeQuestionSelectedMarker")
			end
		end

		if allow_custom then
			add_panel_blank(result)
			local custom_text = selections.custom_input or ""
			local custom_selected = custom_text ~= ""
			local custom_marker = custom_selected and icons.selected or icons.unselected
			local custom_line = custom_selected and (custom_marker .. " Custom: " .. custom_text)
				or (custom_marker .. " Custom answer...")
			add_panel_line(
				result,
				custom_line,
				custom_selected and "OpenCodeQuestionSelected" or "OpenCodeQuestionMuted"
			)
		end
	end

	if status == "pending" then
		local answered_count = 0
		for i = 1, #questions do
			local selection = selection_state.selections and selection_state.selections[i]
			if selection and selection.is_answered then
				answered_count = answered_count + 1
			end
		end

		add_panel_blank(result)
		add_panel_line(
			result,
			format_hint(
				option_count,
				is_multi,
				allow_custom,
				selections.ready_to_advance == true,
				#questions > 1,
				answered_count,
				#questions
			),
			"OpenCodeQuestionMuted"
		)
	end

	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines,
		result.highlights,
		widget_base.make_meta({
			interactive_count = option_count,
			first_interactive_line = first_option_line,
		})
end

-- Format answered question display.
---@param _request_id string
---@param question_data table
---@param answers table
---@return table lines, table highlights
function M.get_answered_lines(_request_id, question_data, answers)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local questions = get_questions(question_data)
	add_panel_blank(result)
	add_header(result, "answered", "answered")
	add_panel_blank(result)

	for i, question in ipairs(questions) do
		local raw_answer = answers and answers[i] or {}
		local answer_text
		if type(raw_answer) == "table" then
			answer_text = table.concat(raw_answer, ", ")
		else
			answer_text = tostring(raw_answer or "")
		end
		if answer_text == "" then
			answer_text = "(no answer)"
		end

		local label = get_question_title(question, "Question " .. tostring(i))
		add_panel_line(result, label .. ": " .. answer_text, "OpenCodeQuestionAnswer")
	end

	add_panel_blank(result)
	add_trailing_separator(result)
	return result.lines, result.highlights
end

-- Format rejected question display.
---@param _request_id string
---@param question_data table
---@return table lines, table highlights
function M.get_rejected_lines(_request_id, question_data)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local questions = get_questions(question_data)
	local title = questions[1] and get_question_title(questions[1], "Question") or "Question"

	add_panel_blank(result)
	add_header(result, title, "rejected", "cancelled")
	add_panel_blank(result)
	add_panel_line(result, "Cancelled", "OpenCodeQuestionError")
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines, result.highlights
end

-- Get confirmation view lines (shown when all questions are answered).
---@param _request_id string
---@param question_data table
---@param selection_state table
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_confirmation_lines(_request_id, question_data, selection_state)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local questions = get_questions(question_data)

	add_panel_blank(result)
	add_header(result, "ready to submit", "pending")
	add_panel_blank(result)

	for i, question in ipairs(questions) do
		local selection = selection_state.selections and selection_state.selections[i]
		local answers = collect_selection_answers(selection, question)
		local answer_text = #answers > 0 and table.concat(answers, ", ") or "(no answer)"
		local label = get_question_title(question, "Question " .. tostring(i))
		add_panel_line(result, label .. ": " .. answer_text, "OpenCodeQuestionAnswer")
	end

	add_panel_blank(result)

	local temp_tab_idx = #questions + 1
	local confirm_selection = selection_state.selections and selection_state.selections[temp_tab_idx]
	local confirm_selected = confirm_selection and confirm_selection.selected_indices or { 1 }
	local selected_choice = confirm_selected[1] or 1
	local first_option_line = #result.lines

	for i, label in ipairs({ "Yes, submit all answers", "No, review answers" }) do
		local selected = selected_choice == i
		local marker = selected and icons.selected or icons.unselected
		local line = string.format("%s %d. %s", marker, i, label)
		add_panel_raw_line(result, line, selected and "OpenCodeQuestionSelected" or "OpenCodeQuestionOutput")
	end

	add_panel_blank(result)
	add_panel_line(result, "Enter to continue · Esc returns to questions", "OpenCodeQuestionMuted")
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines,
		result.highlights,
		widget_base.make_meta({
			interactive_count = 2,
			first_interactive_line = first_option_line,
		})
end

-- Set custom icons.
---@param custom_icons table
function M.set_icons(custom_icons)
	icons = vim.tbl_deep_extend("force", icons, custom_icons or {})
end

return M
