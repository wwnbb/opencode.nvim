-- Dedicated read tool rendering for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local syntax = require("opencode.ui.syntax")
local text_util = require("opencode.util.text")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local PANEL_BORDER_HL = "OpenCodeReadMuted"

local panel_helpers = tool_panel.create_panel({
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeReadOutput",
})

local function ensure_highlights()
	panel_helpers.set_hl("OpenCodeReadMuted", "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeReadPath", "String", "Normal")
	panel_helpers.set_hl("OpenCodeReadFilename", "String", "Normal", { bold = true })
	panel_helpers.set_hl("OpenCodeReadOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeReadError", "DiagnosticError", "ErrorMsg")
end

require("opencode.ui.highlights").register("opencode.ui.chat.read", ensure_highlights)

---@param value any
---@return string
local function stringify(value)
	if text_util.is_nil(value) then
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

local trim_edge_newlines = text_util.trim_edge_newlines

---@param path string
---@return string
local function normalize_path(path)
	if not text_util.is_present(path) then
		return "unknown"
	end
	return vim.fn.fnamemodify(tostring(path), ":~:.")
end

local function get_read_path(input)
	if type(input) ~= "table" then
		return nil
	end
	return input.path or input.filePath
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
	if text_util.is_present(content) then
		return content
	end

	local entries = extract_tag(output, "entries")
	if text_util.is_present(entries) then
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
local function add_code_entry(panel, result, text, hl_group)
	local gutter, body = split_line_number_gutter(text)
	if not gutter then
		local _, _, rows = panel.add_raw_line(result, text, hl_group)
		return text, rows
	end

	local _, _, rows = panel.add_raw_line(result, body, hl_group, {
		body_prefix = gutter,
		continuation_prefix = continuation_gutter(gutter),
	})
	return body, rows
end

local function add_wrapped_syntax_highlights(result, text, lang, row_map)
	vim.list_extend(result.highlights, syntax.project_highlights(
		syntax.highlight_text(text, lang, { scope = "tools" }),
		vim.split(text, "\n", { plain = true }),
		row_map
	))
end

-- Native read output includes a descriptive banner before the numbered lines.
function M.output_range(output)
	return tostring(output or ""):match("^Read file [^\n]+, lines (%d+)%-(%d+)\n(.*)$")
end

---@param tool_part table
---@param is_expanded boolean
---@param opts? table { body_only?: boolean }
---@return table|nil result
function M.render_tool(tool_part, is_expanded, opts)
	if type(tool_part) ~= "table" or tool_part.tool ~= "read" then
		return nil
	end

	opts = opts or {}
	local style = opts.body_only and require("opencode.ui.chat.exploration_style") or nil
	local panel = style and style.panel or panel_helpers
	local output_hl = style and style.output_hl or "OpenCodeReadOutput"
	local error_hl = style and style.body_error_hl or "OpenCodeReadError"
	local ctx = tool_panel.context(tool_part)
	local input = ctx.input
	local metadata = ctx.metadata
	local status = ctx.status
	local working = ctx.working
	local filepath = first_nonempty_trimmed_text(get_read_path(input), metadata.path)
	local output = first_nonempty_text(ctx.output)
	local error_body = trim_edge_newlines(first_nonempty_text(ctx.error))
	local body = extract_read_body(output)
	if style then
		local _, _, content = M.output_range(body)
		body = content or body
	end

	local body_entries = {}
	tool_panel.append_entries(body_entries, body, output_hl)
	tool_panel.append_error_entries(body_entries, error_body, error_hl, output_hl)

	local loaded_entries = {}
	if status == "completed" then
		loaded_entries = get_loaded_entries(metadata)
	end

	local has_overflow = #body_entries > MAX_COLLAPSED_OUTPUT_LINES
	local display_path = normalize_path(filepath)
	local header = "# Read " .. display_path

	if type(input) == "table" then
		if text_util.is_present(input.offset) then
			header = header .. " offset=" .. tostring(input.offset)
		end
		if text_util.is_present(input.limit) then
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

	local result = panel.result()
	if not style then
		panel.add_blank(result)
		local _, _, header_rows = panel.add_line(result, header, header_hl)
		panel.highlight_text(result, header_rows, display_path, "OpenCodeReadFilename")
		panel.add_blank(result)
	end
	if #body_entries == 0 and #loaded_entries == 0 then
		if not style then panel.add_separator(result) end
		return result
	end

	local read_lang = syntax.language_for_path(filepath)
	local code_lines = {}
	local code_rows = {}
	local _, render_overflow = panel.render_entries(result, body_entries, {
		expanded = is_expanded,
		max = MAX_COLLAPSED_OUTPUT_LINES,
		overflow_hl = "OpenCodeReadMuted",
		render_entry = function(_, entry)
			if read_lang and entry.hl_group == output_hl then
				local source_text, rows = add_code_entry(panel, result, entry.text, entry.hl_group)
				table.insert(code_lines, source_text)
				table.insert(code_rows, rows)
			else
				panel.add_entry(result, entry)
			end
		end,
	})
	if read_lang and #code_lines > 0 then
		add_wrapped_syntax_highlights(result, table.concat(code_lines, "\n"), read_lang, code_rows)
	end

	if not render_overflow then
		if #body_entries > 0 and #loaded_entries > 0 then
			panel.add_blank(result)
		end
		for _, entry in ipairs(loaded_entries) do
			if style then entry.hl_group = style.border_hl end
			panel.add_entry(result, entry)
		end
	end

	if not style then
		panel.add_blank(result)
		panel.add_separator(result)
	end
	return result
end

return M
