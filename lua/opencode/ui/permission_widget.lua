-- opencode.nvim - Permission widget module
-- Renders interactive permission prompts inline in chat buffer

local M = {}
local widget_base = require("opencode.ui.widget_base")

local icons = {
	pending = "△",
	approved = "✓",
	rejected = "✗",
	selected = "❯",
	unselected = "  ",
}

local OPTION_LABELS = {
	"Allow once",
	"Allow always",
	"Reject",
}

---@param ... any
---@return string
local function first_non_empty(...)
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if type(value) == "string" and value ~= "" then
			return value
		end
	end

	return ""
end

-- Normalize filepath to cwd-relative or ~-prefixed
---@param filepath string
---@return string
local function normalize_path(filepath)
	if not filepath or filepath == "" then
		return filepath or ""
	end

	local cwd = vim.fn.getcwd()
	if cwd:sub(-1) ~= "/" then
		cwd = cwd .. "/"
	end

	-- Try cwd-relative
	if filepath:sub(1, #cwd) == cwd then
		return filepath:sub(#cwd + 1)
	end

	-- Try home-relative
	local home = os.getenv("HOME") or ""
	if home ~= "" and filepath:sub(1, #home) == home then
		return "~" .. filepath:sub(#home + 1)
	end

	return filepath
end

---@param title string
---@return string
local function summary_line(title)
	return "# " .. title
end

---@param permission_type string
---@param tool_input table
---@param perm_state? table
---@return string
local function get_permission_path(permission_type, tool_input, perm_state)
	local metadata = (perm_state and perm_state.metadata) or {}
	local patterns = (perm_state and perm_state.patterns) or {}
	local cwd = normalize_path(vim.fn.getcwd())

	if permission_type == "bash" then
		return normalize_path(first_non_empty(
			tool_input.workdir,
			tool_input.cwd,
			tool_input.directory,
			tool_input.path,
			metadata.workdir,
			metadata.cwd,
			metadata.directory,
			metadata.path,
			cwd
		))
	end

	if permission_type == "read" then
		return normalize_path(
			first_non_empty(
				tool_input.file_path,
				tool_input.filePath,
				tool_input.filepath,
				tool_input.file,
				tool_input.path,
				tool_input.pattern,
				metadata.file_path,
				metadata.filePath,
				metadata.filepath,
				metadata.file,
				metadata.path,
				metadata.pattern,
				patterns[1]
			)
		)
	end

	if permission_type == "glob" or permission_type == "grep" or permission_type == "list" then
		return normalize_path(first_non_empty(
			tool_input.path,
			metadata.path,
			tool_input.directory,
			metadata.directory,
			cwd
		))
	end

	if permission_type == "external_directory" then
		return normalize_path(first_non_empty(
			tool_input.file_path,
			tool_input.filePath,
			tool_input.filepath,
			tool_input.file,
			metadata.file_path,
			metadata.filePath,
			metadata.filepath,
			metadata.file,
			tool_input.directory,
			tool_input.path,
			metadata.directory,
			metadata.parentDir,
			metadata.path,
			patterns[1]
		))
	end

	return normalize_path(first_non_empty(
		tool_input.file_path,
		tool_input.filePath,
		tool_input.filepath,
		tool_input.file,
		tool_input.path,
		tool_input.directory,
		metadata.file_path,
		metadata.filePath,
		metadata.filepath,
		metadata.file,
		metadata.path,
		metadata.directory,
		patterns[1]
	))
end

---@param lines table
---@param label string
---@param value string
---@return table
local function with_detail_lines(lines, label, value)
	if value == "" then
		return lines
	end

	local parts = vim.split(value, "\n", { plain = true })
	for i, part in ipairs(parts) do
		local prefix = i == 1 and string.format("  %s: ", label) or string.rep(" ", #label + 4)
		table.insert(lines, prefix .. part)
	end

	return lines
end

---@param lines table
---@param path string
---@return table
local function with_path_line(lines, path)
	return with_detail_lines(lines, "Path", path)
end

---@param lines table
---@param message string|nil
---@return table
local function with_message_lines(lines, message)
	return with_detail_lines(lines, "Message", vim.trim(message or ""))
end

---@param lines table
---@param permission_type string
---@param tool_input table
---@param perm_state? table
---@return table
local function with_common_tool_details(lines, permission_type, tool_input, perm_state)
	lines = with_detail_lines(lines, "Command", tool_input.command or "")
	lines = with_path_line(lines, get_permission_path(permission_type, tool_input, perm_state))
	lines = with_detail_lines(lines, "Pattern", tool_input.pattern or "")
	lines = with_detail_lines(lines, "Query", tool_input.query or "")
	lines = with_detail_lines(lines, "URL", tool_input.url or "")
	lines = with_detail_lines(lines, "Agent", tool_input.subagent_type or "")
	lines = with_detail_lines(lines, "Description", tool_input.description or "")
	return lines
end

-- Get description lines for a permission based on type
---@param permission_type string
---@param tool_input table
---@param perm_state? table
---@return table lines Array of description lines
local function get_permission_description(permission_type, tool_input, perm_state)
	tool_input = tool_input or {}

	if permission_type == "bash" then
		local lines = with_common_tool_details({ summary_line("Bash") }, permission_type, tool_input, perm_state)
		if #lines == 1 then
			lines = with_detail_lines(lines, "Description", "Run bash command")
		end
		return with_message_lines(lines, perm_state and perm_state.message)
	elseif permission_type == "read" then
		return with_message_lines(
			with_common_tool_details({ summary_line("Read") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "glob" then
		return with_message_lines(
			with_common_tool_details({ summary_line("Glob") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "grep" then
		return with_message_lines(
			with_common_tool_details({ summary_line("Grep") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "list" then
		return with_message_lines(
			with_common_tool_details({ summary_line("List") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "webfetch" then
		return with_message_lines(
			with_common_tool_details({ summary_line("WebFetch") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "websearch" then
		return with_message_lines(
			with_common_tool_details({ summary_line("Web Search") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "codesearch" then
		return with_message_lines(
			with_common_tool_details({ summary_line("Code Search") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "external_directory" then
		return with_message_lines(
			with_common_tool_details({ summary_line("External directory") }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	elseif permission_type == "diff_review" then
		return with_message_lines({ summary_line("Diff review") }, perm_state and perm_state.message)
	elseif permission_type == "doom_loop" then
		return with_message_lines({ summary_line("Continue after repeated failures") }, perm_state and perm_state.message)
	elseif permission_type == "task" then
		local lines = with_common_tool_details({ summary_line("Task") }, permission_type, tool_input, perm_state)
		return with_message_lines(lines, perm_state and perm_state.message)
	else
		return with_message_lines(
			with_common_tool_details({ summary_line(permission_type) }, permission_type, tool_input, perm_state),
			perm_state and perm_state.message
		)
	end
end

-- Get formatted lines for a pending permission
---@param permission_id string
---@param perm_state table Permission state from permission/state.lua
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_lines_for_permission(permission_id, perm_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	-- Header
	local header = widget_base.format_header(icons.pending, "Permission required", permission_id, perm_state.timestamp)
	table.insert(lines, header)
	widget_base.add_full_line_highlight(highlights, line_num, header, "Title")
	line_num = line_num + 1

	-- Separator
	table.insert(lines, widget_base.separator())
	line_num = line_num + 1

	-- Permission description
	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input, perm_state)
	for _, dline in ipairs(desc_lines) do
		table.insert(lines, dline)
		table.insert(highlights, {
			line = line_num,
			col_start = 0,
			col_end = #dline,
			hl_group = "Normal",
		})
		line_num = line_num + 1
	end

	-- Blank line before options
	table.insert(lines, "")
	line_num = line_num + 1

	-- Options
	local first_option_line = line_num
	local selected = perm_state.selected_option or 1

	for i, label in ipairs(OPTION_LABELS) do
		local is_selected = i == selected
		local indicator = is_selected and icons.selected or icons.unselected
		local option_text = string.format("%s %d. %s", indicator, i, label)
		table.insert(lines, option_text)

		if is_selected then
			widget_base.add_full_line_highlight(highlights, line_num, option_text, "CursorLine")
		end

		line_num = line_num + 1
	end

	-- Keymap hint
	table.insert(lines, "")
	line_num = line_num + 1

	local hint = "[1-3 select, m message, ↑↓ navigate, Enter confirm, Esc reject]"
	table.insert(lines, hint)
	widget_base.add_full_line_highlight(highlights, line_num, hint, "Comment")
	line_num = line_num + 1

	-- Trailing blank line
	table.insert(lines, "")

	return lines,
		highlights,
		widget_base.make_meta({
			interactive_count = #OPTION_LABELS,
			first_interactive_line = first_option_line,
		})
end

-- Get formatted lines for an approved permission
---@param permission_id string
---@param perm_state table
---@return table lines, table highlights
function M.get_approved_lines(permission_id, perm_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local reply_label = perm_state.reply == "always" and "Allowed (always)" or "Allowed (once)"
	local header = widget_base.format_header(icons.approved, "Permission", permission_id, perm_state.timestamp)
	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #icons.approved + 1,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	table.insert(lines, widget_base.separator())
	line_num = line_num + 1

	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input, perm_state)
	local summary = (desc_lines[1] or perm_state.permission_type):gsub("^#%s*", "")
	local display = summary .. " - " .. reply_label
	table.insert(lines, display)
	table.insert(highlights, {
		line = line_num,
		col_start = #summary + 1,
		col_end = #display,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	for i = 2, #desc_lines do
		local dline = desc_lines[i]
		table.insert(lines, dline)
		widget_base.add_full_line_highlight(highlights, line_num, dline, "Normal")
		line_num = line_num + 1
	end

	table.insert(lines, "")

	return lines, highlights
end

-- Get formatted lines for a rejected permission
---@param permission_id string
---@param perm_state table
---@return table lines, table highlights
function M.get_rejected_lines(permission_id, perm_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local header = widget_base.format_header(icons.rejected, "Permission", permission_id, perm_state.timestamp)
	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #icons.rejected + 1,
		hl_group = "Error",
	})
	line_num = line_num + 1

	table.insert(lines, widget_base.separator())
	line_num = line_num + 1

	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input, perm_state)
	local summary = (desc_lines[1] or perm_state.permission_type):gsub("^#%s*", "")
	local display = summary .. " - Rejected"
	table.insert(lines, display)
	table.insert(highlights, {
		line = line_num,
		col_start = #summary + 1,
		col_end = #display,
		hl_group = "Error",
	})
	line_num = line_num + 1

	for i = 2, #desc_lines do
		local dline = desc_lines[i]
		table.insert(lines, dline)
		widget_base.add_full_line_highlight(highlights, line_num, dline, "Normal")
		line_num = line_num + 1
	end

	table.insert(lines, "")

	return lines, highlights
end

return M
