-- opencode.nvim - Permission widget module
-- Renders interactive permission prompts inline in chat buffer

local M = {}

local panel = require("opencode.ui.panel")
local render = require("opencode.ui.chat.render")
local widget_base = require("opencode.ui.widget_base")

local PANEL_PREFIX = "▏  "
local PANEL_EMPTY = "▏"
local PANEL_BORDER_HL = "OpenCodePermissionMuted"

local icons = {
	pending = "△",
	approved = "✓",
	rejected = "✗",
	selected = "❯",
	unselected = " ",
}

local OPTION_LABELS = {
	"Allow once",
	"Allow always",
	"Reject",
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

local function ensure_highlights()
	set_panel_hl("OpenCodePermissionMuted", "Comment", "Normal")
	set_panel_hl("OpenCodePermissionHeader", "Title", "Normal", { bold = true })
	set_panel_hl("OpenCodePermissionTitle", "Label", "Title", { bold = true })
	set_panel_hl("OpenCodePermissionOutput", "Normal", nil)
	set_panel_hl("OpenCodePermissionSelected", "Normal", "CursorLine", { bold = true })
	set_panel_hl("OpenCodePermissionApproved", "String", "Normal")
	set_panel_hl("OpenCodePermissionRejected", "DiagnosticError", "ErrorMsg")
	set_panel_hl("OpenCodePermissionPath", "String", "Normal", { bold = true })
	set_panel_hl("OpenCodePermissionCommand", "Special", "Normal")

	vim.api.nvim_set_hl(0, "OpenCodePermissionSelectedMarker", {
		fg = get_hl("Special").fg or get_hl("Title").fg,
		bg = get_hl("CursorLine").bg,
		bold = true,
	})
end

---@param result table
---@param text string
---@param hl_group string
---@return number line_index
---@return string line
---@return table[] rows
local function add_panel_line(result, text, hl_group)
	return panel.add_line(result, text, hl_group, {
		prefix = PANEL_PREFIX,
		prefix_hl_group = PANEL_BORDER_HL,
	})
end

---@param result table
---@param text string
---@param hl_group string
---@return number line_index
---@return string line
---@return table[] rows
local function add_panel_raw_line(result, text, hl_group)
	return panel.add_raw_line(result, text, hl_group, {
		prefix = PANEL_PREFIX,
		prefix_hl_group = PANEL_BORDER_HL,
	})
end

---@param result table
local function add_panel_blank(result)
	panel.add_blank(result, "OpenCodePermissionOutput", {
		prefix = PANEL_EMPTY,
		prefix_hl_group = PANEL_BORDER_HL,
	})
end

---@param result table
local function add_trailing_separator(result)
	table.insert(result.lines, "")
end

---@param result table
---@param rows table[]|nil
---@param text string
---@param hl_group string
local function highlight_panel_text(result, rows, text, hl_group)
	render.highlight_panel_text(result, rows, text, hl_group)
end

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

---@param line string|nil
---@return string
local function clean_description_line(line)
	if type(line) ~= "string" then
		return ""
	end
	return (line:gsub("^#%s*", ""):gsub("^%s+", ""))
end

---@param description_lines table
---@return string
local function description_title(description_lines)
	local title = clean_description_line(description_lines[1])
	return title ~= "" and title or "Permission"
end

---@param label string
---@return string
local function detail_value_hl(label)
	if label == "Path" then
		return "OpenCodePermissionPath"
	end
	if label == "Command" then
		return "OpenCodePermissionCommand"
	end
	return "OpenCodePermissionOutput"
end

---@param result table
---@param line string
local function append_description_detail(result, line)
	local text = clean_description_line(line)
	if text == "" then
		add_panel_blank(result)
		return
	end

	local label, value = text:match("^([^:]+):%s*(.*)$")
	local _, _, rows = add_panel_line(result, text, "OpenCodePermissionMuted")
	if label and value and value ~= "" then
		highlight_panel_text(result, rows, value, detail_value_hl(label))
	end
end

---@param result table
---@param desc_lines table
local function append_description(result, desc_lines)
	local title = description_title(desc_lines)
	local _, _, title_rows = add_panel_line(result, title, "OpenCodePermissionTitle")
	highlight_panel_text(result, title_rows, title, "OpenCodePermissionTitle")

	for i = 2, #desc_lines do
		append_description_detail(result, desc_lines[i])
	end
end

---@param result table
---@param title string
---@param status "pending"|"approved"|"rejected"
---@param suffix string|nil
local function add_header(result, title, status, suffix)
	local header = "# Permission"
	if status == "pending" then
		header = "# Permission required"
	elseif status == "approved" then
		header = "# Permission allowed"
	elseif status == "rejected" then
		header = "# Permission rejected"
	end
	if title ~= "" then
		header = header .. " " .. title
	end
	if suffix and suffix ~= "" then
		header = header .. " " .. suffix
	end

	local hl_group = "OpenCodePermissionHeader"
	if status == "approved" then
		hl_group = "OpenCodePermissionApproved"
	elseif status == "rejected" then
		hl_group = "OpenCodePermissionRejected"
	end

	local _, _, rows = add_panel_line(result, header, hl_group)
	if title ~= "" then
		highlight_panel_text(result, rows, title, "OpenCodePermissionTitle")
	end
end

---@param result table
---@param option_count number
local function append_hint(result, option_count)
	local hint = string.format("1-%d select · ↑↓ move · Enter confirm · Esc reject · m message", option_count)
	add_panel_line(result, hint, "OpenCodePermissionMuted")
end

-- Get formatted lines for a pending permission
---@param _permission_id string
---@param perm_state table Permission state from permission/state.lua
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_lines_for_permission(_permission_id, perm_state)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input, perm_state)

	add_panel_blank(result)
	add_header(result, "", "pending")
	add_panel_blank(result)
	append_description(result, desc_lines)
	add_panel_blank(result)

	local first_option_line = #result.lines
	local selected = perm_state.selected_option or 1

	for i, label in ipairs(OPTION_LABELS) do
		local is_selected = i == selected
		local indicator = is_selected and icons.selected or icons.unselected
		local option_text = string.format("%s %d. %s", indicator, i, label)
		local _, _, rows = add_panel_raw_line(
			result,
			option_text,
			is_selected and "OpenCodePermissionSelected" or "OpenCodePermissionOutput"
		)
		if is_selected then
			highlight_panel_text(result, rows, indicator, "OpenCodePermissionSelectedMarker")
		end
	end

	add_panel_blank(result)
	append_hint(result, #OPTION_LABELS)
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines,
		result.highlights,
		widget_base.make_meta({
			interactive_count = #OPTION_LABELS,
			first_interactive_line = first_option_line,
		})
end

-- Get formatted lines for an approved permission
---@param _permission_id string
---@param perm_state table
---@return table lines, table highlights
function M.get_approved_lines(_permission_id, perm_state)
	ensure_highlights()

	local reply_suffix = perm_state.reply == "always" and "(always)" or "(once)"
	local result = { lines = {}, highlights = {} }
	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input, perm_state)

	add_panel_blank(result)
	add_header(result, "", "approved", reply_suffix)
	add_panel_blank(result)
	append_description(result, desc_lines)
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines, result.highlights
end

-- Get formatted lines for a rejected permission
---@param _permission_id string
---@param perm_state table
---@return table lines, table highlights
function M.get_rejected_lines(_permission_id, perm_state)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input, perm_state)

	add_panel_blank(result)
	add_header(result, "", "rejected")
	add_panel_blank(result)
	append_description(result, desc_lines)
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines, result.highlights
end

return M
