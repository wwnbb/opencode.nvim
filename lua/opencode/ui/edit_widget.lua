-- opencode.nvim - Edit widget module
-- Renders an interactive edit review widget inline in the chat buffer.

local M = {}

local widget_base = require("opencode.ui.widget_base")
local render = require("opencode.ui.chat.render")
local panel = require("opencode.ui.panel")
local syntax = require("opencode.ui.syntax")

local PANEL_PREFIX = "▏  "
local PANEL_EMPTY = "▏"
local PANEL_BORDER_HL = "OpenCodeEditMuted"
local DIFF_INDENT = "  "
local DIFF_LINE_NUMBER_WIDTH = 4
local DIFF_LINE_NUMBER_SEPARATOR = ":  "
local DIFF_BODY_PRIORITY = 4098
local DIFF_GUTTER_PRIORITY = 4300

local icons = {
	accepted = "✓",
	rejected = "✗",
	resolved = "◆",
	expanded = "▾",
	collapsed = "▸",
	unselected = " ",
}

---@param name string
---@return table
local function get_hl(name)
	return panel.get_hl(name)
end

---@param name string
---@param fg_source string
---@param fallback string|nil
---@param extra_opts table|nil
local function set_panel_hl(name, fg_source, fallback, extra_opts)
	panel.set_hl(name, fg_source, fallback, extra_opts)
end

---@param sources string[]
---@param fallback integer|nil
---@return integer|nil
local function pick_fg(sources, fallback)
	for _, source in ipairs(sources) do
		local hl = get_hl(source)
		if hl.fg then
			return hl.fg
		end
	end
	return fallback
end

local function ensure_highlights()
	set_panel_hl("OpenCodeEditMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeEditHeader", "Title", "Normal", { bold = true })
	set_panel_hl("OpenCodeEditOutput", "Normal", nil)
	set_panel_hl("OpenCodeEditSelected", "Normal", "CursorLine", { bold = true })
	set_panel_hl("OpenCodeEditAccepted", "String", "Normal")
	set_panel_hl("OpenCodeEditRejected", "DiagnosticError", "ErrorMsg")
	set_panel_hl("OpenCodeEditResolved", "Special", "Normal")
	set_panel_hl("OpenCodeEditDiffAdd", "String", "DiffAdd")
	set_panel_hl("OpenCodeEditDiffDelete", "DiagnosticError", "DiffDelete")
	set_panel_hl("OpenCodeEditDiffContext", "Normal", nil)
	set_panel_hl("OpenCodeEditDiffMeta", "Comment", "Normal")
	set_panel_hl("OpenCodeEditDiffHeader", "Special", "Title", { bold = true })
	set_panel_hl("OpenCodeEditDiffSeparator", "LineNr", "Comment")

	vim.api.nvim_set_hl(0, "OpenCodeEditPath", {
		fg = pick_fg({ "Normal" }, nil),
		bold = true,
	})
	vim.api.nvim_set_hl(0, "OpenCodeEditStatAdd", {
		fg = pick_fg({ "String", "Added", "DiagnosticOk", "DiffAdd" }, 0x00aa00),
	})
	vim.api.nvim_set_hl(0, "OpenCodeEditStatDelete", {
		fg = pick_fg({ "DiagnosticError", "Removed", "ErrorMsg", "DiffDelete" }, 0xdd0000),
	})
	vim.api.nvim_set_hl(0, "OpenCodeEditDiffLineNr", {
		fg = get_hl("LineNr").fg or get_hl("Comment").fg,
		bg = get_hl("CursorLine").bg,
	})
	vim.api.nvim_set_hl(0, "OpenCodeEditDiffAddBody", {
		fg = get_hl("Normal").fg,
		bg = get_hl("DiffAdd").bg or get_hl("CursorLine").bg,
	})
	vim.api.nvim_set_hl(0, "OpenCodeEditDiffDeleteBody", {
		fg = get_hl("Normal").fg,
		bg = get_hl("DiffDelete").bg or get_hl("CursorLine").bg,
	})
end

---@param text string|nil
---@return string
local function normalize_path(text)
	if not text or text == "" then
		return "unknown"
	end
	return vim.fn.fnamemodify(text, ":~:.")
end

---@param result table
---@param line number
---@param col_start number
---@param col_end number
---@param hl_group string
---@param priority number|nil
local function add_highlight(result, line, col_start, col_end, hl_group, priority)
	table.insert(result.highlights, {
		line = line,
		col_start = col_start,
		col_end = col_end,
		hl_group = hl_group,
		priority = priority,
	})
end

---@param result table
---@param text string
---@param hl_group string
---@return number line_index, string line
---@return table[] rows
local function add_panel_line(result, text, hl_group)
	return panel.add_line(result, text, hl_group, {
		prefix = PANEL_PREFIX,
		prefix_hl_group = PANEL_BORDER_HL,
	})
end

---@param result table
local function add_panel_blank(result)
	panel.add_blank(result, "OpenCodeEditOutput", {
		prefix = PANEL_EMPTY,
		prefix_hl_group = PANEL_BORDER_HL,
	})
end

---@param result table
local function add_trailing_separator(result)
	table.insert(result.lines, "")
end

---@param file table
---@return string
local function file_path(file)
	return normalize_path(file and (file.relative_path or file.filepath) or nil)
end

---@param file table
---@return string
local function file_stats(file)
	local stats = file and file.stats or {}
	local added = tonumber(stats.added) or 0
	local removed = tonumber(stats.removed) or 0
	return string.format("+%d -%d", added, removed)
end

---@param edit_state table
---@return number added, number removed
local function total_stats(edit_state)
	local added = 0
	local removed = 0

	for _, file in ipairs(edit_state.files or {}) do
		local stats = file.stats or {}
		added = added + (tonumber(stats.added) or 0)
		removed = removed + (tonumber(stats.removed) or 0)
	end

	return added, removed
end

---@param count number
---@return string
local function file_count_label(count)
	return count == 1 and "file" or "files"
end

---@param file table
---@return string
local function file_type_label(file)
	local file_type = file and file.file_type or "update"
	if file_type == "add" or file_type == "create" or file_type == "new" then
		return "A"
	end
	if file_type == "delete" or file_type == "remove" then
		return "D"
	end
	return "M"
end

---@param file table
---@param is_expanded boolean
---@return string
local function file_icon(file, is_expanded)
	if file.status == "accepted" then
		return icons.accepted
	end
	if file.status == "rejected" then
		return icons.rejected
	end
	if file.status == "resolved" then
		return icons.resolved
	end
	if is_expanded then
		return icons.expanded
	end
	local diff_lines = file.diff_lines or {}
	if #diff_lines > 0 then
		return icons.collapsed
	end
	return icons.unselected
end

---@param file table
---@param is_selected boolean
---@return string
local function file_hl_group(file, is_selected)
	if file.status == "accepted" then
		return "OpenCodeEditAccepted"
	end
	if file.status == "rejected" then
		return "OpenCodeEditRejected"
	end
	if file.status == "resolved" then
		return "OpenCodeEditResolved"
	end
	if is_selected then
		return "OpenCodeEditSelected"
	end
	return "OpenCodeEditOutput"
end

---@param result table
---@param rows table[]|nil
---@param path string
---@param path_hl string
local function add_path_highlight(result, rows, path, path_hl)
	render.highlight_panel_text(result, rows, path, path_hl)
end

---@param result table
---@param rows table[]|nil
---@param stats string
local function add_stats_highlights(result, rows, stats)
	local added = stats:match("^(%+%d+)")
	local removed = stats:match("(%-%d+)$")
	if not added or not removed or not rows then
		return
	end

	for _, row in ipairs(rows) do
		local stats_start = row.line:find(stats, 1, true)
		if stats_start then
			local added_start = stats_start - 1
			local removed_start = added_start + #added + 1
			add_highlight(result, row.line_index, added_start, added_start + #added, "OpenCodeEditStatAdd")
			add_highlight(result, row.line_index, removed_start, removed_start + #removed, "OpenCodeEditStatDelete")
			return
		end
	end
end

---@param edit_state table
---@param status_label string|nil
---@return string header, string target, string stats
local function build_header(edit_state, status_label)
	local files = edit_state.files or {}
	local count = #files
	local added, removed = total_stats(edit_state)
	local stats = string.format("+%d -%d", added, removed)
	local target = count == 1 and file_path(files[1]) or string.format("%d %s", count, file_count_label(count))
	local header = "# Edit " .. target .. " " .. stats

	if status_label and status_label ~= "" then
		header = header .. " (" .. status_label .. ")"
	elseif edit_state.review_mode == "readonly" then
		header = header .. " (review)"
	end

	return header, target, stats
end

---@param message string|nil
---@return number
local function message_line_count(message)
	local text = vim.trim(message or "")
	if text == "" then
		return 0
	end
	return #vim.split(text, "\n", { plain = true })
end

---@param result table
---@param message string|nil
local function append_message_lines(result, message)
	local text = vim.trim(message or "")
	if text == "" then
		return
	end

	for i, part in ipairs(vim.split(text, "\n", { plain = true })) do
		local prefix = i == 1 and "Message: " or "         "
		add_panel_line(result, prefix .. part, "OpenCodeEditMuted")
	end
end

---@param diff_line string
---@param file table
---@param is_file_header boolean|nil
---@return string
local function display_diff_line(diff_line, file, is_file_header)
	if not is_file_header then
		return diff_line
	end

	local prefix = diff_line:sub(1, 4)
	if prefix ~= "--- " and prefix ~= "+++ " then
		return diff_line
	end

	local raw_path = diff_line:sub(5)
	if raw_path == "/dev/null" then
		return diff_line
	end

	return prefix .. file_path(file)
end

---@param diff_line string
---@param is_file_header boolean|nil
---@return "file_add"|"file_delete"|"add"|"delete"|"context"|"hunk"|"meta"
local function diff_line_kind(diff_line, is_file_header)
	if is_file_header and diff_line:sub(1, 3) == "+++" then
		return "file_add"
	end
	if is_file_header and diff_line:sub(1, 3) == "---" then
		return "file_delete"
	end
	if diff_line:match("^@@") then
		return "hunk"
	end
	if diff_line:sub(1, 1) == "+" then
		return "add"
	end
	if diff_line:sub(1, 1) == "-" then
		return "delete"
	end
	if diff_line:sub(1, 1) == " " then
		return "context"
	end
	return "meta"
end

---@param kind string
---@return string
local function diff_line_hl_group(kind)
	if kind == "file_add" then
		return "OpenCodeEditDiffAdd"
	end
	if kind == "file_delete" then
		return "OpenCodeEditDiffDelete"
	end
	if kind == "hunk" then
		return "OpenCodeEditDiffHeader"
	end
	if kind == "add" or kind == "delete" or kind == "context" then
		return "OpenCodeEditDiffContext"
	end
	return "OpenCodeEditDiffMeta"
end

---@param diff_lines string[]
---@param index number
---@return boolean
local function is_file_header_line(diff_lines, index)
	local line = diff_lines[index] or ""
	if line:sub(1, 4) == "--- " then
		local next_line = diff_lines[index + 1] or ""
		return next_line:sub(1, 4) == "+++ "
	end
	if line:sub(1, 4) == "+++ " then
		local prev_line = diff_lines[index - 1] or ""
		return prev_line:sub(1, 4) == "--- "
	end
	return false
end

---@param hunk_line string
---@return number|nil old_line
---@return number|nil new_line
local function parse_hunk_start(hunk_line)
	local old_start, new_start = hunk_line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
	return tonumber(old_start), tonumber(new_start)
end

---@param value number|nil
---@return string
local function format_line_number(value)
	return value and tostring(value) or ""
end

---@param diff_line string
---@param kind string
---@param old_line number|nil
---@param new_line number|nil
---@return string
local function format_diff_code_gutter(kind, old_line, new_line)
	local number = kind == "delete" and old_line or new_line
	return string.format(
		"%" .. DIFF_LINE_NUMBER_WIDTH .. "s%s",
		format_line_number(number),
		DIFF_LINE_NUMBER_SEPARATOR
	)
end

---@param kind string
---@return string|nil
local function diff_body_hl_group(kind)
	if kind == "add" then
		return "OpenCodeEditDiffAddBody"
	end
	if kind == "delete" then
		return "OpenCodeEditDiffDeleteBody"
	end
	return nil
end

---@param kind string
---@return string
local function diff_line_number_hl_group(kind)
	if kind == "add" then
		return "OpenCodeEditDiffAdd"
	end
	if kind == "delete" then
		return "OpenCodeEditDiffDelete"
	end
	return "OpenCodeEditDiffLineNr"
end

---@param text string
---@return string
local function display_width_spaces(text)
	return string.rep(" ", vim.fn.strdisplaywidth(text))
end

---@param result table
---@param row table
---@param source_start number
---@param source_end number
---@param hl_group string
---@param priority number|nil
local function add_wrapped_row_highlight(result, row, source_start, source_end, hl_group, priority)
	local row_start = row.byte_start or 0
	local row_end = row.byte_end or (row_start + #(row.text or ""))
	local overlap_start = math.max(source_start, row_start)
	local overlap_end = math.min(source_end, row_end)
	if overlap_start >= overlap_end then
		return
	end

	add_highlight(
		result,
		row.line_index,
		#(row.prefix or "") + overlap_start - row_start,
		#(row.prefix or "") + overlap_end - row_start,
		hl_group,
		priority
	)
end

---@param result table
---@param rows table[]|nil
---@param source_start number
---@param source_end number
---@param hl_group string
---@param priority number|nil
local function add_wrapped_line_highlight(result, rows, source_start, source_end, hl_group, priority)
	if source_end <= source_start then
		return
	end
	for _, row in ipairs(rows or {}) do
		add_wrapped_row_highlight(result, row, source_start, source_end, hl_group, priority)
	end
end

---@param result table
---@param rows table[]
---@param text string
---@param lang string
local function add_wrapped_syntax_highlights(result, rows, text, lang)
	for _, hl in ipairs(syntax.highlight_text(text, lang, { scope = "diffs" })) do
		if (hl.line or 0) == 0 then
			local source_start = hl.col_start or 0
			local source_end = hl.end_col or hl.col_end or hl.col_start or #text
			if source_end == -1 then
				source_end = #text
			end
			add_wrapped_line_highlight(result, rows, source_start, source_end, hl.hl_group, hl.priority)
		end
	end
end

---@param result table
---@param file table
---@param is_selected boolean
---@param is_expanded boolean
---@return number start_line
---@return number end_line
local function append_file_line(result, file, is_selected, is_expanded)
	local path = file_path(file)
	local stats = file_stats(file)
	local icon = file_icon(file, is_expanded)
	local type_label = file_type_label(file)
	local line_text = string.format("%s %s %s  %s", icon, type_label, path, stats)
	local line_index, _, rows = add_panel_line(result, line_text, file_hl_group(file, is_selected))
	local path_hl = file.status == "accepted" and "OpenCodeEditAccepted"
		or file.status == "rejected" and "OpenCodeEditRejected"
		or file.status == "resolved" and "OpenCodeEditResolved"
		or "OpenCodeEditPath"

	add_path_highlight(result, rows, path, path_hl)
	add_stats_highlights(result, rows, stats)
	return line_index, rows[#rows].line_index
end

---@param result table
---@param file table
---@return number|nil start_line
---@return number|nil end_line
local function append_inline_diff(result, file)
	local start_line = nil
	local end_line = nil
	local lang = syntax.language_for_path(file and (file.filepath or file.relative_path))
	local diff_lines = file.diff_lines or {}
	local in_hunk = false
	local old_line = nil
	local new_line = nil
	for i, raw_line in ipairs(diff_lines) do
		local is_file_header = not in_hunk and is_file_header_line(diff_lines, i)
		local kind = diff_line_kind(raw_line, is_file_header)
		if kind == "hunk" then
			old_line, new_line = parse_hunk_start(raw_line)
			in_hunk = true
		elseif kind ~= "file_add" and kind ~= "file_delete" and kind ~= "meta" then
			local diff_line = display_diff_line(raw_line, file, is_file_header)
			local is_code_line = kind == "add" or kind == "delete" or kind == "context"
			local body = diff_line
			local body_prefix = DIFF_INDENT
			local continuation_prefix = DIFF_INDENT
			local gutter = nil
			if is_code_line then
				gutter = format_diff_code_gutter(kind, old_line, new_line)
				body = diff_line:sub(2)
				body_prefix = DIFF_INDENT .. gutter
				continuation_prefix = DIFF_INDENT .. display_width_spaces(gutter)
			end
			local line_index, _, rows = render.add_panel_raw_line(
				result,
				body,
				diff_line_hl_group(kind),
				{
					prefix = PANEL_PREFIX,
					prefix_hl_group = PANEL_BORDER_HL,
					body_prefix = body_prefix,
					continuation_prefix = continuation_prefix,
				}
			)
			start_line = start_line or line_index
			end_line = rows[#rows].line_index

			if is_code_line then
				local gutter_start = #PANEL_PREFIX + #DIFF_INDENT
				local separator_start = gutter_start + DIFF_LINE_NUMBER_WIDTH
				local body_hl = diff_body_hl_group(kind)
				if body_hl then
					for _, row in ipairs(rows) do
						add_highlight(result, row.line_index, #row.prefix, #row.line, body_hl, DIFF_BODY_PRIORITY)
					end
				end
				add_highlight(
					result,
					line_index,
					gutter_start,
					gutter_start + DIFF_LINE_NUMBER_WIDTH,
					diff_line_number_hl_group(kind),
					DIFF_GUTTER_PRIORITY
				)
				add_highlight(
					result,
					line_index,
					separator_start,
					separator_start + #DIFF_LINE_NUMBER_SEPARATOR,
					"OpenCodeEditDiffSeparator",
					DIFF_GUTTER_PRIORITY
				)

				local code = raw_line:sub(2)
				if lang and code ~= "" then
					add_wrapped_syntax_highlights(result, rows, code, lang)
				end
			end
			if kind == "add" then
				new_line = new_line and (new_line + 1) or nil
			elseif kind == "delete" then
				old_line = old_line and (old_line + 1) or nil
			elseif kind == "context" then
				old_line = old_line and (old_line + 1) or nil
				new_line = new_line and (new_line + 1) or nil
			end
		end
	end
	return start_line, end_line
end

---@param edit_state table
---@return number
function M.get_first_file_line(edit_state)
	local line = 3 -- top padding + header + panel blank
	local messages = message_line_count(edit_state and edit_state.message)
	if messages > 0 then
		line = line + messages + 1 -- message lines + separating panel blank
	end
	return line
end

--- Get formatted lines for a pending (interactive) edit widget.
---@param permission_id string
---@param edit_state table Edit state from edit/state.lua
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_lines_for_edit(permission_id, edit_state)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local header, target, stats = build_header(edit_state)
	add_panel_blank(result)
	local _, _, header_rows = add_panel_line(result, header, "OpenCodeEditHeader")
	add_path_highlight(result, header_rows, target, "OpenCodeEditPath")
	add_stats_highlights(result, header_rows, stats)
	add_panel_blank(result)

	if edit_state.message and edit_state.message ~= "" then
		append_message_lines(result, edit_state.message)
		add_panel_blank(result)
	end

	local first_file_line = #result.lines
	local file_ranges = {}
	local selected = edit_state.selected_file or 1
	local expanded_files = edit_state.expanded_files or {}
	for i, file in ipairs(edit_state.files or {}) do
		local file_start, file_end = append_file_line(result, file, i == selected, expanded_files[i] == true)
		if expanded_files[i] and file.diff_lines and #file.diff_lines > 0 then
			add_panel_blank(result)
			local _, diff_end = append_inline_diff(result, file)
			file_end = diff_end or file_end
		end
		table.insert(file_ranges, {
			index = i,
			start_line = file_start,
			end_line = file_end,
		})
	end

	if #(edit_state.files or {}) == 0 then
		add_panel_line(result, "No file changes detected.", "OpenCodeEditMuted")
	end

	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines, result.highlights, widget_base.make_meta({
		interactive_count = #(edit_state.files or {}),
		first_interactive_line = first_file_line,
		file_ranges = file_ranges,
	})
end

--- Get formatted lines for a resolved edit (all files accepted/rejected, reply sent).
---@param permission_id string
---@param edit_state table Edit state from edit/state.lua
---@return table lines, table highlights
function M.get_resolved_lines(permission_id, edit_state)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local edit_state_mod = require("opencode.edit.state")
	local resolution = edit_state_mod.get_resolution(permission_id)
	local resolution_label = "partial"
	local header_hl = "OpenCodeEditMuted"

	if resolution == "all_accepted" then
		resolution_label = "approved"
		header_hl = "OpenCodeEditAccepted"
	elseif resolution == "all_rejected" then
		resolution_label = "rejected"
		header_hl = "OpenCodeEditRejected"
	elseif resolution == "all_resolved" then
		resolution_label = "resolved"
		header_hl = "OpenCodeEditResolved"
	end

	local header, target, stats = build_header(edit_state, resolution_label)
	add_panel_blank(result)
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	add_path_highlight(result, header_rows, target, "OpenCodeEditPath")
	add_stats_highlights(result, header_rows, stats)
	add_panel_blank(result)

	if edit_state.message and edit_state.message ~= "" then
		append_message_lines(result, edit_state.message)
		add_panel_blank(result)
	end

	for _, file in ipairs(edit_state.files or {}) do
		append_file_line(result, file, false, false)
	end

	if #(edit_state.files or {}) == 0 then
		add_panel_line(result, "No file changes detected.", "OpenCodeEditMuted")
	end

	add_panel_blank(result)
	add_trailing_separator(result)
	return result.lines, result.highlights
end

return M
