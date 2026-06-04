-- Dedicated read tool rendering for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")
local panel = require("opencode.ui.panel")
local syntax = require("opencode.ui.syntax")
local text_util = require("opencode.util.text")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local PANEL_PREFIX = "▏  "
local PANEL_BLANK_PREFIX = "▏"
local PANEL_BORDER_HL = "OpenCodeReadMuted"
local READ_ANIM_FRAMES = { "|", "/", "-", "\\" }

local panel_helpers = panel.create_helpers({
	prefix = PANEL_PREFIX,
	blank_prefix = PANEL_BLANK_PREFIX,
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeReadOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator

local function set_panel_hl(name, fg_source, fallback, extra_opts)
	panel_helpers.set_hl(name, fg_source, fallback, extra_opts)
end

local function ensure_highlights()
	set_panel_hl("OpenCodeReadMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeReadPath", "String", "Normal")
	set_panel_hl("OpenCodeReadFilename", "String", "Normal", { bold = true })
	set_panel_hl("OpenCodeReadOutput", "Normal", nil)
	set_panel_hl("OpenCodeReadError", "DiagnosticError", "ErrorMsg")
end

---@param value any
---@return boolean
local function is_nil(value)
	return text_util.is_nil(value)
end

local function is_present(value)
	return text_util.is_present(value)
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
	return text_util.strip_ansi(text)
end

---@param value any
---@return string
local function normalize_text(value)
	return text_util.normalize_text(value, stringify)
end

---@param ... any
---@return string
local function first_nonempty_text(...)
	return text_util.first_nonempty_text(stringify, ...)
end

---@param ... any
---@return string
local function first_nonempty_trimmed_text(...)
	return text_util.first_nonempty_trimmed_text(stringify, ...)
end

---@param text string
---@return string
local function trim_edge_newlines(text)
	return text_util.trim_edge_newlines(text)
end

---@param path string
---@return string
local function normalize_path(path)
	if not is_present(path) then
		return "unknown"
	end
	return vim.fn.fnamemodify(tostring(path), ":~:.")
end

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

local function get_read_path(input)
	if type(input) == "string" then
		return input
	end
	if type(input) ~= "table" then
		return nil
	end
	return input.filePath or input.file_path or input.filepath
end

---@return string
local function get_anim_frame()
	return READ_ANIM_FRAMES[state.task_anim_frame] or READ_ANIM_FRAMES[1]
end

---@param text string
---@param tag string
---@return string|nil
local function extract_tag(text, tag)
	local open_tag = "<" .. tag .. ">"
	local close_tag = "</" .. tag .. ">"
	local start_pos = text:find(open_tag, 1, true)
	if not start_pos then
		return nil
	end
	local end_pos = text:find(close_tag, start_pos + #open_tag, true)
	if not end_pos then
		return nil
	end
	return trim_edge_newlines(text:sub(start_pos + #open_tag, end_pos - 1))
end

---@param output string
---@return string
local function extract_read_body(output)
	local content = extract_tag(output, "content")
	if is_present(content) then
		return content
	end

	local entries = extract_tag(output, "entries")
	if is_present(entries) then
		return entries
	end

	return trim_edge_newlines(output)
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

---@param metadata table
---@return table[]
local function get_loaded_entries(metadata)
	local entries = {}
	local loaded = metadata and metadata.loaded
	if type(loaded) ~= "table" then
		return entries
	end
	for _, filepath in ipairs(loaded) do
		if type(filepath) == "string" and filepath ~= "" then
			table.insert(entries, {
				text = "↳ Loaded " .. normalize_path(filepath),
				hl_group = "OpenCodeReadMuted",
			})
		end
	end
	return entries
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

---@param text string
---@return string|nil gutter
---@return string body
local function split_line_number_gutter(text)
	local gutter, body = tostring(text or ""):match("^(%d+:%s?)(.*)$")
	if gutter then
		return gutter, body
	end
	return nil, text
end

---@param gutter string
---@return string
local function continuation_gutter(gutter)
	return string.rep(" ", vim.fn.strdisplaywidth(gutter))
end

---@param result table
---@param text string
---@param hl_group string
---@return string source_text
---@return table[] rows
local function add_code_entry(result, text, hl_group)
	local gutter, body = split_line_number_gutter(text)
	if not gutter then
		local _, _, rows = add_panel_raw_line(result, text, hl_group)
		return text, rows
	end

	local _, _, rows = add_panel_raw_line(result, body, hl_group, {
		body_prefix = gutter,
		continuation_prefix = continuation_gutter(gutter),
	})
	return body, rows
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

	local prefix_len = #(row.prefix or "")
	local highlight = {
		line = row.line_index,
		col_start = prefix_len + overlap_start - row_start,
		col_end = prefix_len + overlap_end - row_start,
		hl_group = hl_group,
	}
	if priority then
		highlight.priority = priority
	end
	table.insert(result.highlights, highlight)
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
---@param text string
---@param lang string
---@param row_map table[]
local function add_wrapped_syntax_highlights(result, text, lang, row_map)
	local source_lines = vim.split(text, "\n", { plain = true })
	for _, hl in ipairs(syntax.highlight_text(text, lang, { scope = "tools" })) do
		local first_line = hl.line or 0
		local last_line = hl.end_line or first_line
		local max_line = math.max(0, #source_lines - 1)
		if first_line <= max_line then
			last_line = math.min(last_line, max_line)
			for source_line = first_line, last_line do
				local line_text = source_lines[source_line + 1] or ""
				local source_start = source_line == first_line and (hl.col_start or 0) or 0
				local source_end
				if source_line == last_line then
					source_end = hl.end_col or hl.col_end or hl.col_start or #line_text
				else
					source_end = #line_text
				end
				if source_end == -1 then
					source_end = #line_text
				end
				add_wrapped_line_highlight(result, row_map[source_line + 1], source_start, source_end, hl.hl_group, hl.priority)
			end
		end
	end
end

---@param tool_part table
---@param is_expanded boolean
---@return table|nil result
function M.render_tool(tool_part, is_expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "read" then
		return nil
	end
	ensure_highlights()

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = get_input(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	local status = tool_state.status or "pending"
	local working = status == "pending" or status == "running"
	local filepath = first_nonempty_trimmed_text(
		get_read_path(input),
		metadata.filePath,
		metadata.file_path,
		metadata.filepath,
		metadata.path
	)
	local output = first_nonempty_text(tool_state.output, metadata.output, tool_part.output, metadata.preview)
	local error_body = first_nonempty_text(tool_state.error, metadata.error, tool_part.error)
	local body = extract_read_body(output)
	if body == "" then
		body = first_nonempty_text(metadata.preview)
	end

	local body_entries = {}
	append_body_entries(body_entries, body, "OpenCodeReadOutput")
	if #body_entries > 0 and error_body ~= "" then
		table.insert(body_entries, { text = "", hl_group = "OpenCodeReadOutput" })
	end
	append_body_entries(body_entries, trim_edge_newlines(error_body), "OpenCodeReadError")

	local loaded_entries = {}
	if status == "completed" then
		loaded_entries = get_loaded_entries(metadata)
	end

	local has_overflow = #body_entries > MAX_COLLAPSED_OUTPUT_LINES
	local display_path = normalize_path(filepath)
	local header = "# Read " .. display_path

	if type(input) == "table" then
		if is_present(input.offset) then
			header = header .. " offset=" .. tostring(input.offset)
		end
		if is_present(input.limit) then
			header = header .. " limit=" .. tostring(input.limit)
		end
	end
	if working then
		header = header .. " " .. get_anim_frame()
	end
	if has_overflow or is_expanded then
		local fold_icon = is_expanded and "▾" or "▸"
		header = fold_icon .. " " .. header
	end

	local header_hl = "OpenCodeReadMuted"
	if status == "error" or error_body ~= "" then
		header_hl = "OpenCodeReadError"
	elseif working then
		header_hl = "OpenCodeReadPath"
	end

	local result = { lines = {}, highlights = {} }
	add_panel_blank(result)
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	panel_helpers.highlight_text(result, header_rows, display_path, "OpenCodeReadFilename")

	if #body_entries == 0 and #loaded_entries == 0 then
		add_panel_blank(result)
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)

	local read_lang = syntax.language_for_path(filepath)
	local code_lines = {}
	local code_rows = {}
	local limit = is_expanded and #body_entries or math.min(MAX_COLLAPSED_OUTPUT_LINES, #body_entries)
	for i = 1, limit do
		local entry = body_entries[i]
		if read_lang and entry.hl_group == "OpenCodeReadOutput" then
			local source_text, rows = add_code_entry(result, entry.text, entry.hl_group)
			table.insert(code_lines, source_text)
			table.insert(code_rows, rows)
		else
			add_entry(result, entry)
		end
	end
	if read_lang and #code_lines > 0 then
		add_wrapped_syntax_highlights(result, table.concat(code_lines, "\n"), read_lang, code_rows)
	end

	if not is_expanded and has_overflow then
		local remaining = #body_entries - MAX_COLLAPSED_OUTPUT_LINES
		add_panel_line(result, "… (" .. tostring(remaining) .. " more lines, press O to expand)", "OpenCodeReadMuted")
	else
		if #body_entries > 0 and #loaded_entries > 0 then
			add_panel_blank(result)
		end
		for _, entry in ipairs(loaded_entries) do
			add_entry(result, entry)
		end
	end

	add_panel_blank(result)
	add_trailing_separator(result)
	return result
end

return M
