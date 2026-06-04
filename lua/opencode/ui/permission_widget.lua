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

local panel_helpers = panel.create_helpers({
	prefix = PANEL_PREFIX,
	blank_prefix = PANEL_EMPTY,
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodePermissionOutput",
})
local get_hl = panel_helpers.get_hl
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator
local highlight_panel_text = panel_helpers.highlight_text

local TOOL_INPUT_FIELDS = {
	"command",
	"description",
	"workdir",
	"cwd",
	"directory",
	"parentDir",
	"path",
	"file_path",
	"filePath",
	"filepath",
	"file",
	"pattern",
	"query",
	"url",
	"subagent_type",
	"subagentType",
}

local TOOL_DISPLAY_NAMES = {
	apply_patch = "Apply Patch",
	bash = "Bash",
	codesearch = "Code Search",
	edit = "Edit",
	glob = "Glob",
	grep = "Grep",
	list = "List",
	neovim_apply_patch = "Neovim Apply Patch",
	neovim_edit = "Neovim Edit",
	read = "Read",
	skill = "Skill",
	task = "Task",
	todoread = "Read Todos",
	todowrite = "Update Todos",
	webfetch = "WebFetch",
	websearch = "Web Search",
	write = "Write",
}

---@param name string
---@param fg_source string
---@param fallback string|nil
---@param extra_opts table|nil
local function set_panel_hl(name, fg_source, fallback, extra_opts)
	panel_helpers.set_hl(name, fg_source, fallback, extra_opts)
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

---@param value any
---@return table|nil
local function as_table(value)
	if type(value) == "table" then
		return value
	end
	if type(value) == "string" and value ~= "" then
		local ok, decoded = pcall(vim.json.decode, value)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return nil
end

---@param dest table
---@param key string
---@param value any
local function set_non_empty(dest, key, value)
	if type(value) == "string" then
		if value ~= "" then
			dest[key] = value
		end
	elseif value ~= nil then
		dest[key] = value
	end
end

---@param dest table
---@param source table|nil
local function merge_tool_input_source(dest, source)
	source = as_table(source)
	if not source then
		return
	end

	for _, key in ipairs(TOOL_INPUT_FIELDS) do
		set_non_empty(dest, key, source[key])
	end

	set_non_empty(dest, "directory", source.directory or source.parentDir)
	set_non_empty(dest, "subagent_type", source.subagent_type or source.subagentType)
end

---@param part table
---@return table
local function extract_tool_input(part)
	local fresh = {}
	local tool_state = type(part.state) == "table" and part.state or {}

	merge_tool_input_source(fresh, render.get_tool_metadata(part))
	merge_tool_input_source(fresh, part.input)
	merge_tool_input_source(fresh, tool_state.input)

	return fresh
end

---@param tool_name any
---@return string
local function format_tool_name(tool_name)
	if type(tool_name) ~= "string" then
		return ""
	end

	local trimmed = vim.trim(tool_name)
	if trimmed == "" then
		return ""
	end

	local mapped = TOOL_DISPLAY_NAMES[trimmed:lower()]
	if mapped then
		return mapped
	end

	local spaced = trimmed:gsub("([a-z0-9])([A-Z])", "%1 %2"):gsub("[_%.-]+", " ")
	return (spaced:gsub("(%S)(%S*)", function(first, rest)
		return first:upper() .. rest
	end))
end

---@param part table
---@return string
local function extract_tool_name(part)
	if type(part) ~= "table" then
		return ""
	end

	local tool_state = type(part.state) == "table" and part.state or {}
	local metadata = render.get_tool_metadata(part)
	return first_non_empty(
		part.tool,
		part.tool_name,
		part.toolName,
		tool_state.tool,
		tool_state.tool_name,
		tool_state.toolName,
		metadata.tool,
		metadata.tool_name,
		metadata.toolName
	)
end

---@param part table
---@param call_id string
---@return boolean
local function part_matches_call(part, call_id)
	local part_call_id = part.callID or part.call_id or part.callId
	return type(part_call_id) == "string" and part_call_id ~= "" and part_call_id == call_id
end

---@param message_id string|nil
---@param call_id string|nil
---@return table|nil
local function find_tool_part(message_id, call_id)
	if type(message_id) ~= "string" or message_id == "" or type(call_id) ~= "string" or call_id == "" then
		return nil
	end

	local ok, sync = pcall(require, "opencode.sync")
	if not ok or type(sync.get_parts) ~= "function" then
		return nil
	end

	for _, part in ipairs(sync.get_parts(message_id)) do
		if part_matches_call(part, call_id) then
			return part
		end
	end

	return nil
end

---@param permission_id string
---@param perm_state table
---@param tool_name string
local function persist_tool_name(permission_id, perm_state, tool_name)
	if tool_name == "" or perm_state.tool_name == tool_name then
		return
	end

	local ok_state, permission_state = pcall(require, "opencode.permission.state")
	if ok_state and type(permission_state.set_tool_name) == "function" then
		permission_state.set_tool_name(permission_id, tool_name)
	else
		perm_state.tool_name = tool_name
	end
end

---@param permission_id string
---@param perm_state table
---@return table
local function resolve_tool_input(permission_id, perm_state)
	local current = type(perm_state.tool_input) == "table" and perm_state.tool_input or {}
	local part = find_tool_part(perm_state.message_id, perm_state.call_id)
	if not part then
		return current
	end

	persist_tool_name(permission_id, perm_state, extract_tool_name(part))

	local fresh = extract_tool_input(part)
	if not next(fresh) then
		return current
	end

	local merged = vim.tbl_deep_extend("force", {}, current, fresh)
	if not vim.deep_equal(current, merged) then
		local ok_state, permission_state = pcall(require, "opencode.permission.state")
		if ok_state and type(permission_state.merge_tool_input) == "function" then
			permission_state.merge_tool_input(permission_id, fresh)
		else
			perm_state.tool_input = merged
		end
	end

	return merged
end

---@param permission_id string
---@param perm_state table
---@return string
local function resolve_tool_name(permission_id, perm_state)
	local tool_name = first_non_empty(perm_state.tool_name)
	if tool_name ~= "" then
		return tool_name
	end

	local metadata = type(perm_state.metadata) == "table" and perm_state.metadata or {}
	tool_name = first_non_empty(metadata.tool, metadata.tool_name, metadata.toolName)
	if tool_name ~= "" then
		persist_tool_name(permission_id, perm_state, tool_name)
		return tool_name
	end

	local part = find_tool_part(perm_state.message_id, perm_state.call_id)
	tool_name = extract_tool_name(part)
	if tool_name ~= "" then
		persist_tool_name(permission_id, perm_state, tool_name)
		return tool_name
	end

	return ""
end

---@param permission_id string
---@param perm_state table
---@return string
local function permission_header_title(permission_id, perm_state)
	local tool_name = format_tool_name(resolve_tool_name(permission_id, perm_state))
	return tool_name ~= "" and ("for " .. tool_name) or ""
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
---@param permission_id string
---@param perm_state table Permission state from permission/state.lua
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_lines_for_permission(permission_id, perm_state)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local tool_input = resolve_tool_input(permission_id, perm_state)
	local header_title = permission_header_title(permission_id, perm_state)
	local desc_lines = get_permission_description(perm_state.permission_type, tool_input, perm_state)

	add_panel_blank(result)
	add_header(result, header_title, "pending")
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
---@param permission_id string
---@param perm_state table
---@return table lines, table highlights
function M.get_approved_lines(permission_id, perm_state)
	ensure_highlights()

	local reply_suffix = perm_state.reply == "always" and "(always)" or "(once)"
	local result = { lines = {}, highlights = {} }
	local tool_input = resolve_tool_input(permission_id, perm_state)
	local header_title = permission_header_title(permission_id, perm_state)
	local desc_lines = get_permission_description(perm_state.permission_type, tool_input, perm_state)

	add_panel_blank(result)
	add_header(result, header_title, "approved", reply_suffix)
	add_panel_blank(result)
	append_description(result, desc_lines)
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines, result.highlights
end

-- Get formatted lines for a rejected permission
---@param permission_id string
---@param perm_state table
---@return table lines, table highlights
function M.get_rejected_lines(permission_id, perm_state)
	ensure_highlights()

	local result = { lines = {}, highlights = {} }
	local tool_input = resolve_tool_input(permission_id, perm_state)
	local header_title = permission_header_title(permission_id, perm_state)
	local desc_lines = get_permission_description(perm_state.permission_type, tool_input, perm_state)

	add_panel_blank(result)
	add_header(result, header_title, "rejected")
	add_panel_blank(result)
	append_description(result, desc_lines)
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines, result.highlights
end

return M
