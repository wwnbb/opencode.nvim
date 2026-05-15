-- Skill tool widget renderer for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local SKILL_ANIM_FRAMES = { "|", "/", "-", "\\" }

local function get_hl(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and value or {}
end

local function set_panel_hl(name, fg_source, fallback)
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
	if next(opts) == nil then
		opts.link = fallback or fg_source
	end
	vim.api.nvim_set_hl(0, name, opts)
end

local function ensure_highlights()
	set_panel_hl("OpenCodeSkillMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeSkillName", "String", "Normal")
	set_panel_hl("OpenCodeSkillOutput", "Normal", nil)
	set_panel_hl("OpenCodeSkillError", "DiagnosticError", "ErrorMsg")
end

---@return number width
local function get_chat_text_width()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return 80
	end

	local width = vim.api.nvim_win_get_width(state.winid)
	local wininfo = vim.fn.getwininfo(state.winid)[1]
	local textoff = wininfo and tonumber(wininfo.textoff) or 0
	return math.max(1, width - textoff)
end

---@param text string
---@return string
local function pad_to_width(text)
	local width = get_chat_text_width()
	local current = vim.fn.strdisplaywidth(text)
	if current >= width then
		return text
	end
	return text .. string.rep(" ", width - current)
end

---@param result table
---@param text string
---@param hl_group string|nil
local function add_line(result, text, hl_group)
	text = render.sanitize_buffer_line(text)
	local line = pad_to_width(text)
	table.insert(result.lines, line)
	if hl_group then
		table.insert(result.highlights, {
			line = #result.lines - 1,
			col_start = 0,
			col_end = #line,
			hl_group = hl_group,
		})
	end
end

---@param result table
---@param text string
---@param hl_group string
local function add_panel_line(result, text, hl_group)
	add_line(result, "▏  " .. text, hl_group)
end

---@param result table
local function add_panel_blank(result)
	add_line(result, "▏", "OpenCodeSkillOutput")
end

---@param result table
local function add_trailing_separator(result)
	table.insert(result.lines, "")
end

---@param value any
---@return boolean
local function is_nil(value)
	return value == nil or value == vim.NIL
end

local function is_present(value)
	return value ~= nil and value ~= vim.NIL and tostring(value) ~= ""
end

---@param value any
---@return string
local function stringify(value)
	if is_nil(value) then
		return ""
	end
	if type(value) == "string" then
		return value
	end
	if type(value) == "table" then
		if type(value.output) == "string" then
			return value.output
		end
		if type(value.content) == "string" then
			return value.content
		end
		return vim.inspect(value)
	end
	return tostring(value)
end

---@param text string
---@return string
local function strip_ansi(text)
	local esc = string.char(27)
	local bel = string.char(7)
	text = text:gsub(esc .. "%][^" .. bel .. "]*" .. bel, "")
	text = text:gsub(esc .. "%[[0-?]*[ -/]*[@-~]", "")
	return text
end

---@param value any
---@return string
local function normalize_text(value)
	return strip_ansi(stringify(value)):gsub("\r\n", "\n"):gsub("\r", "\n")
end

---@param ... any
---@return string
local function first_nonempty_text(...)
	for i = 1, select("#", ...) do
		local text = normalize_text(select(i, ...))
		if text ~= "" then
			return text
		end
	end
	return ""
end

---@param ... any
---@return string
local function first_nonempty_trimmed_text(...)
	for i = 1, select("#", ...) do
		local text = vim.trim(normalize_text(select(i, ...)))
		if text ~= "" then
			return text
		end
	end
	return ""
end

---@param text string
---@return string
local function trim_edge_newlines(text)
	return (text or ""):gsub("^\n+", ""):gsub("\n+$", "")
end

---@param path string
---@return string
local function normalize_path(path)
	if not is_present(path) then
		return "unknown"
	end

	local normalized = tostring(path)
	if normalized:match("^file://") then
		local ok, filepath = pcall(vim.uri_to_fname, normalized)
		if ok and filepath and filepath ~= "" then
			normalized = filepath
		end
	end
	return vim.fn.fnamemodify(normalized, ":~:.")
end

---@param tool_part table
---@return table|string
local function get_input(tool_part)
	local state_input = tool_part and tool_part.state and tool_part.state.input
	if type(state_input) == "table" then
		return state_input
	end
	local part_input = tool_part and tool_part.input
	if type(part_input) == "table" then
		return part_input
	end
	return state_input or part_input or {}
end

---@return string
local function get_anim_frame()
	return SKILL_ANIM_FRAMES[state.task_anim_frame] or SKILL_ANIM_FRAMES[1]
end

---@param output string
---@return table parsed
local function parse_skill_output(output)
	local parsed = {
		name = nil,
		dir = nil,
		body = "",
		files = {},
	}
	if output == "" then
		return parsed
	end

	parsed.name = output:match('<skill_content%s+name="([^"]+)"')
	parsed.dir = output:match("Base directory for this skill:%s*([^\n]+)")

	for filepath in output:gmatch("<file>(.-)</file>") do
		if filepath ~= "" then
			table.insert(parsed.files, filepath)
		end
	end

	local body = output:match("<skill_content[^>]*>\n?(.-)\n?</skill_content>")
	if not body then
		body = output
	end

	body = body:gsub("\n?<skill_files>%s*.-%s*</skill_files>\n?", "\n")
	local base_pos = body:find("\nBase directory for this skill:", 1, true)
	if base_pos then
		body = body:sub(1, base_pos - 1)
	end
	body = body:gsub("^# Skill:[^\n]*\n?", "")
	parsed.body = trim_edge_newlines(body)

	return parsed
end

---@param entries table[]
---@param text string
---@param hl_group string|nil
local function append_body_entries(entries, text, hl_group)
	if text == "" then
		return
	end
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		table.insert(entries, { text = line, hl_group = hl_group })
	end
end

---@param result table
---@param entry table
local function add_entry(result, entry)
	if entry.text == "" then
		add_panel_blank(result)
		return
	end
	add_panel_line(result, entry.text, entry.hl_group)
end

---@param input table|string
---@return string|nil
local function get_input_name(input)
	if type(input) == "table" then
		return input.name
	end
	if type(input) == "string" then
		return input
	end
	return nil
end

---@param tool_part table
---@param expanded boolean
---@return table|nil result
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "skill" then
		return nil
	end
	ensure_highlights()

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = get_input(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	local status = tool_state.status or "pending"
	local working = status == "pending" or status == "running"
	local output = first_nonempty_text(tool_state.output, metadata.output, tool_part.output)
	local error_body = trim_edge_newlines(first_nonempty_text(tool_state.error, metadata.error, tool_part.error))
	local parsed = parse_skill_output(output)

	local title_name = type(tool_state.title) == "string" and tool_state.title:match("Loaded skill:%s*(.+)") or nil
	local name = first_nonempty_trimmed_text(get_input_name(input), metadata.name, parsed.name, title_name)
	if name == "" then
		name = "unknown"
	end

	local dir = first_nonempty_trimmed_text(metadata.dir, metadata.directory, metadata.path, parsed.dir)
	local body = parsed.body
	if body == "" then
		body = first_nonempty_text(metadata.preview)
	end

	local body_entries = {}
	append_body_entries(body_entries, body, "OpenCodeSkillOutput")
	if #body_entries > 0 and error_body ~= "" then
		table.insert(body_entries, { text = "", hl_group = "OpenCodeSkillOutput" })
	end
	append_body_entries(body_entries, error_body, "OpenCodeSkillError")

	local has_overflow = #body_entries > MAX_COLLAPSED_OUTPUT_LINES
	local header = '# Skill "' .. name .. '"'
	if working then
		header = header .. " " .. get_anim_frame()
	end
	if has_overflow or expanded then
		local fold_icon = expanded and "▾" or "▸"
		header = fold_icon .. " " .. header
	end

	local header_hl = "OpenCodeSkillMuted"
	if status == "error" or error_body ~= "" then
		header_hl = "OpenCodeSkillError"
	elseif working then
		header_hl = "OpenCodeSkillName"
	end

	local result = { lines = {}, highlights = {} }
	add_panel_line(result, header, header_hl)

	local has_details = dir ~= "" or #parsed.files > 0
	if not has_details and #body_entries == 0 then
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)

	if dir ~= "" then
		add_panel_line(result, "Base: " .. normalize_path(dir), "OpenCodeSkillMuted")
	end

	if #parsed.files > 0 then
		add_panel_line(result, "Files: " .. tostring(#parsed.files) .. " sampled", "OpenCodeSkillMuted")
		if expanded then
			for _, filepath in ipairs(parsed.files) do
				add_panel_line(result, "  " .. normalize_path(filepath), "OpenCodeSkillMuted")
			end
		end
	end

	if has_details and #body_entries > 0 then
		add_panel_blank(result)
	end

	local limit = expanded and #body_entries or math.min(MAX_COLLAPSED_OUTPUT_LINES, #body_entries)
	for i = 1, limit do
		add_entry(result, body_entries[i])
	end

	if not expanded and has_overflow then
		local remaining = #body_entries - MAX_COLLAPSED_OUTPUT_LINES
		add_panel_line(result, "… (" .. tostring(remaining) .. " more lines, press O to expand)", "OpenCodeSkillMuted")
	end

	add_trailing_separator(result)
	return result
end

return M
