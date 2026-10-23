-- opencode.nvim - Permission widget module
-- Renders interactive permission prompts inline in chat buffer

local M = {}

local panel = require("opencode.ui.panel")
local render = require("opencode.ui.chat.render")
local syntax = require("opencode.ui.syntax")
local widget_base = require("opencode.ui.widget_base")

local PANEL_PREFIX = "▏  "
local PANEL_PREFIX_WIDTH = vim.api.nvim_strwidth(PANEL_PREFIX)
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
	"Always allow",
	"Reject",
}
local MAX_PERMISSION_COMMAND_HEAD_LINES = 8
local MAX_PERMISSION_COMMAND_TAIL_LINES = 4
-- Permission types whose request is a shell command: native "shell" and the bash tool's own "bash".
local SHELL_PERMISSION_TYPES = { bash = true, shell = true }

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
	"type",
	"glob",
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
	neovim_patch = "Neovim Patch",
	neovim_edit = "Neovim Edit",
	read = "Read",
	rg = "Ripgrep",
	skill = "Skill",
	task = "Task",
	webfetch = "WebFetch",
	websearch = "Web Search",
	write = "Write",
}

local PERMISSION_TITLES = {
	external_directory = "External directory",
	diff_review = "Diff review",
	doom_loop = "Continue after repeated failures",
}
for _, tool in ipairs({ "bash", "read", "glob", "grep", "rg", "list", "webfetch", "websearch", "codesearch", "task" }) do
	PERMISSION_TITLES[tool] = TOOL_DISPLAY_NAMES[tool]
end

local set_panel_hl = panel_helpers.set_hl

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

	vim.api.nvim_set_hl(0, "OpenCodePermissionSelectedMarker", widget_base.selected_marker_hl(get_hl))
end

require("opencode.ui.highlights").register("opencode.ui.permission_widget", ensure_highlights)

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

---@param part table|nil
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

---@param perm_state table
---@return table
local function resolve_tool_input(perm_state)
	local current = type(perm_state.tool_input) == "table" and perm_state.tool_input or {}
	local part = find_tool_part(perm_state.message_id, perm_state.call_id)
	if not part then
		return vim.tbl_deep_extend("force", {}, current)
	end

	local fresh = extract_tool_input(part)
	if not next(fresh) then
		return vim.tbl_deep_extend("force", {}, current)
	end

	return vim.tbl_deep_extend("force", {}, current, fresh)
end

---@param perm_state table
---@return string
local function resolve_tool_name(perm_state)
	local tool_name = first_non_empty(perm_state.tool_name)
	if tool_name ~= "" then
		return tool_name
	end

	local metadata = type(perm_state.metadata) == "table" and perm_state.metadata or {}
	tool_name = first_non_empty(metadata.tool, metadata.tool_name, metadata.toolName)
	if tool_name ~= "" then
		return tool_name
	end

	local part = find_tool_part(perm_state.message_id, perm_state.call_id)
	tool_name = extract_tool_name(part)
	return tool_name
end

---@param perm_state table
---@return string
local function permission_header_title(perm_state)
	local tool_name = format_tool_name(resolve_tool_name(perm_state))
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

---Working directory of a shell request, or "" when it runs in the current directory.
---@param tool_input table
---@param perm_state? table
---@return string
local function shell_workdir(tool_input, perm_state)
	local metadata = (perm_state and perm_state.metadata) or {}
	local workdir = normalize_path(first_non_empty(
		tool_input.workdir,
		tool_input.cwd,
		tool_input.directory,
		tool_input.path,
		metadata.workdir,
		metadata.cwd,
		metadata.directory,
		metadata.path
	))
	return workdir ~= normalize_path(vim.fn.getcwd()) and workdir or ""
end

---@param permission_type string
---@param tool_input table
---@param perm_state? table
---@return string
local function get_permission_path(permission_type, tool_input, perm_state)
	local metadata = (perm_state and perm_state.metadata) or {}
	local patterns = (perm_state and perm_state.patterns) or {}
	local cwd = normalize_path(vim.fn.getcwd())

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

	if permission_type == "glob" or permission_type == "grep" or permission_type == "rg" or permission_type == "list" then
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

---@class OpenCodePermissionDetail
---@field label string
---@field value string

---@class OpenCodePermissionDescription
---@field title string
---@field shell boolean Shell request: the command is the requested resource
---@field command string Command the request runs, or ""
---@field details OpenCodePermissionDetail[]
---@field resources string[] Requested authorization resources
---@field message string Message attached to the reply, or ""

-- Get the description of a permission based on type
---@param permission_type string
---@param tool_input table
---@param perm_state? table
---@return OpenCodePermissionDescription
local function get_permission_description(permission_type, tool_input, perm_state)
	tool_input = tool_input or {}
	perm_state = perm_state or {}
	local description = {
		title = PERMISSION_TITLES[permission_type] or permission_type,
		shell = SHELL_PERMISSION_TYPES[permission_type] == true,
		command = "",
		details = {},
		resources = {},
		message = vim.trim(first_non_empty(perm_state.message)),
	}
	local function add(label, value)
		if type(value) == "string" and value ~= "" then
			table.insert(description.details, { label = label, value = value })
		end
	end

	if permission_type ~= "diff_review" and permission_type ~= "doom_loop" then
		description.command = vim.trim(first_non_empty(tool_input.command))
		add("Path", description.shell and shell_workdir(tool_input, perm_state)
			or get_permission_path(permission_type, tool_input, perm_state))
		add("Pattern", tool_input.pattern)
		add("Type", tool_input.type)
		add("Glob", tool_input.glob)
		add("Query", tool_input.query)
		add("URL", tool_input.url)
		add("Agent", tool_input.subagent_type)
		add("Description", tool_input.description)
		if permission_type == "bash" and description.command == "" and #description.details == 0 then
			add("Description", "Run bash command")
		end
	end

	for _, resource in ipairs(perm_state.patterns or {}) do
		if type(resource) == "string" and vim.trim(resource) ~= "" then
			table.insert(description.resources, resource)
		end
	end
	return description
end

---@param text string
---@param fragment string
---@return boolean
local function contains(text, fragment)
	fragment = vim.trim(fragment)
	return fragment ~= "" and text:find(fragment, 1, true) ~= nil
end

---Requested resources the reader cannot already see: in the shown command
---(shell requests only) or as a shown detail value. Every other resource
---stays listed so no authorization scope is hidden.
---@param description OpenCodePermissionDescription
---@param shown_command string Command shown in full, or ""
---@param shown_details? OpenCodePermissionDetail[]
---@return string[]
local function unshown_resources(description, shown_command, shown_details)
	local shown = {}
	for _, detail in ipairs(shown_details or {}) do
		shown[detail.value] = true
	end
	local resources = {}
	for _, resource in ipairs(description.resources) do
		if not shown[resource] and not (description.shell and contains(shown_command, resource)) then
			table.insert(resources, resource)
		end
	end
	return resources
end

---@param label string
---@return string
local function detail_value_hl(label)
	if label == "Path" then
		return "OpenCodePermissionPath"
	end
	return "OpenCodePermissionOutput"
end

---"Label: value", with continuation and wrapped rows aligned under the value.
---@param result table
---@param label string
---@param value string
local function append_detail(result, label, value)
	local head = label .. ": "
	local indent = string.rep(" ", #head)
	for index, line in ipairs(vim.split(value, "\n", { plain = true })) do
		local _, _, rows = add_panel_raw_line(result, line, detail_value_hl(label), {
			body_prefix = index == 1 and head or indent,
			continuation_prefix = indent,
		})
		if index == 1 then
			highlight_panel_text(result, rows, head, "OpenCodePermissionMuted")
		end
	end
end

---@param result table
---@param details OpenCodePermissionDetail[]
---@param resources string[]
---@param message string
---@return boolean added
local function append_details(result, details, resources, message)
	local count = #result.lines
	for _, detail in ipairs(details) do
		append_detail(result, detail.label, detail.value)
	end
	for _, resource in ipairs(resources) do
		append_detail(result, "Resource", resource)
	end
	if message ~= "" then
		append_detail(result, "Message", message)
	end
	return #result.lines > count
end

---@param result table
---@param lines string[]
---@param first boolean Lines start the command
---@param highlight boolean
local function append_command_lines(result, lines, first, highlight)
	local start_line = nil
	local displayed = {}
	for i, source in ipairs(lines) do
		local line = (result.render or render).expand_tabs(source, PANEL_PREFIX_WIDTH + 2)
		local prefix = (first and i == 1) and "$ " or "  "
		local line_index, _, rows = add_panel_raw_line(result, prefix .. line, "OpenCodePermissionCommand")
		start_line = start_line or line_index
		highlight = highlight and #rows == 1
		table.insert(displayed, line)
	end
	if start_line and highlight then
		syntax.add_highlights(result, table.concat(displayed, "\n"), "bash", {
			scope = "tools",
			line_start = start_line,
			col_offset = #PANEL_PREFIX + #"$ ",
		})
	end
end

---Render a command the way the bash row does: "$ " prompt, indented
---continuation lines and shell syntax. A long command keeps its head and tail,
---unless a requested resource lies in the lines that would be hidden.
---@param result table
---@param command string
---@param resources string[]
local function append_command(result, command, resources)
	local lines = vim.split(command, "\n", { plain = true })
	local head_count, tail_count = MAX_PERMISSION_COMMAND_HEAD_LINES, MAX_PERMISSION_COMMAND_TAIL_LINES
	local head = vim.list_slice(lines, 1, head_count)
	local tail = vim.list_slice(lines, #lines - tail_count + 1)
	local fold = #lines > head_count + tail_count
	if fold then
		local head_text, tail_text = table.concat(head, "\n"), table.concat(tail, "\n")
		for _, resource in ipairs(resources) do
			if contains(command, resource) and not contains(head_text, resource) and not contains(tail_text, resource) then
				fold = false
				break
			end
		end
	end
	if not fold then
		append_command_lines(result, lines, true, true)
		return
	end

	append_command_lines(result, head, true, true)
	local hidden = #lines - head_count - tail_count
	add_panel_line(result, "  … (" .. tostring(hidden) .. " command lines hidden)", "OpenCodePermissionMuted")
	-- A tail fragment can start inside a quote; it keeps the plain command colour.
	append_command_lines(result, tail, false, false)
end

---@param result table
---@param description OpenCodePermissionDescription
local function append_description(result, description)
	local _, _, title_rows = add_panel_line(result, description.title, "OpenCodePermissionTitle")
	highlight_panel_text(result, title_rows, description.title, "OpenCodePermissionTitle")

	local resources = unshown_resources(description, description.command, description.details)
	local has_details = #description.details + #resources > 0 or description.message ~= ""
	if description.command ~= "" then
		add_panel_blank(result)
		append_command(result, description.command, description.resources)
		if has_details then
			add_panel_blank(result)
		end
	end
	append_details(result, description.details, resources, description.message)
end

---Shell command the tool row above shows in full, or nil when this widget
---must show the request itself.
---@param perm_state table
---@param opts? table
---@return string|nil
local function tool_row_command(perm_state, opts)
	local row = opts and opts.tool_row
	if type(row) ~= "table" or row.folded or not SHELL_PERMISSION_TYPES[perm_state.permission_type] then
		return nil
	end
	local command = vim.trim(first_non_empty(row.command))
	return command ~= "" and command or nil
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

	local hl_group = "OpenCodePermissionHeader"
	if status == "approved" then
		hl_group = "OpenCodePermissionApproved"
	elseif status == "rejected" then
		hl_group = "OpenCodePermissionRejected"
	end

	widget_base.add_status_header(panel_helpers, result, header, title, suffix, hl_group, "OpenCodePermissionTitle")
end

---@param result table
---@param option_count number
local function append_hint(result, option_count)
	local keymaps = require("opencode.util.keymap")
	local keys = (require("opencode.ui.chat.state").state.config or {}).keymaps
	local function key(action) return keymaps.label("chat", action, keys) end
	local select_part, move_part = widget_base.selection_hint(option_count, keys)
	local hint = select_part .. " · " .. move_part .. " · " .. key("confirm") .. " confirm · "
		.. key("widget_message") .. " message"
	add_panel_line(result, hint, "OpenCodePermissionMuted")
end

-- Get formatted lines for a pending permission
---@param _permission_id string Unused; kept for the public signature
---@param perm_state table Permission state from permission/state.lua
---@param opts? table { width?: number, render?: table, tool_row?: table }
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.get_lines_for_permission(_permission_id, perm_state, opts)
	local result = widget_base.new_result(opts)
	local tool_input = resolve_tool_input(perm_state)
	local header_title = permission_header_title(perm_state)
	local description = get_permission_description(perm_state.permission_type, tool_input, perm_state)
	local row_command = tool_row_command(perm_state, opts)

	add_panel_blank(result)
	add_header(result, header_title, "pending")
	add_panel_blank(result)
	if not row_command then
		append_description(result, description)
		add_panel_blank(result)
	elseif append_details(result, {}, unshown_resources(description, row_command), description.message) then
		-- The tool row above shows the command; keep only what it does not.
		add_panel_blank(result)
	end

	if perm_state.status == "unavailable" or perm_state.submitting then
		add_panel_line(result, perm_state.submitting and "Sending decision…" or "Request is no longer pending", "OpenCodePermissionMuted")
		add_trailing_separator(result)
		return result.lines, result.highlights, widget_base.make_meta()
	end
	if perm_state.error then
		add_panel_line(result, perm_state.error.message or "Unable to confirm decision", "OpenCodePermissionError")
	end
	local first_option_line = #result.lines
	local selected = perm_state.selected_option or 1
	local save = perm_state.always or {}
	local options = #save > 0 and OPTION_LABELS or { OPTION_LABELS[1], OPTION_LABELS[3] }

	local option_lines, option_end_lines = widget_base.append_options(result, options, function(i)
		return i == selected
	end, function(_, is_selected)
		return is_selected and icons.selected or icons.unselected
	end, {
		add_raw_line = add_panel_raw_line,
		highlight_text = highlight_panel_text,
		selected_hl = "OpenCodePermissionSelected",
		option_hl = "OpenCodePermissionOutput",
		marker_hl = "OpenCodePermissionSelectedMarker",
	})

	add_panel_blank(result)
	if #save > 0 and selected == 2 then
		if #save == 1 and save[1] == "*" then
			add_panel_line(
				result,
				"This will always allow " .. perm_state.permission_type .. " for this project.",
				"OpenCodePermissionMuted"
			)
		else
			add_panel_line(result, "This will always allow the following patterns for this project.", "OpenCodePermissionMuted")
			for _, pattern in ipairs(save) do
				add_panel_line(result, "- " .. pattern, "OpenCodePermissionOutput")
			end
		end
		add_panel_blank(result)
	end
	append_hint(result, #options)
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines,
		result.highlights,
		widget_base.make_meta({
			interactive_count = #options,
			first_interactive_line = first_option_line,
			option_lines = option_lines,
			option_end_lines = option_end_lines,
		})
end

---@param status string|nil
---@return boolean
local function is_resolved(status)
	return status == "approved" or status == "rejected"
end

---The decision as one line on the tool row's panel, then whatever the row does not show.
---@param result table
---@param perm_state table
---@param status "approved"|"rejected"
---@param tool_row table
---@param description OpenCodePermissionDescription
local function append_status(result, perm_state, status, tool_row, description)
	local always = perm_state.always or {}
	local decision = "allowed once"
	if status == "rejected" then
		decision = "rejected"
	elseif perm_state.reply == "always" and #always > 0 then
		decision = "always allowed"
		if not (#always == 1 and always[1] == "*") then
			decision = decision .. ": " .. table.concat(always, ", ")
		end
	end

	local permission_type = perm_state.permission_type
	local own = permission_type == tool_row.tool or (description.shell and tool_row.tool == "bash")
	local text
	if own then
		text = decision:sub(1, 1):upper() .. decision:sub(2)
	else
		text = description.title .. " " .. decision
	end
	local icon = status == "rejected" and icons.rejected or icons.approved
	add_panel_line(result, icon .. " " .. text,
		status == "rejected" and "OpenCodePermissionRejected" or "OpenCodePermissionApproved")
	append_details(result, {}, unshown_resources(description, first_non_empty(tool_row.command)), description.message)
	add_panel_blank(result)
end

---@return table lines, table highlights, boolean attached
local function render_resolved(perm_state, status, reply_suffix, opts)
	local result = widget_base.new_result(opts)
	local tool_input = resolve_tool_input(perm_state)
	local description = get_permission_description(perm_state.permission_type, tool_input, perm_state)
	local tool_row = opts and opts.tool_row
	if type(tool_row) == "table" then
		append_status(result, perm_state, status, tool_row, description)
		return result.lines, result.highlights, true
	end

	add_panel_blank(result)
	add_header(result, permission_header_title(perm_state), status, reply_suffix)
	add_panel_blank(result)
	append_description(result, description)
	add_panel_blank(result)
	add_trailing_separator(result)

	return result.lines, result.highlights, false
end

-- Compatibility entrypoints retain their existing signatures and reply suffixes.
---@param _permission_id string Unused; kept for the public signature
---@param perm_state table
---@param opts? table { width?: number, render?: table, tool_row?: table }
---@return table lines, table highlights, boolean attached One status line for the tool row above
function M.get_approved_lines(_permission_id, perm_state, opts)
	local saved = perm_state.reply == "always" and #(perm_state.always or {}) > 0
	return render_resolved(perm_state, "approved", saved and "(always)" or "(once)", opts)
end

---@param _permission_id string Unused; kept for the public signature
---@param perm_state table
---@param opts? table { width?: number, render?: table, tool_row?: table }
---@return table lines, table highlights, boolean attached One status line for the tool row above
function M.get_rejected_lines(_permission_id, perm_state, opts)
	return render_resolved(perm_state, "rejected", nil, opts)
end

---Whether a permission renders as a status line on the tool row directly above it.
---@param perm_state table
---@param tool_row table|nil
---@return boolean
function M.attaches(perm_state, tool_row)
	return type(tool_row) == "table" and is_resolved(perm_state.status)
end

---Render a permission for its current status; always returns meta.
---`opts.tool_row` describes the tool row rendered for the same call:
---{ tool: string, command?: string, folded?: boolean }. With it, a resolved
---permission is one status line and a pending shell request leaves the
---command to the row.
---@param perm_state table Permission state from permission/state.lua
---@param opts? table { width?: number, render?: table, tool_row?: table }
---@return table lines, table highlights, OpenCodeWidgetMeta meta
function M.render(perm_state, opts)
	local id = perm_state.permission_id
	local status = perm_state.status or "pending"
	if is_resolved(status) then
		local lines, highlights, attached = (status == "approved" and M.get_approved_lines or M.get_rejected_lines)(id, perm_state, opts)
		return lines, highlights, widget_base.make_meta(attached and { attached = true } or nil)
	end
	return M.get_lines_for_permission(id, perm_state, opts)
end

return M
