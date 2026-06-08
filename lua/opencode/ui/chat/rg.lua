-- Dedicated ripgrep tool widget renderer for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local syntax = require("opencode.ui.syntax")
local text_util = require("opencode.util.text")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local PANEL_PREFIX = tool_panel.PANEL_PREFIX
local PANEL_BORDER_HL = "OpenCodeRgMuted"

local panel_helpers = tool_panel.create_panel({
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeRgOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator
local highlight_text = panel_helpers.highlight_text

local function ensure_highlights()
	panel_helpers.set_hl("OpenCodeRgMuted", "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeRgPattern", "String", "Normal", { bold = true })
	panel_helpers.set_hl("OpenCodeRgPath", "Directory", "Normal")
	panel_helpers.set_hl("OpenCodeRgFlag", "Special", "Normal")
	panel_helpers.set_hl("OpenCodeRgOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeRgError", "DiagnosticError", "ErrorMsg")
end

---@param value any
---@return boolean
local function is_nil(value)
	return text_util.is_nil(value)
end

---@param value any
---@return boolean
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

---@param raw any
---@return string
local function display_paths(raw)
	local text = vim.trim(normalize_text(raw))
	if text == "" then
		return ""
	end

	local paths = {}
	for _, path in ipairs(vim.split(text, "\n", { plain = true })) do
		path = vim.trim(path)
		if path ~= "" then
			table.insert(paths, normalize_path(path))
		end
	end
	return table.concat(paths, ", ")
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

---@param count number
---@return string
local function format_match_count(count)
	return tostring(count) .. " " .. (count == 1 and "match" or "matches")
end

---@param text string
---@return number
local function count_extra_patterns(text)
	local count = 0
	for _, pattern in ipairs(vim.split(text or "", "\n", { plain = true })) do
		if vim.trim(pattern) ~= "" then
			count = count + 1
		end
	end
	return count
end

---@param input table|string
---@return table
local function build_details(input)
	local details = {}
	local function add_value(label, value)
		local text = first_nonempty_trimmed_text(value)
		if text ~= "" then
			table.insert(details, label .. "=" .. text:gsub("\n", ","))
		end
	end
	local function add_flag(label, value)
		if value == true then
			table.insert(details, label)
		end
	end
	local function add_number(label, value)
		local number = tool_panel.normalize_number(value)
		if number and number > 0 then
			table.insert(details, label .. "=" .. tostring(number))
		end
	end

	add_value("type", input_value(input, "type"))
	add_value("exclude_type", input_value(input, "exclude_type"))
	add_value("glob", input_value(input, "glob"))
	add_number("context", input_value(input, "context"))
	add_number("before", input_value(input, "before_context"))
	add_number("after", input_value(input, "after_context"))
	add_flag("files", input_value(input, "files_only"))
	add_flag("without-match", input_value(input, "files_without_match"))
	add_flag("counts", input_value(input, "count"))
	add_flag("only-match", input_value(input, "only_matching"))
	add_flag("columns", input_value(input, "column"))
	add_flag("invert", input_value(input, "invert"))
	add_flag("fixed", input_value(input, "fixed_strings"))
	add_flag("word", input_value(input, "word"))
	add_flag("line", input_value(input, "line_match"))
	add_flag("smart-case", input_value(input, "smart_case"))
	add_flag("ignore-case", input_value(input, "case_insensitive"))
	add_flag("hidden", input_value(input, "hidden"))
	add_flag("follow", input_value(input, "follow"))
	add_flag("binary", input_value(input, "binary"))
	add_flag("no-ignore", input_value(input, "no_ignore"))
	add_flag("no-ignore-vcs", input_value(input, "no_ignore_vcs"))
	add_flag("multiline", input_value(input, "multiline"))
	add_flag("pcre2", input_value(input, "pcre2"))
	add_number("max-count", input_value(input, "max_count"))

	local extra = count_extra_patterns(first_nonempty_text(input_value(input, "extra_patterns")))
	if extra > 0 then
		table.insert(details, "extra=" .. tostring(extra))
	end

	return details
end

---@param metadata table
---@param tool_state table
---@return number|nil
local function get_match_count(metadata, tool_state)
	return tool_panel.normalize_number(metadata.matches)
		or tool_panel.normalize_number(metadata.count)
		or tool_panel.normalize_number(tool_state.matches)
		or tool_panel.normalize_number(tool_state.count)
end

---@param text string
---@return string|nil path
---@return string|nil body
---@return number|nil body_col
local function parse_rg_line(text)
	local path, line, col, body = text:match("^(.*):(%d+):(%d+):(.*)$")
	if path and path ~= "" then
		local before = path .. ":" .. line .. ":" .. col .. ":"
		return path, body, #before
	end

	path, line, body = text:match("^(.*):(%d+):(.*)$")
	if path and path ~= "" then
		local before = path .. ":" .. line .. ":"
		return path, body, #before
	end

	path, line, col, body = text:match("^(.*)%-(%d+)%-(%d+)%-(.*)$")
	if path and path ~= "" then
		local before = path .. "-" .. line .. "-" .. col .. "-"
		return path, body, #before
	end

	path, line, body = text:match("^(.*)%-(%d+)%-(.*)$")
	if path and path ~= "" then
		local before = path .. "-" .. line .. "-"
		return path, body, #before
	end

	return nil, nil, nil
end

---@param text string
---@return string|nil path
---@return string|nil count
local function parse_count_line(text)
	local path, count = text:match("^(.*):(%d+)$")
	if path and path ~= "" then
		return path, count
	end
	return nil, nil
end

---@param result table
---@param entry table
local function render_result_entry(result, entry)
	if entry.text == "" then
		add_panel_blank(result)
		return
	end

	local rg_path, rg_body, body_col = nil, nil, nil
	if entry.hl_group == "OpenCodeRgOutput" then
		rg_path, rg_body, body_col = parse_rg_line(entry.text)
	end
	local rg_lang = rg_path and syntax.language_for_path(rg_path) or nil

	if rg_lang and rg_body and rg_body ~= "" and body_col then
		local line_index, _, rows = add_panel_raw_line(result, entry.text, entry.hl_group)
		if #rows == 1 then
			syntax.add_highlights(result, rg_body, rg_lang, {
				scope = "tools",
				line_start = line_index,
				col_offset = (#PANEL_PREFIX) + body_col,
			})
		end
		return
	end

	local count_path = nil
	if entry.hl_group == "OpenCodeRgOutput" then
		count_path = parse_count_line(entry.text)
	end
	local _, _, rows = add_panel_line(result, entry.text, entry.hl_group)
	if count_path then
		highlight_text(result, rows, count_path, "OpenCodeRgPath")
	end
end

---@param tool_part table
---@param expanded boolean
---@return table|nil result
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "rg" then
		return nil
	end
	ensure_highlights()

	local ctx = tool_panel.context(tool_part)
	local tool_state = ctx.state
	local input = ctx.input
	local metadata = ctx.metadata
	local status = ctx.status
	local working = ctx.working
	local pattern = first_nonempty_trimmed_text(input_value(input, "pattern"), metadata.pattern)
	local display_path = display_paths(first_nonempty_text(input_value(input, "path"), metadata.path))
	local output = first_nonempty_text(ctx.output)
	local error_body = trim_edge_newlines(first_nonempty_text(ctx.error))
	local body = trim_edge_newlines(output)
	local output_is_error = body:match("^ripgrep error:") ~= nil
	local has_error = status == "error" or error_body ~= "" or output_is_error
	local count = get_match_count(metadata, tool_state)

	if body == "" and status == "completed" then
		body = "No matches found."
	end

	local output_hl = output_is_error and "OpenCodeRgError" or "OpenCodeRgOutput"
	if body == "No matches found." then
		output_hl = "OpenCodeRgMuted"
	end

	local entries = {}
	tool_panel.append_entries(entries, body, output_hl, {
		hl_for_line = function(line, hl_group)
			return line == "--" and "OpenCodeRgMuted" or hl_group
		end,
	})
	tool_panel.append_error_entries(entries, error_body, "OpenCodeRgError", "OpenCodeRgOutput")

	local has_overflow = #entries > MAX_COLLAPSED_OUTPUT_LINES
	local display_pattern = pattern ~= "" and pattern or "..."
	local extra_patterns = count_extra_patterns(first_nonempty_text(input_value(input, "extra_patterns")))
	local header = '# Ripgrep "' .. display_pattern .. '"'
	if extra_patterns > 0 then
		header = header .. " +" .. tostring(extra_patterns)
	end
	if display_path ~= "" then
		header = header .. " in " .. display_path
	end
	if count ~= nil then
		header = header .. " (" .. format_match_count(count) .. ")"
	end
	header = tool_panel.header(header, {
		fold = has_overflow or expanded,
		expanded = expanded,
		working = working,
	})

	local header_hl = "OpenCodeRgMuted"
	if has_error then
		header_hl = "OpenCodeRgError"
	elseif working then
		header_hl = "OpenCodeRgPattern"
	end

	local result = panel_helpers.result()
	add_panel_blank(result)
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	highlight_text(result, header_rows, '"' .. display_pattern .. '"', "OpenCodeRgPattern")
	highlight_text(result, header_rows, display_path, "OpenCodeRgPath")

	local details = build_details(input)
	if #details > 0 then
		local _, _, detail_rows = add_panel_line(result, table.concat(details, " · "), "OpenCodeRgMuted")
		for _, detail in ipairs(details) do
			local label = detail:match("^[^=]+") or detail
			highlight_text(result, detail_rows, label, "OpenCodeRgFlag")
		end
	end

	if #entries == 0 then
		add_panel_blank(result)
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)

	panel_helpers.render_entries(result, entries, {
		expanded = expanded,
		max = MAX_COLLAPSED_OUTPUT_LINES,
		overflow_hl = "OpenCodeRgMuted",
		render_entry = render_result_entry,
	})

	add_panel_blank(result)
	add_trailing_separator(result)
	return result
end

return M
