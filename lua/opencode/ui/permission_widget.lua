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

---@param permission_type string
---@param tool_input table
---@param perm_state? table
---@return string
local function get_permission_path(permission_type, tool_input, perm_state)
	local metadata = (perm_state and perm_state.metadata) or {}
	local patterns = (perm_state and perm_state.patterns) or {}

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
			metadata.directory
		))
	end

	if permission_type == "external_directory" then
		return normalize_path(first_non_empty(
			tool_input.directory,
			tool_input.path,
			metadata.directory,
			metadata.path
		))
	end

	return ""
end

---@param lines table
---@param path string
---@return table
local function with_path_line(lines, path)
	if path == "" then
		return lines
	end

	table.insert(lines, "  Path: " .. path)
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
		local desc = tool_input.description or "Run bash command"
		local cmd = tool_input.command or ""
		local lines = { "# " .. desc }
		if cmd ~= "" then
			table.insert(lines, "  $ " .. cmd)
		end
		return lines
	elseif permission_type == "read" then
		local path = get_permission_path(permission_type, tool_input, perm_state)
		if path == "" then
			return { "→ Read" }
		end
		return with_path_line({ "→ Read" }, path)
	elseif permission_type == "glob" then
		local pattern = tool_input.pattern or ""
		return with_path_line(
			{ string.format('✱ Glob "%s"', pattern) },
			get_permission_path(permission_type, tool_input, perm_state)
		)
	elseif permission_type == "grep" then
		local pattern = tool_input.pattern or ""
		return with_path_line(
			{ string.format('✱ Grep "%s"', pattern) },
			get_permission_path(permission_type, tool_input, perm_state)
		)
	elseif permission_type == "list" then
		local path = get_permission_path(permission_type, tool_input, perm_state)
		if path == "" then
			return { "→ List" }
		end
		return with_path_line({ "→ List" }, path)
	elseif permission_type == "webfetch" then
		local url = tool_input.url or ""
		return { "%% WebFetch " .. url }
	elseif permission_type == "websearch" then
		local query = tool_input.query or ""
		return { string.format('◈ Web Search "%s"', query) }
	elseif permission_type == "codesearch" then
		local query = tool_input.query or ""
		return { string.format('◇ Code Search "%s"', query) }
	elseif permission_type == "external_directory" then
		local path = get_permission_path(permission_type, tool_input, perm_state)
		if path == "" then
			return { "← Access external directory" }
		end
		return with_path_line({ "← Access external directory" }, path)
	elseif permission_type == "diff_review" then
		return { "Review file changes" }
	elseif permission_type == "doom_loop" then
		return { "⟳ Continue after repeated failures" }
	elseif permission_type == "task" then
		local subagent = tool_input.subagent_type or "Task"
		local desc = tool_input.description or ""
		local lines = { "# " .. subagent:sub(1, 1):upper() .. subagent:sub(2) .. " Task" }
		if desc ~= "" then
			table.insert(lines, "◉ " .. desc)
		end
		return lines
	else
		return { "Call tool " .. permission_type }
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

	local hint = "[1-3 select, ↑↓ navigate, Enter confirm, Esc reject]"
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
	local summary = desc_lines[1] or perm_state.permission_type
	local display = summary .. " - " .. reply_label
	table.insert(lines, display)
	table.insert(highlights, {
		line = line_num,
		col_start = #summary + 1,
		col_end = #display,
		hl_group = "Comment",
	})
	line_num = line_num + 1

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
	local summary = desc_lines[1] or perm_state.permission_type
	local display = summary .. " - Rejected"
	table.insert(lines, display)
	table.insert(highlights, {
		line = line_num,
		col_start = #summary + 1,
		col_end = #display,
		hl_group = "Error",
	})
	line_num = line_num + 1

	table.insert(lines, "")

	return lines, highlights
end

return M
