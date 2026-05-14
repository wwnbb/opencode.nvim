-- Bash tool widget renderer for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local BASH_ANIM_FRAMES = { "|", "/", "-", "\\" }

---@param result table
---@param text string
---@param hl_group string|nil
local function add_line(result, text, hl_group)
	table.insert(result.lines, text)
	if hl_group then
		table.insert(result.highlights, {
			line = #result.lines - 1,
			col_start = 0,
			col_end = #text,
			hl_group = hl_group,
		})
	end
end

---@param value any
---@return boolean
local function is_nil(value)
	return value == nil or value == vim.NIL
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

---@return string
local function get_anim_frame()
	return BASH_ANIM_FRAMES[state.task_anim_frame] or BASH_ANIM_FRAMES[1]
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
---@param command string
local function add_command(result, command)
	local lines = vim.split(command, "\n", { plain = true })
	for i, line in ipairs(lines) do
		local prefix = i == 1 and "$ " or "  "
		add_line(result, prefix .. line, "String")
	end
end

---@param tool_part table
---@param expanded boolean
---@return table|nil
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "bash" then
		return nil
	end

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = type(tool_state.input) == "table" and tool_state.input or {}
	local fallback_input = type(tool_part.input) == "table" and tool_part.input or {}
	input = vim.tbl_deep_extend("force", {}, fallback_input, input)

	local metadata = render.get_tool_metadata(tool_part)
	local status = tool_state.status or "pending"
	local working = status == "pending" or status == "running"
	local command = first_nonempty_trimmed_text(input.command, metadata.command)
	local description = first_nonempty_trimmed_text(input.description, metadata.description)
	local workdir = first_nonempty_trimmed_text(input.workdir, input.cwd, metadata.workdir, metadata.cwd)

	local result = { lines = {}, highlights = {} }
	if command == "" then
		local text = working and ("~ Writing command... " .. get_anim_frame()) or "~ Writing command..."
		add_line(result, text, working and "Special" or "Comment")
		return result
	end

	if description == "" then
		description = "Shell"
	end
	if workdir ~= "" and not description:find(workdir, 1, true) then
		description = description .. " in " .. workdir
	end

	local exit_code = normalize_exit_code(metadata.exit)
		or normalize_exit_code(metadata.exitCode)
		or normalize_exit_code(metadata.exit_code)
		or normalize_exit_code(tool_state.exit)
		or normalize_exit_code(tool_state.exitCode)
		or normalize_exit_code(tool_state.exit_code)
	local output = first_nonempty_text(tool_state.output, metadata.output, tool_part.output)
	local error_text = first_nonempty_text(tool_state.error, metadata.error, tool_part.error)
	local output_body = strip_echoed_command(output, command, workdir)
	local error_body = trim_edge_newlines(error_text)
	local has_error = status == "error" or error_body ~= "" or (exit_code ~= nil and exit_code ~= 0)

	local fold_icon = expanded and "▾" or "▸"
	local header = fold_icon .. " # " .. description
	if exit_code ~= nil and exit_code ~= 0 then
		header = header .. " (exit " .. tostring(exit_code) .. ")"
	end
	if working then
		header = header .. " " .. get_anim_frame()
	end

	local header_hl = "Comment"
	if has_error then
		header_hl = "DiagnosticError"
	elseif working then
		header_hl = "Special"
	end

	add_line(result, header, header_hl)
	add_command(result, command)

	local entries = {}
	append_body_entries(entries, output_body, nil)
	if output_body ~= "" and error_body ~= "" then
		table.insert(entries, { text = "", hl_group = nil })
	end
	append_body_entries(entries, error_body, "DiagnosticError")

	if #entries == 0 then
		return result
	end

	add_line(result, "", nil)

	local limit = expanded and #entries or math.min(MAX_COLLAPSED_OUTPUT_LINES, #entries)
	for i = 1, limit do
		local entry = entries[i]
		add_line(result, entry.text, entry.hl_group)
	end

	if not expanded and #entries > MAX_COLLAPSED_OUTPUT_LINES then
		local remaining = #entries - MAX_COLLAPSED_OUTPUT_LINES
		add_line(result, "… (" .. tostring(remaining) .. " more lines, press O to expand)", "Comment")
	end

	return result
end

return M
