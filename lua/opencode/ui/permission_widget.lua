-- opencode.nvim - Permission widget module
-- Renders interactive permission prompts inline in chat buffer

local M = {}

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

-- Get description lines for a permission based on type
---@param permission_type string
---@param tool_input table
---@return table lines Array of description lines
local function get_permission_description(permission_type, tool_input)
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
		local path = normalize_path(tool_input.file_path or tool_input.filePath or tool_input.path or "")
		return { "→ Read " .. path }
	elseif permission_type == "glob" then
		local pattern = tool_input.pattern or ""
		return { string.format('✱ Glob "%s"', pattern) }
	elseif permission_type == "grep" then
		local pattern = tool_input.pattern or ""
		return { string.format('✱ Grep "%s"', pattern) }
	elseif permission_type == "list" then
		local path = normalize_path(tool_input.path or "")
		return { "→ List " .. path }
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
		local dir = tool_input.directory or tool_input.path or ""
		return { "← Access external directory " .. dir }
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
---@return table lines, table highlights, number option_count, number first_option_line
function M.get_lines_for_permission(permission_id, perm_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	-- Header
	local id_short = permission_id:sub(1, 12)
	local time_str = os.date("%H:%M", perm_state.timestamp or os.time())
	local header = string.format(
		"%s Permission required [%s] %s%s",
		icons.pending,
		id_short,
		string.rep(" ", math.max(0, 50 - 22 - #id_short - #time_str)),
		time_str
	)
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

	-- Permission description
	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input)
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
			table.insert(highlights, {
				line = line_num,
				col_start = 0,
				col_end = #option_text,
				hl_group = "CursorLine",
			})
		end

		line_num = line_num + 1
	end

	-- Keymap hint
	table.insert(lines, "")
	line_num = line_num + 1

	local hint = "[1-3 select, ↑↓ navigate, Enter confirm, Esc reject]"
	table.insert(lines, hint)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #hint,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	-- Trailing blank line
	table.insert(lines, "")

	return lines, highlights, 3, first_option_line
end

-- Get formatted lines for an approved permission
---@param permission_id string
---@param perm_state table
---@return table lines, table highlights
function M.get_approved_lines(permission_id, perm_state)
	local lines = {}
	local highlights = {}
	local line_num = 0

	local id_short = permission_id:sub(1, 12)
	local time_str = os.date("%H:%M", perm_state.resolved_at or os.time())
	local reply_label = perm_state.reply == "always" and "Allowed (always)" or "Allowed (once)"
	local header = string.format(
		"%s Permission [%s] %s%s",
		icons.approved,
		id_short,
		string.rep(" ", math.max(0, 50 - 14 - #id_short - #time_str)),
		time_str
	)
	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #icons.approved + 1,
		hl_group = "Comment",
	})
	line_num = line_num + 1

	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input)
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

	local id_short = permission_id:sub(1, 12)
	local time_str = os.date("%H:%M", perm_state.resolved_at or os.time())
	local header = string.format(
		"%s Permission [%s] %s%s",
		icons.rejected,
		id_short,
		string.rep(" ", math.max(0, 50 - 14 - #id_short - #time_str)),
		time_str
	)
	table.insert(lines, header)
	table.insert(highlights, {
		line = line_num,
		col_start = 0,
		col_end = #icons.rejected + 1,
		hl_group = "Error",
	})
	line_num = line_num + 1

	table.insert(lines, string.rep("─", 60))
	line_num = line_num + 1

	local desc_lines = get_permission_description(perm_state.permission_type, perm_state.tool_input)
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
