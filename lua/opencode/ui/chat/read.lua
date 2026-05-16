-- Dedicated read tool rendering for the chat buffer.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")
local syntax = require("opencode.ui.syntax")

local MAX_COLLAPSED_OUTPUT_LINES = 10
local READ_ANIM_FRAMES = { "|", "/", "-", "\\" }

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
	set_panel_hl("OpenCodeReadMuted", "Comment", "Normal")
	set_panel_hl("OpenCodeReadPath", "String", "Normal")
	set_panel_hl("OpenCodeReadFilename", "String", "Normal", { bold = true })
	set_panel_hl("OpenCodeReadOutput", "Normal", nil)
	set_panel_hl("OpenCodeReadError", "DiagnosticError", "ErrorMsg")
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
---@param text string
---@param hl_group string
---@return number line_index
---@return string line
---@return table[] rows
local function add_panel_raw_line(result, text, hl_group)
	return render.add_panel_raw_line(result, text, hl_group)
end

---@param result table
local function add_panel_blank(result)
	render.add_panel_blank(result, "OpenCodeReadOutput")
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
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	render.highlight_panel_text(result, header_rows, display_path, "OpenCodeReadFilename")

	if #body_entries == 0 and #loaded_entries == 0 then
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)

	local read_lang = syntax.language_for_path(filepath)
	local code_start_line = nil
	local code_lines = {}
	local can_highlight_code = true
	local limit = is_expanded and #body_entries or math.min(MAX_COLLAPSED_OUTPUT_LINES, #body_entries)
	for i = 1, limit do
		local entry = body_entries[i]
		if read_lang and entry.hl_group == "OpenCodeReadOutput" then
			local line_index, _, rows = add_panel_raw_line(result, entry.text, entry.hl_group)
			code_start_line = code_start_line or line_index
			table.insert(code_lines, entry.text)
			if #rows > 1 then
				can_highlight_code = false
			end
		else
			add_entry(result, entry)
		end
	end
	if read_lang and code_start_line and #code_lines > 0 and can_highlight_code then
		syntax.add_highlights(result, table.concat(code_lines, "\n"), read_lang, {
			scope = "tools",
			line_start = code_start_line,
			col_offset = #"▏  ",
		})
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

	add_trailing_separator(result)
	return result
end

return M
