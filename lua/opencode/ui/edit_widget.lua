-- opencode.nvim - Edit widget module
-- Renders an interactive edit review widget inline in the chat buffer.

local M = {}

local widget_base = require("opencode.ui.widget_base")
local render = require("opencode.ui.chat.render")
local syntax = require("opencode.ui.syntax")

local PANEL_PREFIX = "▏  "
local PANEL_EMPTY = "▏"

local icons = {
	accepted = "✓",
	rejected = "✗",
	resolved = "◆",
	selected = "❯",
	unselected = " ",
}

---@param name string
---@return table
local function get_hl(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and value or {}
end

---@param name string
---@param fg_source string
---@param fallback string|nil
---@param extra_opts table|nil
local function set_panel_hl(name, fg_source, fallback, extra_opts)
	local cursor = get_hl("CursorLine")
	local fg_hl = get_hl(fg_source)
	local fallback_hl = fallback and get_hl(fallback) or {}
	local opts = {}

	if fg_hl.fg or fallback_hl.fg then
		opts.fg = fg_hl.fg or fallback_hl.fg
	end
	if cursor.bg then
		opts.bg = cursor.bg
	end
	if extra_opts then
		opts = vim.tbl_extend("force", opts, extra_opts)
	end
	if next(opts) == nil then
		opts.link = fallback or fg_source
	end

	vim.api.nvim_set_hl(0, name, opts)
end

local function ensure_highlights()
	set_panel_hl("OpenCodeEditMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeEditHeader", "Title", "Normal", { bold = true })
	set_panel_hl("OpenCodeEditPath", "String", "Normal", { bold = true })
	set_panel_hl("OpenCodeEditOutput", "Normal", nil)
	set_panel_hl("OpenCodeEditSelected", "Normal", "CursorLine", { bold = true })
	set_panel_hl("OpenCodeEditAccepted", "String", "Normal")
	set_panel_hl("OpenCodeEditRejected", "DiagnosticError", "ErrorMsg")
	set_panel_hl("OpenCodeEditResolved", "Special", "Normal")
	set_panel_hl("OpenCodeEditDiffAdd", "DiffAdd", "String")
	set_panel_hl("OpenCodeEditDiffDelete", "DiffDelete", "DiagnosticError")
	set_panel_hl("OpenCodeEditDiffHeader", "Title", "Normal")
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
local function add_highlight(result, line, col_start, col_end, hl_group)
	table.insert(result.highlights, {
		line = line,
		col_start = col_start,
		col_end = col_end,
		hl_group = hl_group,
	})
end

---@param result table
---@param text string
---@param hl_group string
---@return number line_index, string line
---@return table[] rows
local function add_panel_line(result, text, hl_group)
	return render.add_panel_line(result, text, hl_group, { prefix = PANEL_PREFIX })
end

---@param result table
local function add_panel_blank(result)
	render.add_panel_blank(result, "OpenCodeEditOutput", { prefix = PANEL_EMPTY })
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
---@param is_selected boolean
---@return string
local function file_icon(file, is_selected)
	if file.status == "accepted" then
		return icons.accepted
	end
	if file.status == "rejected" then
		return icons.rejected
	end
	if file.status == "resolved" then
		return icons.resolved
	end
	if is_selected then
		return icons.selected
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
			add_highlight(result, row.line_index, added_start, added_start + #added, "OpenCodeEditDiffAdd")
			add_highlight(result, row.line_index, removed_start, removed_start + #removed, "OpenCodeEditDiffDelete")
			return
		end
	end
end

---@param left string
---@param right string
---@return string
local function align_right(left, right)
	local body_width = math.max(20, render.get_chat_text_width() - vim.fn.strdisplaywidth(PANEL_PREFIX))
	local left_width = vim.fn.strdisplaywidth(left)
	local right_width = vim.fn.strdisplaywidth(right)
	local padding = math.max(1, body_width - left_width - right_width)
	return left .. string.rep(" ", padding) .. right
end

---@param edit_state table
---@param status_label string|nil
---@return string header, string target
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

	return header, target
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
---@return string
local function display_diff_line(diff_line, file)
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
---@return string
local function diff_hl_group(diff_line)
	if diff_line:sub(1, 3) == "+++" or diff_line:sub(1, 1) == "+" then
		return "OpenCodeEditDiffAdd"
	end
	if diff_line:sub(1, 3) == "---" or diff_line:sub(1, 1) == "-" then
		return "OpenCodeEditDiffDelete"
	end
	if diff_line:match("^@@") then
		return "OpenCodeEditDiffHeader"
	end
	return "OpenCodeEditMuted"
end

---@param result table
---@param file table
---@param is_selected boolean
---@return number start_line
---@return number end_line
local function append_file_line(result, file, is_selected)
	local path = file_path(file)
	local stats = file_stats(file)
	local icon = file_icon(file, is_selected)
	local type_label = file_type_label(file)
	local left = string.format("%s %s %s", icon, type_label, path)
	local line_index, _, rows = add_panel_line(result, align_right(left, stats), file_hl_group(file, is_selected))
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
	for _, raw_line in ipairs(file.diff_lines or {}) do
		local diff_line = display_diff_line(raw_line, file)
		local line_index, _, rows = render.add_panel_raw_line(result, "  " .. diff_line, diff_hl_group(raw_line), {
			prefix = PANEL_PREFIX,
		})
		start_line = start_line or line_index
		end_line = rows[#rows].line_index
		if
			lang
			and raw_line:sub(1, 3) ~= "+++"
			and raw_line:sub(1, 3) ~= "---"
			and not raw_line:match("^@@")
			and (raw_line:sub(1, 1) == "+" or raw_line:sub(1, 1) == "-" or raw_line:sub(1, 1) == " ")
		then
			local code = raw_line:sub(2)
			if code ~= "" then
				syntax.add_highlights(result, code, lang, {
					scope = "diffs",
					line_start = line_index,
					col_offset = (#PANEL_PREFIX) + (#"  ") + 1,
				})
			end
		end
	end
	return start_line, end_line
end

---@param result table
---@param edit_state table
local function append_hint_lines(result, edit_state)
	local is_readonly = edit_state.review_mode == "readonly"
	if is_readonly then
		add_panel_line(result, "Keys: <C-a>/Enter approve  <C-x>/Esc reject  = inline diff", "OpenCodeEditMuted")
		add_panel_line(result, "      A approve all  X reject all  m message  1-9 jump", "OpenCodeEditMuted")
		return
	end

	add_panel_line(result, "Keys: <C-a> accept  <C-x> reject  <C-m> resolve  = inline diff", "OpenCodeEditMuted")
	add_panel_line(result, "      Enter open  A accept all  X reject all  M resolve all", "OpenCodeEditMuted")
	add_panel_line(result, "      m message  dv diff split  dt diff tab  1-9 jump", "OpenCodeEditMuted")
end

---@param edit_state table
---@return number
function M.get_first_file_line(edit_state)
	local line = 2 -- header + panel blank
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
	local header, target = build_header(edit_state)
	local _, _, header_rows = add_panel_line(result, header, "OpenCodeEditHeader")
	add_path_highlight(result, header_rows, target, "OpenCodeEditPath")
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
		local file_start, file_end = append_file_line(result, file, i == selected)
		if expanded_files[i] and file.diff_lines and #file.diff_lines > 0 then
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
	append_hint_lines(result, edit_state)
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

	local header, target = build_header(edit_state, resolution_label)
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	add_path_highlight(result, header_rows, target, "OpenCodeEditPath")
	add_panel_blank(result)

	if edit_state.message and edit_state.message ~= "" then
		append_message_lines(result, edit_state.message)
		add_panel_blank(result)
	end

	for _, file in ipairs(edit_state.files or {}) do
		append_file_line(result, file, false)
	end

	if #(edit_state.files or {}) == 0 then
		add_panel_line(result, "No file changes detected.", "OpenCodeEditMuted")
	end

	add_trailing_separator(result)
	return result.lines, result.highlights
end

return M
