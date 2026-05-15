-- Glob/grep tool widget renderer for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local SEARCH_ANIM_FRAMES = { "|", "/", "-", "\\" }

local TOOL_CONFIG = {
	glob = {
		title = "Glob",
		pending = "Finding files...",
		count_key = "count",
	},
	grep = {
		title = "Grep",
		pending = "Searching content...",
		count_key = "matches",
	},
}

local function get_hl(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and value or {}
end

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
	set_panel_hl("OpenCodeSearchMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeSearchPattern", "String", "Normal", { bold = true })
	set_panel_hl("OpenCodeSearchPath", "Directory", "Normal")
	set_panel_hl("OpenCodeSearchOutput", "Normal", nil)
	set_panel_hl("OpenCodeSearchError", "DiagnosticError", "ErrorMsg")
end

---@param result table
---@param text string
---@param hl_group string
---@return number line_index
---@return string line
---@return table[] rows
local function add_panel_line(result, text, hl_group)
	return render.add_panel_line(result, text, hl_group)
end

---@param result table
local function add_panel_blank(result)
	render.add_panel_blank(result, "OpenCodeSearchOutput")
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

---@param value any
---@return boolean
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
		return ""
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
	local part_input = tool_part and tool_part.input
	if type(state_input) == "table" or type(part_input) == "table" then
		return vim.tbl_deep_extend(
			"force",
			{},
			type(part_input) == "table" and part_input or {},
			type(state_input) == "table" and state_input or {}
		)
	end
	return state_input or part_input or {}
end

---@param input table|string
---@param key string
---@return any
local function input_value(input, key)
	if type(input) == "table" then
		return input[key]
	end
	if key == "pattern" and type(input) == "string" then
		return input
	end
	return nil
end

---@param value any
---@return number|nil
local function normalize_number(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" and value ~= "" then
		return tonumber(value)
	end
	return nil
end

---@param count number
---@return string
local function format_match_count(count)
	return tostring(count) .. " " .. (count == 1 and "match" or "matches")
end

---@return string
local function get_anim_frame()
	return SEARCH_ANIM_FRAMES[state.task_anim_frame] or SEARCH_ANIM_FRAMES[1]
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

---@param result table
---@param rows table[]|nil
---@param text string
---@param hl_group string
local function highlight_text(result, rows, text, hl_group)
	render.highlight_panel_text(result, rows, text, hl_group)
end

---@param tool_part table
---@param expanded boolean
---@return table|nil result
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or (tool_part.tool ~= "glob" and tool_part.tool ~= "grep") then
		return nil
	end
	ensure_highlights()

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = get_input(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	local status = tool_state.status or "pending"
	local working = status == "pending" or status == "running"
	local config = TOOL_CONFIG[tool_part.tool]
	local pattern = first_nonempty_trimmed_text(input_value(input, "pattern"), metadata.pattern)
	local path = first_nonempty_trimmed_text(input_value(input, "path"), metadata.path)
	local include = first_nonempty_trimmed_text(input_value(input, "include"), metadata.include)
	local display_path = normalize_path(path)
	local output = first_nonempty_text(tool_state.output, metadata.output, tool_part.output, metadata.preview)
	local error_body = trim_edge_newlines(first_nonempty_text(tool_state.error, metadata.error, tool_part.error))
	local count = normalize_number(metadata[config.count_key])
	if count == nil then
		count = normalize_number(tool_state[config.count_key])
	end

	local body = trim_edge_newlines(output)
	if body == "" and status == "completed" then
		body = "No files found"
	end

	local entries = {}
	append_body_entries(entries, body, "OpenCodeSearchOutput")
	if #entries > 0 and error_body ~= "" then
		table.insert(entries, { text = "", hl_group = "OpenCodeSearchOutput" })
	end
	append_body_entries(entries, error_body, "OpenCodeSearchError")

	local has_overflow = #entries > MAX_COLLAPSED_OUTPUT_LINES
	local display_pattern = pattern ~= "" and pattern or "..."
	local header = '# ' .. config.title .. ' "' .. display_pattern .. '"'
	if display_path ~= "" then
		header = header .. " in " .. display_path
	end
	if tool_part.tool == "grep" and include ~= "" then
		header = header .. " include=" .. include
	end
	if count ~= nil then
		header = header .. " (" .. format_match_count(count) .. ")"
	end
	if working then
		header = header .. " " .. get_anim_frame()
	end
	if has_overflow or expanded then
		local fold_icon = expanded and "▾" or "▸"
		header = fold_icon .. " " .. header
	end

	local header_hl = "OpenCodeSearchMuted"
	if status == "error" or error_body ~= "" then
		header_hl = "OpenCodeSearchError"
	elseif working then
		header_hl = "OpenCodeSearchPattern"
	end

	local result = { lines = {}, highlights = {} }
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	highlight_text(result, header_rows, '"' .. display_pattern .. '"', "OpenCodeSearchPattern")
	highlight_text(result, header_rows, display_path, "OpenCodeSearchPath")

	if #entries == 0 then
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)

	local limit = expanded and #entries or math.min(MAX_COLLAPSED_OUTPUT_LINES, #entries)
	for i = 1, limit do
		add_entry(result, entries[i])
	end

	if not expanded and has_overflow then
		local remaining = #entries - MAX_COLLAPSED_OUTPUT_LINES
		add_panel_line(result, "… (" .. tostring(remaining) .. " more lines, press O to expand)", "OpenCodeSearchMuted")
	end

	add_trailing_separator(result)
	return result
end

return M
