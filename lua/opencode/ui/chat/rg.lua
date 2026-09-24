-- Dedicated ripgrep tool widget renderer for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local render = require("opencode.ui.chat.render")
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
	panel_helpers.set_hl("OpenCodeRgPath", "Directory", "Normal")
	panel_helpers.set_hl("OpenCodeRgOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeRgError", "DiagnosticError", "ErrorMsg")
	-- Inline arguments use the chat background and plain text, like the TUI.
	for name, source in pairs({
		OpenCodeRgLabel = "Comment",
		OpenCodeRgValue = "Normal",
		OpenCodeRgFailure = "DiagnosticError",
	}) do
		local hl = panel_helpers.get_hl(source)
		vim.api.nvim_set_hl(0, name, { fg = hl.fg, italic = false })
	end
end

require("opencode.ui.highlights").register("opencode.ui.chat.rg", ensure_highlights)

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

local trim_edge_newlines = text_util.trim_edge_newlines

-- Lua tables do not retain the server's argument order. Keep the common search
-- fields first, followed by every other supplied option in a stable order.
local function arguments(input, metadata)
	local values = type(input) == "table" and vim.deepcopy(input) or {}
	if type(input) == "string" then
		values.pattern = input
	end
	for _, key in ipairs({ "pattern", "path" }) do
		if text_util.is_nil(values[key]) then
			values[key] = metadata[key]
		end
	end

	local result, seen = {}, {}
	local function add(key)
		seen[key] = true
		if text_util.is_nil(values[key]) then
			return
		end
		result[#result + 1] = { key = key, value = normalize_text(values[key]) }
	end
	for _, key in ipairs({ "pattern", "path", "glob", "max_results" }) do
		add(key)
	end
	local keys = {}
	for key in pairs(values) do
		if type(key) == "string" and not seen[key] then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		add(key)
	end
	return result
end

local function render_arguments(result, input, metadata, status, has_error)
	local args, summary = arguments(input, metadata), {}
	for _, arg in ipairs(args) do
		summary[#summary + 1] = arg.key .. "=" .. arg.value:gsub("\n", "\\n")
	end
	local header = "∴ rg" .. (#summary > 0 and " [" .. table.concat(summary, ", ") .. "]" or "")
	local header_hl = has_error and "OpenCodeRgFailure"
		or (status == "completed" and "OpenCodeRgLabel" or "OpenCodeRgValue")
	render.add_panel_line(result, header, header_hl, {
		prefix = "",
	})
	for _, arg in ipairs(args) do
		local label = arg.key .. ": "
		local lines = vim.split(arg.value, "\n", { plain = true })
		for i, line in ipairs(lines) do
			local _, _, rows = render.add_panel_raw_line(result, line, "OpenCodeRgValue", {
				prefix = "  ",
				body_prefix = i == 1 and label or string.rep(" ", #label),
				continuation_prefix = string.rep(" ", #label),
			})
			if i == 1 then
				highlight_text(result, rows, label, "OpenCodeRgLabel")
			end
		end
	end
end

---@param count number
---@return string
local function format_match_count(count)
	return tostring(count) .. " " .. (count == 1 and "match" or "matches")
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

	local ctx = tool_panel.context(tool_part)
	local tool_state = ctx.state
	local input = ctx.input
	local metadata = ctx.metadata
	local status = ctx.status
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

	local result = panel_helpers.result()
	render_arguments(result, input, metadata, status, has_error)

	-- Keep successful output behind the existing expand action. Failures remain
	-- visible without opening the tool, so a compact call never hides an error.
	if #entries == 0 or (not expanded and not has_error) then
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)
	local header = "▾ rg output"
	if count ~= nil then
		header = header .. " (" .. format_match_count(count) .. ")"
	end
	add_panel_line(result, header, has_error and "OpenCodeRgError" or "OpenCodeRgMuted")
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
