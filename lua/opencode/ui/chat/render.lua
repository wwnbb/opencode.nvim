local cs = require("opencode.ui.chat.state")
return cs.factory("render", function(view)
-- Pure NuiLine-based rendering helpers for the chat buffer.
-- No state mutations here — functions only read state (for window width and
-- model info) or operate on their arguments.  Buffer-mutating highlight
-- application lives in ui.chat.highlights.
-- The animation frame is passed in as a parameter so this module stays free of
-- timer side-effects.

local M = {}

local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local syntax = require("opencode.ui.syntax")
local highlights = require("opencode.ui.highlights")
local text_widths = require("opencode.ui.chat.text_width")

local state = view
local PANEL_BACKGROUND_HL_PRIORITY = 4000
local UI_HIGHLIGHT_PRIORITY = 4200
local PANEL_PREFIX_HL_PRIORITY = UI_HIGHLIGHT_PRIORITY + 1

local function ensure_user_message_highlights()
	highlights.setup_message_backgrounds()
end

---@return number width
local function get_chat_text_width()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return 80
	end

	local width = vim.api.nvim_win_get_width(state.winid)
	local wininfo = vim.fn.getwininfo(state.winid)[1]
	local textoff = wininfo and tonumber(wininfo.textoff) or 0
	-- The status column supplies the left gutter; reserve the same space on the right.
	return math.max(1, width - textoff - 2)
end

-- getwininfo() is costly and widgets ask for the width (and panels the
-- tabstop) per row; one frame build reads them once.
local frame_width

---@return number width
function M.get_chat_text_width()
	return frame_width or get_chat_text_width()
end

M.sanitize_buffer_line = text_widths.sanitize_buffer_line

local frame_tabstop

---@return number
local function get_tabstop()
	if frame_tabstop then return frame_tabstop end
	local value
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		value = tonumber(vim.api.nvim_get_option_value("tabstop", { buf = state.bufnr }))
	end
	value = value or tonumber(vim.bo.tabstop) or tonumber(vim.o.tabstop) or 8
	if value <= 0 then
		return 8
	end
	return value
end

---Run build with the text width fixed for its duration.
---@generic T
---@param build fun(): T
---@return T
function M.with_frame_width(build)
	if frame_width then return build() end
	local width, tabstop = get_chat_text_width(), get_tabstop()
	frame_width, frame_tabstop = width, tabstop
	local result = { pcall(build) }
	frame_width, frame_tabstop = nil, nil
	if not result[1] then error(result[2], 0) end
	return unpack(result, 2, table.maxn(result))
end

---@return table
local function new_width_context()
	return text_widths.new_context(get_tabstop())
end

local char_display_width = text_widths.char_width
local display_width_from_col = text_widths.width_from_col

---@param text any
---@param initial_col? number
---@param width_context? table
---@return number
local function safe_display_width(text, initial_col, width_context)
	local safe_text = M.sanitize_buffer_line(text)
	return display_width_from_col(safe_text, tonumber(initial_col) or 0, width_context or new_width_context())
end

---Expand a display line before wrapping and syntax highlighting. Literal tabs
---can grow under 'linebreak' when panel padding follows them.
---@param text string
---@param initial_col? number Display column after the panel/command prefix
---@return string
function M.expand_tabs(text, initial_col)
	text = M.sanitize_buffer_line(text)
	if not text:find("\t", 1, true) then
		return text
	end
	local width_context = new_width_context()
	local col = tonumber(initial_col) or 0
	return (text:gsub("([^\t]*)\t", function(piece)
		col = col + display_width_from_col(piece, col, width_context)
		local spaces = char_display_width(width_context, "\t", col)
		col = col + spaces
		return piece .. string.rep(" ", spaces)
	end))
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
	tool_part = type(tool_part) == "table" and tool_part or {}
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local part_metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}
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

local wrap_text_with_ranges = text_widths.wrap_with_ranges

function M.wrap_text_with_ranges(text, max_width, opts)
	local result = wrap_text_with_ranges(text, max_width, opts, new_width_context())
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
---@param width number
---@param current number
---@return string
local function pad_to_width_with_current(text, width, current)
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
	local width = opts.width or result.width or get_chat_text_width()
	local width_context = new_width_context()
	local prefix_width = safe_display_width(prefix, 0, width_context)
	local body_width = math.max(1, width - prefix_width)
	local chunks, chunk_widths = wrap_text_with_ranges(text, body_width, {
		initial_col = prefix_width,
	}, width_context)
	local rows = {}

	for index, chunk in ipairs(chunks) do
		local line = prefix .. chunk.text
		line = pad_to_width_with_current(line, width, prefix_width + chunk_widths[index])
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
	local width = opts.width or result.width or get_chat_text_width()
	local width_context = new_width_context()
	local body = M.sanitize_buffer_line(text)
	local body_prefix = opts.body_prefix or ""
	local continuation_prefix = opts.continuation_prefix or body_prefix
	local body_prefix_width = math.max(
		safe_display_width(body_prefix, 0, width_context),
		safe_display_width(continuation_prefix, 0, width_context)
	)
	local prefix_width = safe_display_width(prefix, 0, width_context)
	local body_width = math.max(1, width - prefix_width - body_prefix_width)
	local chunks, chunk_widths
	if opts.wrap ~= false then
		chunks, chunk_widths = wrap_text_with_ranges(body, body_width, {
			initial_col = prefix_width + body_prefix_width,
		}, width_context)
	else
		chunks = {
			{
				text = body,
				byte_start = 0,
				byte_end = #body,
			},
		}
	end
	local first_prefix_width = safe_display_width(prefix .. body_prefix, 0, width_context)
	local continuation_prefix_width = safe_display_width(prefix .. continuation_prefix, 0, width_context)
	local rows = {}

	for index, chunk in ipairs(chunks) do
		local row_body_prefix = index == 1 and body_prefix or continuation_prefix
		local row_prefix = prefix .. row_body_prefix
		local row_prefix_width = index == 1 and first_prefix_width or continuation_prefix_width
		local current
		if opts.wrap ~= false and (row_prefix_width == prefix_width + body_prefix_width or not chunk.text:find("\t", 1, true)) then
			current = row_prefix_width + chunk_widths[index]
		else
			current = safe_display_width(row_prefix .. chunk.text, 0, width_context)
		end
		local line = pad_to_width_with_current(row_prefix .. chunk.text, width, current)
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
	local width = opts.width or result.width or get_chat_text_width()
	local width_context = new_width_context()
	local prefix_width = safe_display_width(prefix, 0, width_context)
	local line = pad_to_width_with_current(prefix, width, prefix_width)
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

-- ─── NuiLine renderers ────────────────────────────────────────────────────────

---Render a user message using NuiLine.
---@param content string|nil
---@param agent_name string|nil
---@param files? table[]
---@param opts? { max_lines?: number, highlight_code?: OpenCodeCodeHighlighter }
---@return OpenCodeRenderedLines
function M.render_user_message(content, agent_name, files, opts)
	opts = opts or {}
	ensure_user_message_highlights()

	local lines = {}
	local text_width = get_chat_text_width()
	local content_width = math.max(1, text_width - 3) -- User box border and inner spacing.
	local body = M.render_content(content, {
		width = content_width,
		scope = "user_markdown",
		highlight_code = opts.highlight_code,
	})
	-- Shorten rendered rows, so hidden fences cannot break Markdown parsing.
	local body_lines = M.extract_lines(body)
	local content_lines, body_indices, row_map = {}, {}, {}
	for index, text in ipairs(body_lines) do
		content_lines[index], body_indices[index] = text, index
	end
	local max_lines = tonumber(opts.max_lines) or 0
	if max_lines > 0 and #content_lines > max_lines then
		local visible_budget = math.max(1, max_lines - 1)
		local head_lines = math.max(1, math.floor(visible_budget * 0.75))
		local tail_lines = math.max(0, visible_budget - head_lines)
		local compacted, indices = {}, {}
		for i = 1, head_lines do
			indices[#compacted + 1] = i
			compacted[#compacted + 1] = content_lines[i] or ""
		end
		local hidden_content_lines = #content_lines - head_lines - tail_lines
		indices[#compacted + 1] = false
		compacted[#compacted + 1] = "... (" .. tostring(hidden_content_lines) .. " lines hidden)"
		for i = #content_lines - tail_lines + 1, #content_lines do
			if i > head_lines then
				indices[#compacted + 1] = i
				compacted[#compacted + 1] = content_lines[i] or ""
			end
		end
		content_lines, body_indices = compacted, indices
	end
	local border_hl = M.get_agent_hl(agent_name or "unknown")

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

	for index, text in ipairs(content_lines) do
		if body_indices[index] then
			row_map[body_indices[index]] = { {
				line_index = #lines, byte_start = 0, byte_end = #text, prefix = "┃  ",
			} }
			add_block_line("  " .. text)
		else
			for _, line in ipairs(M.wrap_text(text, content_width)) do add_block_line("  " .. line) end
		end
	end
	lines._opencode_highlights = syntax.project_highlights(body._opencode_highlights, body_lines, row_map)
	lines._opencode_syntax_retry = body._opencode_syntax_retry

	for _, file in ipairs(files or {}) do
		local mime = file.mime or "file"
		local label = (file.type == "skill" or file.type == "agent") and file.type
			or (mime:match("^image/") and "img" or (mime == "application/pdf" and "pdf" or "file"))
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

---Render chat Markdown using the reference TUI's block layout.
---@param content string|nil
---@param opts? OpenCodeMarkdownRenderOpts
---@return OpenCodeRenderedLines
function M.render_content(content, opts)
	return require("opencode.ui.markdown").render(content, opts, M)
end

---Render a tool no widget knows (MCP and custom tools) as a compact row:
---" ▸ <Name> · <description>[ · <Status>][ <spinner>]", its error as sub-lines
---when folded, and input, output and error in the shared frame when opened.
---@param tool_part table
---@param is_expanded boolean
---@return table { lines: string[], highlights: table[] }
function M.render_tool_line(tool_part, is_expanded)
	local style = cs.module(view, require("opencode.ui.chat.tool_style"))
	local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
	local text = require("opencode.util.text")
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local status = tool_state.status or "pending"
	local input, output, err = tool_state.input, tool_state.output, tool_state.error
	local working = status == "pending" or status == "running"
	local failed = status == "error" or (text.is_present(err) and err ~= false)
	local cancelled = status == "cancelled" or status == "canceled" or status == "interrupted" or status == "aborted"
	local function present(value)
		return text.is_present(value) and not (type(value) == "table" and next(value) == nil)
	end
	local foldable = present(input) or present(output) or failed

	local header = (foldable and tool_panel.fold_prefix(is_expanded) or "")
		.. require("opencode.util.tool_names").display_name(tool_part.tool or "unknown")
	if type(input) == "table" and text.is_present(input.description) then
		header = header .. " · " .. M.sanitize_buffer_line(tostring(input.description))
	end
	local status_word = failed and "Failed" or cancelled and "Cancelled"
		or status == "pending" and "Pending" or status == "running" and "Running" or nil
	if status_word then header = header .. " · " .. status_word end
	local elapsed = not working and tool_panel.duration(tool_state.time) or nil
	if elapsed then header = header .. " · " .. elapsed end
	if working and not failed then header = header .. " " .. tool_panel.anim_frame() end

	local result = { lines = {}, highlights = {} }
	M.add_panel_line(result, header, failed and style.error_hl or style.header_hl, { prefix = " " })
	local error_text = failed and (type(err) == "string" and err or json_or_inspect(err)) or ""
	if not is_expanded then
		if failed then style.add_error_lines(result, error_text) end
		result.lines[#result.lines + 1] = ""
		return result
	end

	local panel = style.panel
	local function section(label, value, language, hl)
		if not present(value) then return end
		if #result.lines > 2 then panel.add_blank(result) end
		panel.add_line(result, label, style.border_hl)
		local body = text.normalize_text(value, function(v) return type(v) == "string" and v or json_or_inspect(v) end)
		tool_panel.add_raw_body(result, body, {
			panel = panel, prefix = style.prefix, hl_group = hl,
			language = hl == nil and (type(value) == "table" and "json"
				or syntax.detect_output_language(body, M.get_tool_metadata(tool_part))) or nil,
		})
	end
	style.add_border(result)
	section("Input", input)
	section("Output", output)
	if failed then section("Error", error_text, nil, style.body_error_hl) end
	style.add_border(result, true)
	style.contain_background(result)
	result.lines[#result.lines + 1] = ""
	return result
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

-- Message footer and token breakdown, installed on this render instance.
require("opencode.ui.chat.message_footer").attach(M, { ui_priority = UI_HIGHLIGHT_PRIORITY })

return M

end)
