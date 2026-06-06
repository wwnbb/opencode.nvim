-- Dedicated ripgrep tool widget renderer for the chat buffer.

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
local PANEL_BORDER_HL = "OpenCodeRgMuted"
local RG_ANIM_FRAMES = { "|", "/", "-", "\\" }

local panel_helpers = panel.create_helpers({
	prefix = PANEL_PREFIX,
	blank_prefix = PANEL_BLANK_PREFIX,
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeRgOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator
local highlight_text = panel_helpers.highlight_text

local function set_panel_hl(name, fg_source, fallback, extra_opts)
	panel_helpers.set_hl(name, fg_source, fallback, extra_opts)
end

local function ensure_highlights()
	set_panel_hl("OpenCodeRgMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeRgPattern", "String", "Normal", { bold = true })
	set_panel_hl("OpenCodeRgPath", "Directory", "Normal")
	set_panel_hl("OpenCodeRgFlag", "Special", "Normal")
	set_panel_hl("OpenCodeRgOutput", "Normal", nil)
	set_panel_hl("OpenCodeRgError", "DiagnosticError", "ErrorMsg")
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

---@return string
local function get_anim_frame()
	return RG_ANIM_FRAMES[state.task_anim_frame] or RG_ANIM_FRAMES[1]
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
		local number = normalize_number(value)
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
	return normalize_number(metadata.matches)
		or normalize_number(metadata.matchCount)
		or normalize_number(metadata.match_count)
		or normalize_number(metadata.count)
		or normalize_number(tool_state.matches)
		or normalize_number(tool_state.matchCount)
		or normalize_number(tool_state.match_count)
		or normalize_number(tool_state.count)
end

---@param entries table[]
---@param text string
---@param hl_group string|nil
local function append_body_entries(entries, text, hl_group)
	if text == "" then
		return
	end
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		local line_hl = hl_group
		if line == "--" then
			line_hl = "OpenCodeRgMuted"
		end
		table.insert(entries, { text = line, hl_group = line_hl })
	end
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
local function add_entry(result, entry)
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

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = get_input(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	local status = tool_state.status or "pending"
	local working = status == "pending" or status == "running"
	local pattern = first_nonempty_trimmed_text(input_value(input, "pattern"), metadata.pattern)
	local display_path = display_paths(first_nonempty_text(input_value(input, "path"), metadata.path))
	local output = first_nonempty_text(tool_state.output, metadata.output, tool_part.output, metadata.preview)
	local error_body = trim_edge_newlines(first_nonempty_text(tool_state.error, metadata.error, tool_part.error))
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
	append_body_entries(entries, body, output_hl)
	if #entries > 0 and error_body ~= "" then
		table.insert(entries, { text = "", hl_group = "OpenCodeRgOutput" })
	end
	append_body_entries(entries, error_body, "OpenCodeRgError")

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
	if working then
		header = header .. " " .. get_anim_frame()
	end
	if has_overflow or expanded then
		local fold_icon = expanded and "▾" or "▸"
		header = fold_icon .. " " .. header
	end

	local header_hl = "OpenCodeRgMuted"
	if has_error then
		header_hl = "OpenCodeRgError"
	elseif working then
		header_hl = "OpenCodeRgPattern"
	end

	local result = { lines = {}, highlights = {} }
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

	local limit = expanded and #entries or math.min(MAX_COLLAPSED_OUTPUT_LINES, #entries)
	for i = 1, limit do
		add_entry(result, entries[i])
	end

	if not expanded and has_overflow then
		local remaining = #entries - MAX_COLLAPSED_OUTPUT_LINES
		add_panel_line(result, "… (" .. tostring(remaining) .. " more lines, press O to expand)", "OpenCodeRgMuted")
	end

	add_panel_blank(result)
	add_trailing_separator(result)
	return result
end

return M
