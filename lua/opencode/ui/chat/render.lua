-- Pure NuiLine-based rendering helpers for the chat buffer.
-- No state mutations here — functions only read state (for window width) or
-- operate on their arguments.  The animation frame is passed in as a parameter
-- so this module stays free of timer side-effects.

local M = {}

local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local thinking = require("opencode.ui.thinking")
local locale = require("opencode.util.locale")
local sync = require("opencode.sync")
local syntax = require("opencode.ui.syntax")

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns
local PANEL_BACKGROUND_HL_PRIORITY = 4000
local UI_HIGHLIGHT_PRIORITY = 4200
local PANEL_PREFIX_HL_PRIORITY = UI_HIGHLIGHT_PRIORITY + 1

local function ensure_user_message_highlights()
	vim.api.nvim_set_hl(0, "OpenCodeUserMessageBg", { link = "CursorLine", default = true })
end

---@return number width
local function get_chat_text_width()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return 80
	end

	local width = vim.api.nvim_win_get_width(state.winid)
	local wininfo = vim.fn.getwininfo(state.winid)[1]
	local textoff = wininfo and tonumber(wininfo.textoff) or 0
	return math.max(1, width - textoff)
end

---@return number width
function M.get_chat_text_width()
	return get_chat_text_width()
end

---@param text any
---@return string
function M.sanitize_buffer_line(text)
	text = type(text) == "string" and text or tostring(text or "")
	return (text:gsub("\r\n", " ↵ "):gsub("\n", " ↵ "):gsub("\r", " ↵ "):gsub("%z", "<NUL>"))
end

---@param text any
---@return number
local function safe_display_width(text)
	local safe_text = M.sanitize_buffer_line(text)
	local ok, width = pcall(vim.fn.strdisplaywidth, safe_text)
	if ok and type(width) == "number" then
		return width
	end
	return #safe_text
end

-- ─── Agent highlight ─────────────────────────────────────────────────────────

---@param agent_name string
---@return string hl_group
function M.get_agent_hl(agent_name)
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		return lc.agent.color(agent_name)
	end
	return "DiagnosticInfo"
end

-- ─── Small text helpers ───────────────────────────────────────────────────────

---@param raw string|nil
---@return string
function M.format_title(raw)
	if type(raw) ~= "string" or raw == "" then
		return "Unknown"
	end
	return raw:sub(1, 1):upper() .. raw:sub(2)
end

---@param summary_raw any
---@return table[]
function M.normalize_task_summary(summary_raw)
	if type(summary_raw) ~= "table" then
		return {}
	end

	local normalized = {}
	for _, item in pairs(summary_raw) do
		if type(item) == "table" then
			table.insert(normalized, item)
		end
	end

	if #normalized <= 1 then
		return normalized
	end

	table.sort(normalized, function(a, b)
		local a_id = tostring(a.id or "")
		local b_id = tostring(b.id or "")
		return a_id < b_id
	end)
	return normalized
end

---@param tool_part table
---@return table
function M.get_tool_metadata(tool_part)
	local part_metadata = tool_part and tool_part.metadata or {}
	local state_metadata = (tool_part and tool_part.state and tool_part.state.metadata) or {}
	return vim.tbl_deep_extend("force", {}, part_metadata, state_metadata)
end

---@param value table
---@return string
local function json_or_inspect(value)
	local ok, encoded = pcall(vim.json.encode, value)
	if ok and type(encoded) == "string" then
		return encoded
	end
	return vim.inspect(value)
end

-- ─── Text wrapping ────────────────────────────────────────────────────────────

---@param text string
---@param byte_pos number 0-based byte offset
---@return number length
local function utf8_char_len_at(text, byte_pos)
	local first = text:byte(byte_pos + 1)
	if not first then
		return 0
	end
	local length
	if first < 0x80 then
		length = 1
	elseif first < 0xE0 then
		length = 2
	elseif first < 0xF0 then
		length = 3
	elseif first < 0xF8 then
		length = 4
	else
		length = 1
	end
	return math.min(length, #text - byte_pos)
end

---@return number
local function get_tabstop()
	local value = tonumber(vim.bo.tabstop) or tonumber(vim.o.tabstop) or 8
	if value <= 0 then
		return 8
	end
	return value
end

---@param ch string
---@param col number
---@return number
local function char_display_width(ch, col)
	if ch == "\t" then
		local tabstop = get_tabstop()
		return tabstop - (col % tabstop)
	end
	return safe_display_width(ch)
end

---@param text string
---@param initial_col number
---@return number
local function display_width_from_col(text, initial_col)
	local width = 0
	local byte_pos = 0
	while byte_pos < #text do
		local char_len = utf8_char_len_at(text, byte_pos)
		local ch = text:sub(byte_pos + 1, byte_pos + char_len)
		width = width + char_display_width(ch, initial_col + width)
		byte_pos = byte_pos + char_len
	end
	return width
end

---Wrap a string to fit within max_width, breaking at word boundaries.
---@param text string
---@param max_width number
---@param opts? table
---@return table[] chunks
function M.wrap_text_with_ranges(text, max_width, opts)
	opts = opts or {}
	text = M.sanitize_buffer_line(text)
	if max_width <= 0 then
		return {
			{
				text = text,
				byte_start = 0,
				byte_end = #text,
			},
		}
	end
	local initial_col = opts.initial_col or 0
	if display_width_from_col(text, initial_col) <= max_width then
		return {
			{
				text = text,
				byte_start = 0,
				byte_end = #text,
			},
		}
	end

	local result = {}
	local remaining = text
	local remaining_start = 0
	while display_width_from_col(remaining, initial_col) > max_width do
		local last_space_byte = nil
		local byte_pos = 0
		local col = 0
		while byte_pos < #remaining do
			local char_len = utf8_char_len_at(remaining, byte_pos)
			local ch = remaining:sub(byte_pos + 1, byte_pos + char_len)
			local char_width = char_display_width(ch, initial_col + col)
			if col + char_width > max_width then
				if byte_pos == 0 then
					byte_pos = char_len
				end
				break
			end
			col = col + char_width
			byte_pos = byte_pos + char_len
			if ch:match("%s") then
				last_space_byte = byte_pos
			end
		end
		local cut_at_space = last_space_byte and last_space_byte > 0
		local cut = cut_at_space and last_space_byte or byte_pos
		if cut <= 0 then
			cut = utf8_char_len_at(remaining, 0)
		end
		local raw_piece = remaining:sub(1, cut)
		local piece = raw_piece:gsub("%s+$", "")
		local piece_end = remaining_start + #piece
		if piece == "" then
			piece = raw_piece
			piece_end = remaining_start + #piece
		end
		table.insert(result, {
			text = piece,
			byte_start = remaining_start,
			byte_end = piece_end,
		})
		remaining = remaining:sub(cut + 1)
		remaining_start = remaining_start + cut
		if cut_at_space and remaining:sub(1, 1):match("%s") then
			remaining = remaining:sub(2)
			remaining_start = remaining_start + 1
		end
	end
	if #remaining > 0 then
		table.insert(result, {
			text = remaining,
			byte_start = remaining_start,
			byte_end = #text,
		})
	end
	return result
end

---Wrap a string to fit within max_width, breaking at word boundaries.
---@param text string
---@param max_width number
---@param opts? table
---@return string[]
function M.wrap_text(text, max_width, opts)
	local result = {}
	for _, chunk in ipairs(M.wrap_text_with_ranges(text, max_width, opts)) do
		table.insert(result, chunk.text)
	end
	return result
end

---@param text string
---@param width? number
---@return string
function M.pad_to_width(text, width)
	width = width or get_chat_text_width()
	text = M.sanitize_buffer_line(text)
	local current = safe_display_width(text)
	if current >= width then
		return text
	end
	return text .. string.rep(" ", width - current)
end

---@param result table
---@param line_index number
---@param prefix string
---@param hl_group string|nil
local function add_panel_prefix_highlight(result, line_index, prefix, hl_group)
	if not hl_group or prefix == "" then
		return
	end
	table.insert(result.highlights, {
		line = line_index,
		col_start = 0,
		col_end = #prefix,
		hl_group = hl_group,
		priority = PANEL_PREFIX_HL_PRIORITY,
	})
end

---@param result table
---@param line_index number
---@param line string
---@param hl_group string|nil
local function add_panel_background_highlight(result, line_index, line, hl_group)
	if not hl_group then
		return
	end
	table.insert(result.highlights, {
		line = line_index,
		col_start = 0,
		col_end = #line,
		hl_group = hl_group,
		priority = PANEL_BACKGROUND_HL_PRIORITY,
	})
end

---@param result table
---@param text string
---@param hl_group string|nil
---@param opts? table { prefix?: string, width?: number, prefix_hl_group?: string }
---@return number line_index
---@return string line
---@return table[] rows
function M.add_panel_line(result, text, hl_group, opts)
	opts = opts or {}
	result.lines = result.lines or {}
	result.highlights = result.highlights or {}

	local prefix = opts.prefix or "▏  "
	local width = opts.width or get_chat_text_width()
	local prefix_width = safe_display_width(prefix)
	local body_width = math.max(1, width - prefix_width)
	local chunks = M.wrap_text_with_ranges(M.sanitize_buffer_line(text), body_width, {
		initial_col = prefix_width,
	})
	local rows = {}

	for _, chunk in ipairs(chunks) do
		local line = M.pad_to_width(prefix .. chunk.text, width)
		table.insert(result.lines, line)
		local line_index = #result.lines - 1
		add_panel_background_highlight(result, line_index, line, hl_group)
		add_panel_prefix_highlight(result, line_index, prefix, opts.prefix_hl_group)
		table.insert(rows, {
			line_index = line_index,
			line = line,
			text = chunk.text,
			prefix = prefix,
			byte_start = chunk.byte_start,
			byte_end = chunk.byte_end,
		})
	end

	return rows[1].line_index, rows[1].line, rows
end

---@param result table
---@param text string
---@param hl_group string|nil
---@param opts? table
---@return number line_index
---@return string line
---@return table[] rows
function M.add_panel_raw_line(result, text, hl_group, opts)
	opts = opts or {}
	result.lines = result.lines or {}
	result.highlights = result.highlights or {}

	local prefix = opts.prefix or "▏  "
	local width = opts.width or get_chat_text_width()
	local body = M.sanitize_buffer_line(text)
	local body_prefix = opts.body_prefix or ""
	local continuation_prefix = opts.continuation_prefix or body_prefix
	local body_prefix_width = math.max(
		safe_display_width(body_prefix),
		safe_display_width(continuation_prefix)
	)
	local prefix_width = safe_display_width(prefix)
	local body_width = math.max(1, width - prefix_width - body_prefix_width)
	local chunks = opts.wrap ~= false and M.wrap_text_with_ranges(body, body_width, {
		initial_col = prefix_width + body_prefix_width,
	}) or {
		{
			text = body,
			byte_start = 0,
			byte_end = #body,
		},
	}
	local rows = {}

	for index, chunk in ipairs(chunks) do
		local row_body_prefix = index == 1 and body_prefix or continuation_prefix
		local row_prefix = prefix .. row_body_prefix
		local line = M.pad_to_width(row_prefix .. chunk.text, width)
		table.insert(result.lines, line)

		local line_index = #result.lines - 1
		add_panel_background_highlight(result, line_index, line, hl_group)
		add_panel_prefix_highlight(result, line_index, prefix, opts.prefix_hl_group)
		table.insert(rows, {
			line_index = line_index,
			line = line,
			text = chunk.text,
			prefix = row_prefix,
			byte_start = chunk.byte_start,
			byte_end = chunk.byte_end,
		})
	end

	return rows[1].line_index, rows[1].line, rows
end

---@param result table
---@param hl_group string|nil
---@param opts? table { prefix?: string, width?: number, prefix_hl_group?: string }
---@return number line_index
---@return string line
---@return table[] rows
function M.add_panel_blank(result, hl_group, opts)
	opts = opts or {}
	result.lines = result.lines or {}
	result.highlights = result.highlights or {}

	local prefix = opts.prefix or "▏"
	local width = opts.width or get_chat_text_width()
	local line = M.pad_to_width(prefix, width)
	table.insert(result.lines, line)
	local line_index = #result.lines - 1
	add_panel_background_highlight(result, line_index, line, hl_group)
	add_panel_prefix_highlight(result, line_index, prefix, opts.prefix_hl_group)

	return line_index, line, {
		{
			line_index = line_index,
			line = line,
			text = "",
			prefix = prefix,
		},
	}
end

---@param result table
---@param rows table[]|nil
---@param text string
---@param hl_group string
---@return boolean highlighted
function M.highlight_panel_text(result, rows, text, hl_group)
	if text == "" or not rows then
		return false
	end
	result.highlights = result.highlights or {}
	for _, row in ipairs(rows) do
		local start_pos = row.line:find(text, 1, true)
		if start_pos then
			table.insert(result.highlights, {
				line = row.line_index,
				col_start = start_pos - 1,
				col_end = start_pos + #text - 1,
				hl_group = hl_group,
			})
			return true
		end
	end
	return false
end

-- ─── User message display config ─────────────────────────────────────────────

---@return string prompt, boolean multiline_prefix
function M.get_user_message_display()
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}
	local display_cfg = full_config.chat and full_config.chat.message_display or {}
	local message_prefix = display_cfg and display_cfg.user_prefix
	local prompt
	if type(message_prefix) == "string" then
		prompt = message_prefix
	else
		local chat_prompt = full_config.chat and full_config.chat.input and full_config.chat.input.prompt
		if type(chat_prompt) == "string" then
			prompt = chat_prompt
		else
			local input_prompt = full_config.input and full_config.input.prompt
			prompt = type(input_prompt) == "string" and input_prompt or "> "
		end
	end
	local multiline_prefix = display_cfg and display_cfg.multiline_prefix
	if type(multiline_prefix) ~= "boolean" then
		multiline_prefix = true
	end
	return prompt, multiline_prefix
end

-- ─── NuiLine renderers ────────────────────────────────────────────────────────

---Render a user message using NuiLine.
---@param content string|nil
---@param agent_name string|nil
---@param files? table[]
---@return NuiLine[]
function M.render_user_message(content, agent_name, files)
	ensure_user_message_highlights()

	local lines = {}
	local content_lines = vim.split(content or "", "\n", { plain = true })
	local border_hl = M.get_agent_hl(agent_name or "unknown")

	local text_width = get_chat_text_width()
	local bg_width = math.max(1, text_width - 1)
	local content_width = math.max(1, bg_width - 2)

	local function pad_after_prefix(prefix, text, width)
		local current = safe_display_width(prefix .. text)
		if current >= width then
			return text
		end
		return text .. string.rep(" ", width - current)
	end

	local function add_block_line(text)
		local line = NuiLine()
		line:append(NuiText("┃", border_hl))
		line:append(NuiText(pad_after_prefix("┃", text, text_width), "OpenCodeUserMessageBg"))
		table.insert(lines, line)
	end

	add_block_line("")

	for _, text in ipairs(content_lines) do
		local wrapped = M.wrap_text(text, content_width, {
			initial_col = safe_display_width("┃  "),
		})
		for _, wline in ipairs(wrapped) do
			add_block_line("  " .. wline)
		end
	end

	for _, file in ipairs(files or {}) do
		local mime = file.mime or "file"
		local label = mime:match("^image/") and "img" or (mime == "application/pdf" and "pdf" or "file")
		local filename = file.filename or file.name or file.uri or "attachment"
		local display = label .. " " .. filename
		local wrapped = M.wrap_text(display, content_width, {
			initial_col = safe_display_width("┃  "),
		})
		for _, wline in ipairs(wrapped) do
			add_block_line("  " .. wline)
		end
	end

	add_block_line("")
	return lines
end

---Render reasoning using NuiLine.
---@param reasoning string|nil
---@return NuiLine[]
function M.render_reasoning(reasoning)
	local lines = {}
	if not reasoning or reasoning == "" or not thinking.is_enabled() then
		return lines
	end

	local reasoning_lines = vim.split(reasoning, "\n", { plain = true })
	for i, rline in ipairs(reasoning_lines) do
		local line = NuiLine()
		if i == 1 then
			line:append(NuiText("Thinking: ", "WarningMsg"))
			line:append(NuiText(rline, "Comment"))
		else
			line:append(NuiText("          " .. rline, "Comment"))
		end
		table.insert(lines, line)
	end

	if #lines > 0 then
		table.insert(lines, NuiLine())
	end
	return lines
end

---Render content using plain text lines only.
---@param content string|nil
---@param _opts? table
---@return NuiLine[]
function M.render_content(content, _opts)
	local opts = _opts or {}
	local lines = {}
	if not content or content == "" then
		return lines
	end

	local content_lines = vim.split(content, "\n", { plain = true })
	for _, text in ipairs(content_lines) do
		local line = NuiLine()
		line:append(text)
		table.insert(lines, line)
	end

	if not opts.stream_plain and syntax.is_enabled("assistant_markdown") then
		lines._opencode_highlights = syntax.highlight_markdown_fenced_blocks(content, {
			scope = "assistant_markdown",
			compat_markdown = true,
		})
	end

	return lines
end

---Render a single tool line (fold icon + status + tool name, optional expanded body).
---@param tool_part table
---@param is_expanded boolean
---@return table { lines: string[], highlights: table[] }
function M.render_tool_line(tool_part, is_expanded)
	local tool_name = tool_part.tool or "unknown"
	local tool_status = tool_part.state and tool_part.state.status or "pending"

	local status_symbol = "○"
	local status_hl = "Comment"
	if tool_status == "completed" then
		status_symbol = "●"
		status_hl = "Normal"
	elseif tool_status == "running" then
		status_symbol = "◐"
		status_hl = "WarningMsg"
	elseif tool_status == "error" then
		status_symbol = "✗"
		status_hl = "ErrorMsg"
	end

	local result_lines = {}
	local result_highlights = {}

	local function add_hl_line(text, hl_group)
		table.insert(result_lines, text)
		if hl_group then
			table.insert(result_highlights, {
				line = #result_lines - 1,
				col_start = 0,
				col_end = #text,
				hl_group = hl_group,
			})
		end
	end

	local fold_icon = is_expanded and "▾" or "▸"
	local header = fold_icon .. " " .. status_symbol .. " " .. tool_name
	if tool_part.input and tool_part.input.description then
		header = header .. " - " .. tool_part.input.description
	end
	add_hl_line(header, status_hl)

	if is_expanded then
		local tool_state_data = tool_part.state or {}
		local tool_input = tool_state_data.input
		local tool_output = tool_state_data.output
		local tool_error = tool_state_data.error

		if tool_input then
			local input_str = type(tool_input) == "string" and tool_input or json_or_inspect(tool_input)
			add_hl_line("  Input: ", "Special")
			local input_start = #result_lines
			for _, iline in ipairs(vim.split(input_str, "\n", { plain = true })) do
				add_hl_line("    " .. iline, "Comment")
			end
			local input_lang = type(tool_input) == "table" and "json" or syntax.detect_output_language(input_str, nil)
			if input_lang then
				if input_lang == "markdown" then
					syntax.add_markdown_highlights({ highlights = result_highlights }, input_str, {
						scope = "tools",
						line_start = input_start,
						col_offset = 4,
						compat_markdown = false,
					})
				else
					syntax.add_highlights({ highlights = result_highlights }, input_str, input_lang, {
						scope = "tools",
						line_start = input_start,
						col_offset = 4,
					})
				end
			end
		end

		if tool_output then
			local output_str = type(tool_output) == "string" and tool_output or json_or_inspect(tool_output)
			add_hl_line("  Output: ", "Special")
			local output_start = #result_lines
			for _, oline in ipairs(vim.split(output_str, "\n", { plain = true })) do
				add_hl_line("    " .. oline, "Comment")
			end
			local output_lang = type(tool_output) == "table" and "json"
				or syntax.detect_output_language(output_str, M.get_tool_metadata(tool_part))
			if output_lang == "markdown" then
				syntax.add_markdown_highlights({ highlights = result_highlights }, output_str, {
					scope = "tools",
					line_start = output_start,
					col_offset = 4,
					compat_markdown = false,
				})
			elseif output_lang then
				syntax.add_highlights({ highlights = result_highlights }, output_str, output_lang, {
					scope = "tools",
					line_start = output_start,
					col_offset = 4,
				})
			end
		end

		if tool_error then
			local error_str = type(tool_error) == "string" and tool_error or vim.inspect(tool_error)
			add_hl_line("  Error: ", "ErrorMsg")
			for _, eline in ipairs(vim.split(error_str, "\n", { plain = true })) do
				add_hl_line("    " .. eline, "ErrorMsg")
			end
		end
	end

	return { lines = result_lines, highlights = result_highlights }
end

-- ─── NuiLine utilities ────────────────────────────────────────────────────────

---Extract raw content strings from NuiLine array.
---@param nui_lines NuiLine[]
---@return string[]
function M.extract_lines(nui_lines)
	local lines = {}
	for _, nui_line in ipairs(nui_lines) do
		table.insert(lines, M.sanitize_buffer_line(nui_line:content()))
	end
	return lines
end

---Apply NuiLine highlights to a buffer.
---@param nui_lines NuiLine[]
---@param bufnr number
---@param ns_id number
---@param start_line number 0-indexed
function M.apply_highlights(nui_lines, bufnr, ns_id, start_line)
	for i, nui_line in ipairs(nui_lines) do
		nui_line:highlight(bufnr, ns_id, start_line + i - 1)
	end
	M.apply_extmark_highlights(bufnr, ns_id, nui_lines._opencode_highlights, start_line)
end

---@param bufnr number
---@param ns_id number
---@param highlights table[]|nil
---@param start_line number
---@param opts? table
function M.apply_extmark_highlights(bufnr, ns_id, highlights, start_line, opts)
	if type(highlights) ~= "table" then
		return
	end

	opts = opts or {}
	local min_line = opts.min_line
	local max_line = opts.max_line
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	for _, hl in ipairs(highlights) do
		if type(hl) == "table" and hl.hl_group then
			local line = start_line + (hl.line or 0)
			local end_line = hl.end_line and (start_line + hl.end_line) or line
			local in_bounds = line >= 0 and line < line_count
			local after_min = not min_line or end_line >= min_line
			local before_max = not max_line or line < max_line
			if in_bounds and after_min and before_max then
				local col_start = math.max(0, hl.col_start or 0)
				local end_col = hl.end_col or hl.col_end
				if end_col == nil or end_col == -1 then
					local end_text = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1]
					end_col = end_text and #end_text or col_start
				end

				local mark_opts = {
					hl_group = hl.hl_group,
				}
				if hl.hl_eol ~= nil then
					mark_opts.hl_eol = hl.hl_eol
				end
				if hl.priority then
					mark_opts.priority = hl.priority
				end
				if end_line ~= line then
					mark_opts.end_row = end_line
					mark_opts.end_col = math.max(0, end_col)
				else
					mark_opts.end_col = math.max(col_start, end_col)
				end

				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line, col_start, mark_opts)
			end
		end
	end
end

---Shift positions in a line map when content above them changes size.
---@param line_map table { [id] = { start_line, end_line, ... } }
---@param old_end number  0-indexed end of changed region
---@param delta number    line count change (positive = grew, negative = shrunk)
function M.shift_line_map(line_map, old_end, delta)
	if delta == 0 then
		return
	end
	for _, pos in pairs(line_map) do
		if pos and pos.start_line and pos.end_line and pos.start_line > old_end then
			pos.start_line = pos.start_line + delta
			pos.end_line = pos.end_line + delta
		end
	end
end

---@param value any
---@return number|nil
local function _numeric(value)
	if type(value) ~= "number" then
		return nil
	end
	if value ~= value or value == math.huge or value == -math.huge then
		return nil
	end
	return value
end

---@param value number
---@return string
local function _format_compact_number(value)
	if value < 1000 then
		return tostring(math.floor(value + 0.5))
	end

	local units = { "", "k", "m", "b", "t" }
	local unit_idx = 1
	local scaled = value
	while scaled >= 1000 and unit_idx < #units do
		scaled = scaled / 1000
		unit_idx = unit_idx + 1
	end

	local rounded = math.floor(scaled * 10 + 0.5) / 10
	if rounded >= 1000 and unit_idx < #units then
		rounded = rounded / 1000
		unit_idx = unit_idx + 1
	end

	if rounded == math.floor(rounded) then
		return string.format("%d%s", rounded, units[unit_idx])
	end
	return string.format("%.1f%s", rounded, units[unit_idx])
end

---@param message table
---@return number|nil
local function _get_token_usage(message)
	if type(message) ~= "table" or type(message.tokens) ~= "table" then
		return nil
	end

	local tokens = message.tokens
	local total = _numeric(tokens.total)
	if total then
		return total
	end

	local sum = 0
	local has_value = false
	local fields = { "input", "output", "reasoning" }
	for _, key in ipairs(fields) do
		local value = _numeric(tokens[key])
		if value then
			sum = sum + value
			has_value = true
		end
	end

	if type(tokens.cache) == "table" then
		local cache_fields = { "read", "write" }
		for _, key in ipairs(cache_fields) do
			local value = _numeric(tokens.cache[key])
			if value then
				sum = sum + value
				has_value = true
			end
		end
	end

	if has_value then
		return sum
	end
	return nil
end

---@param message table
---@return number|nil
local function _get_token_limit(message)
	if type(message) ~= "table" then
		return nil
	end
	if type(message.providerID) ~= "string" or message.providerID == "" then
		return nil
	end
	if type(message.modelID) ~= "string" or message.modelID == "" then
		return nil
	end

	local ok, model = pcall(sync.get_model, message.providerID, message.modelID)
	if not ok or type(model) ~= "table" or type(model.limit) ~= "table" then
		return nil
	end

	local context_limit = _numeric(model.limit.context)
	if context_limit then
		return context_limit
	end
	return _numeric(model.limit.input)
end

---@param message table
---@return string
local function _get_model_name(message)
	local model_id = type(message) == "table" and message.modelID or nil
	if type(model_id) ~= "string" or model_id == "" then
		return ""
	end
	if type(message.providerID) ~= "string" or message.providerID == "" then
		return model_id
	end
	local ok, model = pcall(sync.get_model, message.providerID, model_id)
	if ok and type(model) == "table" and type(model.name) == "string" and model.name ~= "" then
		return model.name
	end
	return model_id
end

-- ─── Message metadata helpers ─────────────────────────────────────────────────

---@param message table
---@return boolean
function M.is_message_final(message)
	local finish = message.finish
	if not finish then
		return false
	end
	return finish ~= "tool-calls" and finish ~= "unknown"
end

---@param message table
---@param is_last boolean
---@return boolean
function M.should_show_footer(message, is_last)
	if
		message
		and message.modelID == nil
		and message.providerID == nil
		and message.agent == nil
		and message.mode == nil
	then
		return false
	end
	if is_last then
		return true
	end
	if M.is_message_final(message) then
		return true
	end
	if message.error and message.error.name == "MessageAbortedError" then
		return true
	end
	return false
end

---@param message table
---@return boolean
function M.is_interrupted(message)
	return message.error and message.error.name == "MessageAbortedError" or false
end

---Calculate duration for an assistant message (completed - parent_user.created).
---@param message table
---@param messages table[]
---@return number|nil duration_ms
function M.calculate_duration(message, messages)
	if not message.time or not message.time.completed then
		return nil
	end
	local parent_id = message.parentID
	if not parent_id then
		return nil
	end
	for _, msg in ipairs(messages) do
		if msg.id == parent_id and msg.role == "user" then
			if msg.time and msg.time.created then
				return message.time.completed - msg.time.created
			end
			break
		end
	end
	return nil
end

---Render metadata footer for an assistant message.
---@param message table
---@param messages table[]
---@param opts? table { spinner_frame?: string|nil }
---@return NuiLine
function M.render_metadata_footer(message, messages, opts)
	opts = opts or {}
	local agent_name = message.mode or message.agent or "unknown"
	local agent_id = message.agent or message.mode or "unknown"
	local interrupted = M.is_interrupted(message)
	local is_final = M.is_message_final(message)
	local agent_hl = interrupted and "Comment" or M.get_agent_hl(agent_id)
	local token_usage = _get_token_usage(message)
	local token_limit = _get_token_limit(message)
	local spinner_frame = (type(opts.spinner_frame) == "string" and #opts.spinner_frame > 0) and opts.spinner_frame or nil
	local agent_prefix = spinner_frame and (spinner_frame .. " ") or "▣ "

	local line = NuiLine()
	line:append(NuiText(agent_prefix, { hl_group = "Comment", priority = UI_HIGHLIGHT_PRIORITY }))
	line:append(NuiText(locale.titlecase(agent_name), { hl_group = agent_hl, priority = UI_HIGHLIGHT_PRIORITY }))
	local model_name = _get_model_name(message)
	if model_name ~= "" then
		line:append(NuiText(" · ", "Comment"))
		line:append(NuiText(model_name, "Comment"))
	end
	if token_usage and token_usage > 0 then
		line:append(NuiText(" · ", "Comment"))
		local token_text = _format_compact_number(token_usage)
		if token_limit then
			token_text = token_text .. "/" .. _format_compact_number(token_limit)
		end
		line:append(NuiText(token_text .. " tok", "Comment"))
	end
	if not interrupted and is_final then
		local duration_ms = M.calculate_duration(message, messages)
		if duration_ms then
			line:append(NuiText(" · ", "Comment"))
			line:append(NuiText(locale.duration(duration_ms), agent_hl))
		end
	end
	if interrupted then
		line:append(NuiText(" · ", "Comment"))
		line:append(NuiText("interrupted", "Comment"))
	end
	return line
end

return M
