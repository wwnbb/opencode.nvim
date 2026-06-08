-- Bash tool widget renderer for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local syntax = require("opencode.ui.syntax")
local text_util = require("opencode.util.text")

local MAX_COLLAPSED_COMMAND_LINES = 12
local MAX_COLLAPSED_OUTPUT_LINES = 10
local PANEL_PREFIX = tool_panel.PANEL_PREFIX
local PANEL_BORDER_HL = "OpenCodeBashMuted"

local panel_helpers = tool_panel.create_panel({
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeBashOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank

local function ensure_highlights()
	panel_helpers.set_hl("OpenCodeBashMuted", "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeBashCommand", "String", "Normal")
	panel_helpers.set_hl("OpenCodeBashOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeBashError", "DiagnosticError", "ErrorMsg")
end

---@param value any
---@return boolean
local function is_nil(value)
	return text_util.is_nil(value)
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
		if type(value.stdout) == "string" or type(value.stderr) == "string" then
			local parts = {}
			if type(value.stdout) == "string" and value.stdout ~= "" then
				table.insert(parts, value.stdout)
			end
			if type(value.stderr) == "string" and value.stderr ~= "" then
				table.insert(parts, value.stderr)
			end
			return table.concat(parts, "\n")
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

---@param lines string[]
---@param start_index number
---@return string
local function join_from(lines, start_index)
	local out = {}
	for i = start_index, #lines do
		table.insert(out, lines[i])
	end
	return table.concat(out, "\n")
end

---@param output string
---@param command string
---@param workdir string
---@return string
local function strip_echoed_command(output, command, workdir)
	local cmd = vim.trim(command or "")
	if cmd == "" then
		return trim_edge_newlines(output)
	end

	local wd_raw = vim.trim(workdir or "")
	local lines = vim.split(output or "", "\n", { plain = true })
	local first = vim.trim(lines[1] or "")
	local second = vim.trim(lines[2] or "")

	if wd_raw ~= "" and (first == wd_raw) and second == cmd then
		return trim_edge_newlines(join_from(lines, 3))
	end

	if first == cmd or first == "$ " .. cmd then
		return trim_edge_newlines(join_from(lines, 2))
	end

	if wd_raw ~= "" and first == wd_raw .. " " .. cmd then
		return trim_edge_newlines(join_from(lines, 2))
	end

	return trim_edge_newlines(output)
end

---@param value any
---@return number|nil
local function normalize_exit_code(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" and value ~= "" then
		local num = tonumber(value)
		if num then
			return num
		end
	end
	return nil
end

---@param result table
---@param command_lines string[]
---@param expanded boolean
local function add_command(result, command_lines, expanded)
	local start_line = nil
	local can_highlight = true
	local limit = expanded and #command_lines or math.min(MAX_COLLAPSED_COMMAND_LINES, #command_lines)
	local displayed_lines = {}
	for i = 1, limit do
		local line = command_lines[i] or ""
		table.insert(displayed_lines, line)
		local prefix = i == 1 and "$ " or "  "
		local line_index, _, rows = add_panel_raw_line(result, prefix .. line, "OpenCodeBashCommand")
		start_line = start_line or line_index
		if #rows > 1 then
			can_highlight = false
		end
	end

	if not expanded and #command_lines > MAX_COLLAPSED_COMMAND_LINES then
		add_panel_line(
			result,
			tool_panel.overflow_text(#command_lines - MAX_COLLAPSED_COMMAND_LINES, "command lines"),
			"OpenCodeBashMuted"
		)
	end

	if start_line and can_highlight then
		syntax.add_highlights(result, table.concat(displayed_lines, "\n"), "bash", {
			scope = "tools",
			line_start = start_line,
			col_offset = #PANEL_PREFIX + #"$ ",
		})
	end
end

---@param tool_part table
---@param expanded boolean
---@return table|nil
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "bash" then
		return nil
	end
	ensure_highlights()

	local ctx = tool_panel.context(tool_part)
	local tool_state = ctx.state
	local input = type(ctx.input) == "table" and ctx.input or {}
	local metadata = ctx.metadata
	local status = ctx.status
	local working = ctx.working
	local command = first_nonempty_trimmed_text(input.command, metadata.command)
	local description = first_nonempty_trimmed_text(input.description, metadata.description)
	local workdir = first_nonempty_trimmed_text(input.workdir, metadata.workdir)

	local result = panel_helpers.result()
	add_panel_blank(result)
	if command == "" then
		local text = working and ("~ Writing command... " .. tool_panel.anim_frame()) or "~ Writing command..."
		add_panel_line(result, text, working and "OpenCodeBashCommand" or "OpenCodeBashMuted")
		add_panel_blank(result)
		return result
	end

	if description == "" then
		description = "Shell"
	end
	if workdir ~= "" and not description:find(workdir, 1, true) then
		description = description .. " in " .. workdir
	end

	local exit_code = normalize_exit_code(metadata.exit)
		or normalize_exit_code(tool_state.exit)
	local output = first_nonempty_text(ctx.output)
	local error_text = first_nonempty_text(ctx.error)
	local output_body = strip_echoed_command(output, command, workdir)
	local error_body = trim_edge_newlines(error_text)
	local has_error = status == "error" or error_body ~= "" or (exit_code ~= nil and exit_code ~= 0)
	local command_lines = vim.split(command, "\n", { plain = true })
	local has_command_overflow = #command_lines > MAX_COLLAPSED_COMMAND_LINES
	local entries = {}
	tool_panel.append_entries(entries, output_body, "OpenCodeBashOutput")
	tool_panel.append_error_entries(entries, error_body, "OpenCodeBashError", "OpenCodeBashOutput")
	local has_overflow = #entries > MAX_COLLAPSED_OUTPUT_LINES
	local output_probe_lines = {}
	for _, entry in ipairs(entries) do
		if entry.hl_group == "OpenCodeBashOutput" and entry.text ~= "" then
			table.insert(output_probe_lines, entry.text)
		end
	end
	local output_lang = syntax.detect_output_language(table.concat(output_probe_lines, "\n"), metadata)

	local header = "# " .. description
	if exit_code ~= nil and exit_code ~= 0 then
		header = header .. " (exit " .. tostring(exit_code) .. ")"
	end
	header = tool_panel.header(header, {
		fold = has_command_overflow or has_overflow or expanded,
		expanded = expanded,
		working = working,
	})

	local header_hl = "OpenCodeBashMuted"
	if has_error then
		header_hl = "OpenCodeBashError"
	elseif working then
		header_hl = "OpenCodeBashCommand"
	end

	add_panel_line(result, header, header_hl)
	add_panel_blank(result)
	add_command(result, command_lines, expanded)

	if #entries == 0 then
		add_panel_blank(result)
		return result
	end

	add_panel_blank(result)

	local output_start_line = nil
	local output_lines = {}
	local can_highlight_output = true
	panel_helpers.render_entries(result, entries, {
		expanded = expanded,
		max = MAX_COLLAPSED_OUTPUT_LINES,
		overflow_hl = "OpenCodeBashMuted",
		render_entry = function(_, entry)
			if output_lang and entry.hl_group == "OpenCodeBashOutput" then
				local line_index, _, rows = add_panel_raw_line(result, entry.text, entry.hl_group)
				output_start_line = output_start_line or line_index
				table.insert(output_lines, entry.text)
				if #rows > 1 then
					can_highlight_output = false
				end
			elseif entry.text == "" then
				add_panel_blank(result)
			else
				add_panel_line(result, entry.text, entry.hl_group)
			end
		end,
	})
	if output_lang and output_start_line and #output_lines > 0 and can_highlight_output then
		local output_text = table.concat(output_lines, "\n")
		if output_lang == "markdown" then
			syntax.add_markdown_highlights(result, output_text, {
				scope = "tools",
				line_start = output_start_line,
				col_offset = #PANEL_PREFIX,
				compat_markdown = false,
			})
		else
			syntax.add_highlights(result, output_text, output_lang, {
				scope = "tools",
				line_start = output_start_line,
				col_offset = #PANEL_PREFIX,
			})
		end
	end

	add_panel_blank(result)
	return result
end

return M
