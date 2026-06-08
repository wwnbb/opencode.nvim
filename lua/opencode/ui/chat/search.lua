-- Glob/grep tool widget renderer for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local syntax = require("opencode.ui.syntax")
local text_util = require("opencode.util.text")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local PANEL_PREFIX = tool_panel.PANEL_PREFIX
local PANEL_BORDER_HL = "OpenCodeSearchMuted"

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

local panel_helpers = tool_panel.create_panel({
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeSearchOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator
local highlight_text = panel_helpers.highlight_text

local function ensure_highlights()
	panel_helpers.set_hl("OpenCodeSearchMuted", "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeSearchPattern", "String", "Normal", { bold = true })
	panel_helpers.set_hl("OpenCodeSearchPath", "Directory", "Normal")
	panel_helpers.set_hl("OpenCodeSearchOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeSearchError", "DiagnosticError", "ErrorMsg")
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
---@return string|nil path
---@return string|nil body
---@return number|nil body_col
local function parse_grep_line(text)
	local path, line, col, body = text:match("^(.*):(%d+):(%d+):(.*)$")
	if path and path ~= "" then
		local before = path .. ":" .. line .. ":" .. col .. ":"
		local body_col = #before
		return path, body, body_col
	end

	path, line, body = text:match("^(.*):(%d+):(.*)$")
	if path and path ~= "" then
		local before = path .. ":" .. line .. ":"
		local body_col = #before
		return path, body, body_col
	end

	return nil, nil, nil
end

---@param tool_part table
---@param expanded boolean
---@return table|nil result
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or (tool_part.tool ~= "glob" and tool_part.tool ~= "grep") then
		return nil
	end
	ensure_highlights()

	local ctx = tool_panel.context(tool_part)
	local input = ctx.input
	local metadata = ctx.metadata
	local status = ctx.status
	local working = ctx.working
	local config = TOOL_CONFIG[tool_part.tool]
	local pattern = first_nonempty_trimmed_text(input_value(input, "pattern"), metadata.pattern)
	local path = first_nonempty_trimmed_text(input_value(input, "path"), metadata.path)
	local include = first_nonempty_trimmed_text(input_value(input, "include"), metadata.include)
	local display_path = normalize_path(path)
	local output = first_nonempty_text(ctx.output)
	local error_body = trim_edge_newlines(first_nonempty_text(ctx.error))
	local count = tool_panel.normalize_number(metadata[config.count_key])
	if count == nil then
		count = tool_panel.normalize_number(ctx.state[config.count_key])
	end

	local body = trim_edge_newlines(output)
	if body == "" and status == "completed" then
		body = "No files found"
	end

	local entries = {}
	tool_panel.append_entries(entries, body, "OpenCodeSearchOutput")
	tool_panel.append_error_entries(entries, error_body, "OpenCodeSearchError", "OpenCodeSearchOutput")

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
	header = tool_panel.header(header, {
		fold = has_overflow or expanded,
		expanded = expanded,
		working = working,
	})

	local header_hl = "OpenCodeSearchMuted"
	if status == "error" or error_body ~= "" then
		header_hl = "OpenCodeSearchError"
	elseif working then
		header_hl = "OpenCodeSearchPattern"
	end

	local result = panel_helpers.result()
	add_panel_blank(result)
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	highlight_text(result, header_rows, '"' .. display_pattern .. '"', "OpenCodeSearchPattern")
	highlight_text(result, header_rows, display_path, "OpenCodeSearchPath")

	if #entries == 0 then
		add_panel_blank(result)
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)

	panel_helpers.render_entries(result, entries, {
		expanded = expanded,
		max = MAX_COLLAPSED_OUTPUT_LINES,
		overflow_hl = "OpenCodeSearchMuted",
		render_entry = function(_, entry)
			local grep_path, grep_body, body_col = nil, nil, nil
			local grep_lang = nil
			if tool_part.tool == "grep" and entry.hl_group == "OpenCodeSearchOutput" then
				grep_path, grep_body, body_col = parse_grep_line(entry.text)
				grep_lang = grep_path and syntax.language_for_path(grep_path) or nil
			end

			if grep_lang and grep_body and grep_body ~= "" and body_col then
				local line_index, _, rows = add_panel_raw_line(result, entry.text, entry.hl_group)
				if #rows == 1 then
					syntax.add_highlights(result, grep_body, grep_lang, {
						scope = "tools",
						line_start = line_index,
						col_offset = (#PANEL_PREFIX) + body_col,
					})
				end
			else
				panel_helpers.add_entry(result, entry)
			end
		end,
	})

	add_panel_blank(result)
	add_trailing_separator(result)
	return result
end

return M
