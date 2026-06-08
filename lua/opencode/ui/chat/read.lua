-- Dedicated read tool rendering for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local syntax = require("opencode.ui.syntax")
local text_util = require("opencode.util.text")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local PANEL_PREFIX = tool_panel.PANEL_PREFIX
local PANEL_BORDER_HL = "OpenCodeReadMuted"

local panel_helpers = tool_panel.create_panel({
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeReadOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator

local function ensure_highlights()
	panel_helpers.set_hl("OpenCodeReadMuted", "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeReadPath", "String", "Normal")
	panel_helpers.set_hl("OpenCodeReadFilename", "String", "Normal", { bold = true })
	panel_helpers.set_hl("OpenCodeReadOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeReadError", "DiagnosticError", "ErrorMsg")
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

local function get_read_path(input)
	if type(input) ~= "table" then
		return nil
	end
	return input.filePath
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

	local ctx = tool_panel.context(tool_part)
	local input = ctx.input
	local metadata = ctx.metadata
	local status = ctx.status
	local working = ctx.working
	local filepath = first_nonempty_trimmed_text(get_read_path(input), metadata.path)
	local output = first_nonempty_text(ctx.output)
	local error_body = trim_edge_newlines(first_nonempty_text(ctx.error))
	local body = extract_read_body(output)

	local body_entries = {}
	tool_panel.append_entries(body_entries, body, "OpenCodeReadOutput")
	tool_panel.append_error_entries(body_entries, error_body, "OpenCodeReadError", "OpenCodeReadOutput")

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
	header = tool_panel.header(header, {
		fold = has_overflow or is_expanded,
		expanded = is_expanded,
		working = working,
	})

	local header_hl = "OpenCodeReadMuted"
	if status == "error" or error_body ~= "" then
		header_hl = "OpenCodeReadError"
	elseif working then
		header_hl = "OpenCodeReadPath"
	end

	local result = panel_helpers.result()
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
	local _, render_overflow = panel_helpers.render_entries(result, body_entries, {
		expanded = is_expanded,
		max = MAX_COLLAPSED_OUTPUT_LINES,
		overflow_hl = "OpenCodeReadMuted",
		render_entry = function(_, entry)
			if read_lang and entry.hl_group == "OpenCodeReadOutput" then
				local source_text, rows = add_code_entry(result, entry.text, entry.hl_group)
				table.insert(code_lines, source_text)
				table.insert(code_rows, rows)
			else
				panel_helpers.add_entry(result, entry)
			end
		end,
	})
	if read_lang and #code_lines > 0 then
		add_wrapped_syntax_highlights(result, table.concat(code_lines, "\n"), read_lang, code_rows)
	end

	if not render_overflow then
		if #body_entries > 0 and #loaded_entries > 0 then
			add_panel_blank(result)
		end
		for _, entry in ipairs(loaded_entries) do
			panel_helpers.add_entry(result, entry)
		end
	end

	add_panel_blank(result)
	add_trailing_separator(result)
	return result
end

return M
