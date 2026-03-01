-- Pure NuiLine-based rendering helpers for the chat buffer.
-- No state mutations here — functions only read state (for window width) or
-- operate on their arguments.  The animation frame is passed in as a parameter
-- so this module stays free of timer side-effects.

local M = {}

local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local markdown = require("opencode.ui.markdown")
local thinking = require("opencode.ui.thinking")
local locale = require("opencode.util.locale")

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

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

-- ─── Text wrapping ────────────────────────────────────────────────────────────

---Wrap a string to fit within max_width, breaking at word boundaries.
---@param text string
---@param max_width number
---@return string[]
function M.wrap_text(text, max_width)
	if max_width <= 0 then
		return { text }
	end
	if vim.fn.strdisplaywidth(text) <= max_width then
		return { text }
	end

	local result = {}
	local remaining = text
	while vim.fn.strdisplaywidth(remaining) > max_width do
		local last_space_byte = nil
		local byte_pos = 0
		local col = 0
		while byte_pos < #remaining do
			local char_len = vim.fn.byteidx(remaining:sub(byte_pos + 1), 1)
			if char_len <= 0 then
				char_len = 1
			end
			local ch = remaining:sub(byte_pos + 1, byte_pos + char_len)
			local char_width = vim.fn.strdisplaywidth(ch)
			if col + char_width > max_width then
				break
			end
			col = col + char_width
			byte_pos = byte_pos + char_len
			if ch == " " then
				last_space_byte = byte_pos
			end
		end
		local cut = (last_space_byte and last_space_byte > 0) and last_space_byte or byte_pos
		table.insert(result, remaining:sub(1, cut))
		remaining = remaining:sub(cut + 1)
		if remaining:sub(1, 1) == " " then
			remaining = remaining:sub(2)
		end
	end
	if #remaining > 0 then
		table.insert(result, remaining)
	end
	return result
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
---@return NuiLine[]
function M.render_user_message(content, agent_name)
	local lines = {}
	local content_lines = vim.split(content or "", "\n", { plain = true })
	local prefix_hl = M.get_agent_hl(agent_name or "unknown")
	local prompt, multiline_prefix = M.get_user_message_display()

	local win_width = 80
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		win_width = vim.api.nvim_win_get_width(state.winid)
	end
	local prompt_width = vim.fn.strdisplaywidth(prompt)
	local first_line_width = math.max(1, win_width - prompt_width)
	local continuation_width = math.max(1, win_width)

	table.insert(lines, NuiLine())

	local first_output_line = true
	for _, text in ipairs(content_lines) do
		local wrapped
		if multiline_prefix then
			wrapped = M.wrap_text(text, first_line_width)
		else
			local initial = first_output_line and first_line_width or continuation_width
			wrapped = M.wrap_text(text, initial)
		end
		for _, wline in ipairs(wrapped) do
			local line = NuiLine()
			local should_prefix = multiline_prefix or first_output_line
			if should_prefix then
				line:append(NuiText(prompt, prefix_hl))
			end
			line:append(wline)
			table.insert(lines, line)
			first_output_line = false
		end
	end

	table.insert(lines, NuiLine())
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

---Render content (markdown or plain) using NuiLine.
---@param content string|nil
---@param opts? table { stream_plain?: boolean }
---@return NuiLine[]
function M.render_content(content, opts)
	opts = opts or {}
	local lines = {}
	if not content or content == "" then
		return lines
	end

	local use_markdown = not opts.stream_plain and markdown.has_markdown(content)

	if use_markdown then
		local parsed = markdown.parse(content)
		local md_lines, _ = markdown.render_to_lines(parsed)
		for _, text in ipairs(md_lines) do
			local line = NuiLine()
			line:append(text)
			table.insert(lines, line)
		end
	else
		local content_lines = vim.split(content, "\n", { plain = true })
		for _, text in ipairs(content_lines) do
			local line = NuiLine()
			line:append(text)
			table.insert(lines, line)
		end
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
			local input_str = type(tool_input) == "string" and tool_input or vim.json.encode(tool_input)
			add_hl_line("  Input: ", "Special")
			for _, iline in ipairs(vim.split(input_str, "\n", { plain = true })) do
				add_hl_line("    " .. iline, "Comment")
			end
		end

		if tool_output then
			local output_str = type(tool_output) == "string" and tool_output or vim.inspect(tool_output)
			add_hl_line("  Output: ", "Special")
			for _, oline in ipairs(vim.split(output_str, "\n", { plain = true })) do
				add_hl_line("    " .. oline, "Comment")
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
		table.insert(lines, nui_line:content())
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
	if message and message.modelID == nil and message.providerID == nil and message.agent == nil and message.mode == nil then
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
---@return NuiLine
function M.render_metadata_footer(message, messages)
	local agent_name = message.mode or message.agent or "unknown"
	local agent_id = message.agent or message.mode or "unknown"
	local interrupted = M.is_interrupted(message)
	local agent_hl = interrupted and "Comment" or M.get_agent_hl(agent_id)

	local line = NuiLine()
	line:append(NuiText("▣ " .. locale.titlecase(agent_name), agent_hl))
	local model_id = message.modelID or ""
	if model_id ~= "" then
		line:append(NuiText(" · ", "Comment"))
		line:append(NuiText(model_id, "Comment"))
	end
	if not interrupted and M.is_message_final(message) then
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
