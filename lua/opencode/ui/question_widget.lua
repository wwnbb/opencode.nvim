-- opencode.nvim - Question widget module
-- Renders interactive questions inline in chat buffer

local M = {}

-- Icons and config (will be configurable)
local icons = {
	pending = "💭",
	answered = "✓",
	rejected = "✗",
	selected = "❯",
	unselected = "  ",
	multi_selected = "☑",
	multi_unselected = "☐",
}

-- Get formatted lines for a question
---@param request_id string
---@param question_data table
---@param selection_state table
---@param status "pending" | "answered" | "rejected" | "confirming"
---@return table lines, table highlights, number option_count, number first_option_line
function M.get_lines_for_question(request_id, question_data, selection_state, status)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local questions = question_data.questions or question_data

	-- If in confirming state, show confirmation view instead
	-- (must check BEFORE current_tab lookup since confirming uses a temp tab beyond question range)
	if status == "confirming" then
		return M.get_confirmation_lines(request_id, question_data, selection_state)
	end

	local current_tab = selection_state.current_tab or 1
	local current_question = questions[current_tab]

	if not current_question then
		return lines, highlights, 0, 0
	end

	-- Header line with icon and request ID
	local icon = icons[status] or icons.pending
	local id_short = request_id:sub(1, 8)
	local time_str = os.date("%H:%M", selection_state.timestamp or os.time())
	local header = string.format("%s Question [%s] %s%s", icon, id_short, string.rep(" ", 50 - 10 - #id_short - #time_str), time_str)
	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #icon + 9,
		hl_group = status == "pending" and "Title" or "Comment",
	})
	line_num = line_num + 1

	-- Separator
	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	-- Tab bar (if multiple questions)
	if #questions > 1 then
		local tab_parts = {}
		local tab_highlight_offsets = {}
		local current_offset = 0

		for i, q in ipairs(questions) do
			local tab_label = q.title or q.header or ("Q" .. i)
			local is_active = i == current_tab
			
			-- Check if this question is answered
			local selection = selection_state.selections and selection_state.selections[i]
			local is_answered = selection and selection.is_answered
			
			-- Add checkmark if answered
			if is_answered then
				tab_label = tab_label .. " ✓"
			end
			
			local prefix = is_active and "[" or " "
			local suffix = is_active and "]" or " "
			local tab_text = prefix .. tab_label .. suffix

			table.insert(tab_parts, tab_text)
			table.insert(tab_highlight_offsets, {
				start_col = current_offset,
				end_col = current_offset + #tab_text,
				is_active = is_active,
				is_answered = is_answered,
			})

			current_offset = current_offset + #tab_text + 1
		end

		table.insert(lines, table.concat(tab_parts, " "))

		-- Apply tab highlights
		for _, offset in ipairs(tab_highlight_offsets) do
			local hl_group = "Normal"
			if offset.is_active then
				hl_group = "CursorLine"
			elseif offset.is_answered then
				hl_group = "Comment"
			end
			table.insert(highlights, {
				line = line_num,
				col_start = offset.start_col,
				col_end = offset.end_col,
				hl_group = hl_group,
			})
		end

		line_num = line_num + 1
		table.insert(lines, "")
		line_num = line_num + 1
	end

	-- Question header/title
	if current_question.header then
		table.insert(lines, current_question.header)
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = #current_question.header,
			hl_group = "Label",
		})
		line_num = line_num + 1
	end

	-- Question text
	if current_question.question then
		local question_lines = vim.split(current_question.question, "\n", { plain = true })
		for _, qline in ipairs(question_lines) do
			table.insert(lines, qline)
			line_num = line_num + 1
		end
	end

	table.insert(lines, "")
	line_num = line_num + 1

	-- Options
	local option_count = 0
	local first_option_line = line_num
	local selections = selection_state.selections and selection_state.selections[current_tab] or {}
	local selected_indices = selections.selected_indices or {}
	local is_multi = current_question.type == "multi"

	if current_question.options and #current_question.options > 0 then
		first_option_line = line_num
		option_count = #current_question.options

		for i, option in ipairs(current_question.options) do
			local is_selected = false
			for _, idx in ipairs(selected_indices) do
				if idx == i then
					is_selected = true
					break
				end
			end

			local option_text
			local option_label = type(option) == "string" and option or (option.label or option.value or tostring(i))

			if is_multi then
				local checkbox = is_selected and icons.multi_selected or icons.multi_unselected
				option_text = string.format("%s %d. %s", checkbox, i, option_label)
			else
				local indicator = is_selected and icons.selected or icons.unselected
				option_text = string.format("%s %d. %s", indicator, i, option_label)
			end

			table.insert(lines, option_text)

			-- Highlight selected option
			if is_selected then
				table.insert(highlights, {
					line = line_num,
					col_start = 0,
					col_end = #option_text,
					hl_group = "CursorLine",
				})
			end

			line_num = line_num + 1
		end

		-- Custom input option (if enabled)
		local allow_custom = current_question.allow_custom or current_question.allowCustom
		if allow_custom then
			local custom_selected = selections.custom_input and selections.custom_input ~= ""
			local custom_indicator = custom_selected and icons.selected or icons.unselected
			local custom_text = selections.custom_input or ""

			table.insert(lines, "")
			line_num = line_num + 1

			if custom_selected then
				table.insert(lines, custom_indicator .. " Custom: " .. custom_text)
				table.insert(highlights, {
					line = line_num,
					col_start = 0,
					col_end = 10 + #custom_text,
					hl_group = "CursorLine",
				})
			else
				table.insert(lines, custom_indicator .. " Provide custom answer...")
			end

			line_num = line_num + 1
		end
	end

	-- Keymap hint
	if status == "pending" then
		table.insert(lines, "")
		line_num = line_num + 1

		local hint_parts = {}
		if option_count > 0 then
			table.insert(hint_parts, "1-" .. math.min(option_count, 9) .. " select")
		end
		table.insert(hint_parts, "↑↓ navigate")

		if allow_custom then
			table.insert(hint_parts, "c custom")
		end

		-- Show progress for multi-question blocks
		if #questions > 1 then
			-- Count answered questions
			local answered_count = 0
			for i = 1, #questions do
				local sel = selection_state.selections and selection_state.selections[i]
				if sel and sel.is_answered then
					answered_count = answered_count + 1
				end
			end
			
			if answered_count == #questions then
				table.insert(hint_parts, "Enter submit")
			else
				table.insert(hint_parts, string.format("Enter submit (%d/%d)", answered_count, #questions))
			end
			table.insert(hint_parts, "Tab/S-Tab navigate")
		else
			table.insert(hint_parts, "Enter confirm")
		end
		
		table.insert(hint_parts, "Esc cancel")

		local hint = "[" .. table.concat(hint_parts, ", ") .. "]"
		table.insert(lines, hint)
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = #hint,
			hl_group = "Comment",
		})
		line_num = line_num + 1
	end

	-- Empty line after question
	table.insert(lines, "")

	return lines, highlights, option_count, first_option_line
end

-- Get option count for a question
---@param question_data table
---@return number
function M.get_option_count(question_data)
	local questions = question_data.questions or question_data
	if #questions == 0 then
		return 0
	end

	local current_question = questions[1]
	if not current_question.options then
		return 0
	end

	return #current_question.options
end

-- Check if line is within a question's range
---@param bufnr number
---@param line number 0-based line number
---@param question_line_start number
---@param question_line_end number
---@return boolean
function M.is_line_in_question(bufnr, line, question_line_start, question_line_end)
	return line >= question_line_start and line <= question_line_end
end

-- Get option index from line number
---@param line number Line number within question (relative to question start)
---@param header_lines number Number of header lines before options
---@param has_tabs boolean Whether question has tab bar
---@param has_header boolean Whether question has header text
---@return number|nil option_index
function M.get_option_index_from_line(line, header_lines, has_tabs, has_header)
	-- Account for: header (1) + separator (1) + [tabs (2 if has_tabs)] + [header] + question + empty + options start
	local options_start = 2 + (has_tabs and 2 or 0) + header_lines + 1

	if line < options_start then
		return nil
	end

	local option_index = line - options_start + 1
	return option_index > 0 and option_index or nil
end

-- Format answered question display
---@param request_id string
---@param question_data table
---@param answers table
---@return table lines, table highlights
function M.get_answered_lines(request_id, question_data, answers)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local id_short = request_id:sub(1, 8)
	local time_str = os.date("%H:%M", os.time())
	local header = string.format("%s Question [%s] %s%s", icons.answered, id_short, string.rep(" ", 50 - 2 - #id_short - #time_str), time_str)

	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = 2,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	local questions = question_data.questions or question_data

	for i, question in ipairs(questions) do
		local answer = answers and answers[i] or {}
		local answer_text = table.concat(answer, ", ")

		local display_text = (question.header or question.question or "Question") .. ": " .. answer_text
		table.insert(lines, display_text)
		line_num = line_num + 1
	end

	table.insert(lines, "")

	return lines, highlights
end

-- Format rejected question display
---@param request_id string
---@param question_data table
---@return table lines, table highlights
function M.get_rejected_lines(request_id, question_data)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local id_short = request_id:sub(1, 8)
	local time_str = os.date("%H:%M", os.time())
	local header = string.format("%s Question [%s] %s%s", icons.rejected, id_short, string.rep(" ", 50 - 2 - #id_short - #time_str), time_str)

	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = 2,
		hl_group = "Error",
	})
	line_num = line_num + 1

	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	local questions = question_data.questions or question_data
	local question_text = questions[1] and (questions[1].header or questions[1].question or "Question")

	table.insert(lines, question_text .. " - Cancelled")
	table.insert(highlights, {
		line = line_num,
		col_start = #question_text + 1,
		col_end = #question_text + 1 + 10,
		hl_group = "Error",
	})
	line_num = line_num + 1

	table.insert(lines, "")

	return lines, highlights
end

-- Get confirmation view lines (shown when all questions are answered)
---@param request_id string
---@param question_data table
---@param selection_state table
---@return table lines, table highlights, number option_count, number first_option_line
function M.get_confirmation_lines(request_id, question_data, selection_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local questions = question_data.questions or question_data
	
	-- Header
	local id_short = request_id:sub(1, 8)
	local time_str = os.date("%H:%M", selection_state.timestamp or os.time())
	local header = string.format("✓ Question [%s] %s%s", id_short, string.rep(" ", 50 - 2 - #id_short - #time_str), time_str)
	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #header,
		hl_group = "Title",
	})
	line_num = line_num + 1

	-- Separator
	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	-- Title
	table.insert(lines, "Ready to Submit")
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = 15,
		hl_group = "Title",
	})
	line_num = line_num + 1
	
	table.insert(lines, "")
	line_num = line_num + 1

	-- Show all questions with their answers
	for i, question in ipairs(questions) do
		local selection = selection_state.selections and selection_state.selections[i]
		local answer_parts = {}
		
		-- Collect answer text
		if selection then
			for _, idx in ipairs(selection.selected_indices or {}) do
				local option = question.options and question.options[idx]
				if option then
					local label = type(option) == "string" and option or (option.label or option.value or tostring(idx))
					table.insert(answer_parts, label)
				end
			end
			if selection.custom_input and selection.custom_input ~= "" then
				table.insert(answer_parts, selection.custom_input)
			end
		end
		
		local answer_text = #answer_parts > 0 and table.concat(answer_parts, ", ") or "(no answer)"
		local q_label = question.header or question.title or ("Question " .. i)
		
		-- Question label
		table.insert(lines, q_label .. ":")
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = #q_label + 1,
			hl_group = "Label",
		})
		line_num = line_num + 1
		
		-- Answer with checkmark
		local answer_line = "  ✓ " .. answer_text
		table.insert(lines, answer_line)
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = #answer_line,
			hl_group = "String",
		})
		line_num = line_num + 1
		
		table.insert(lines, "")
		line_num = line_num + 1
	end

	-- Confirmation prompt - read current selection
	local temp_tab_idx = #questions + 1
	local confirm_selection = selection_state.selections and selection_state.selections[temp_tab_idx]
	local confirm_selected = confirm_selection and confirm_selection.selected_indices or { 1 }
	local selected_choice = confirm_selected[1] or 1

	local first_option_line = line_num

	local yes_indicator = selected_choice == 1 and icons.selected or icons.unselected
	local no_indicator = selected_choice == 2 and icons.selected or icons.unselected

	local yes_text = yes_indicator .. " 1. Yes, submit all answers"
	table.insert(lines, yes_text)
	if selected_choice == 1 then
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = #yes_text,
			hl_group = "CursorLine",
		})
	end
	line_num = line_num + 1

	local no_text = no_indicator .. " 2. No, review answers"
	table.insert(lines, no_text)
	if selected_choice == 2 then
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = #no_text,
			hl_group = "CursorLine",
		})
	end
	line_num = line_num + 1
	
	table.insert(lines, "")
	line_num = line_num + 1

	-- Hint
	local hint = "[1-2 select, ↑↓ navigate, Enter confirm, Esc cancel]"
	table.insert(lines, hint)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #hint,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	table.insert(lines, "")

	return lines, highlights, 2, first_option_line
end

-- Set custom icons
---@param custom_icons table
function M.set_icons(custom_icons)
	icons = vim.tbl_deep_extend("force", icons, custom_icons or {})
end

return M
