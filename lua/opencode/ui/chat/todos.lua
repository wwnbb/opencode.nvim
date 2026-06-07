-- Todo list rendering and live dock helpers for the chat buffer.
-- Mirrors OpenCode TUI's todowrite -> session todo state -> renderer flow.

local M = {}

local render = require("opencode.ui.chat.render")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local panel = require("opencode.ui.panel")
local text_util = require("opencode.util.text")
local perf = require("opencode.perf")
local todo_hl_ns = vim.api.nvim_create_namespace("opencode_todo_hl")
local PANEL_PREFIX_HL_PRIORITY = 4201
local MAX_COLLAPSED_OUTPUT_LINES = 10
local PANEL_PREFIX = "▏  "
local PANEL_BLANK_PREFIX = "▏"
local PANEL_BORDER_HL = "OpenCodeTodoMuted"
local TODO_ANIM_FRAMES = { "|", "/", "-", "\\" }
local TODO_READ_TOOLS = { todoread = true, todolist = true }
local TODO_WRITE_TOOLS = { todowrite = true }

local panel_helpers = panel.create_helpers({
	prefix = PANEL_PREFIX,
	blank_prefix = PANEL_BLANK_PREFIX,
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeTodoOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank

local STATUS_HIGHLIGHTS = {
	pending = "OpenCodeTodoPending",
	in_progress = "OpenCodeTodoProgress",
	completed = "OpenCodeTodoCompleted",
	cancelled = "OpenCodeTodoCancelled",
}

local DOCK_HIGHLIGHTS = {
	OpenCodeTodoMuted = "OpenCodeTodoDockMuted",
	OpenCodeTodoHeader = "OpenCodeTodoDockHeader",
	OpenCodeTodoPending = "OpenCodeTodoDockPending",
	OpenCodeTodoProgress = "OpenCodeTodoDockProgress",
	OpenCodeTodoCompleted = "OpenCodeTodoDockCompleted",
	OpenCodeTodoCancelled = "OpenCodeTodoDockCancelled",
	OpenCodeTodoPriority = "OpenCodeTodoDockPriority",
	OpenCodeTodoOutput = "OpenCodeTodoDockOutput",
	OpenCodeTodoError = "OpenCodeTodoDockError",
}

local PRIORITY_MARKERS = {
	high = "!",
	medium = "•",
	low = "·",
}

---@class OpenCodeTodoConfig
---@field enabled boolean
---@field show_dock boolean
---@field hide_when_done boolean
---@field default_collapsed boolean
---@field keymaps table
---@field icons table<string, string>
---@field highlights table<string, string>

local DEFAULT_CONFIG = {
	enabled = true,
	show_dock = true,
	hide_when_done = true,
	default_collapsed = false,
	keymaps = {
		toggle = "T",
	},
	icons = {
		pending = "[ ]",
		in_progress = "[•]",
		completed = "[✓]",
		cancelled = "[ ]",
	},
	highlights = {
		pending = "Comment",
		in_progress = "WarningMsg",
		completed = "DiagnosticOk",
		cancelled = "Comment",
		header = "Title",
		border = "Comment",
	},
}

local VALID_STATUS = {
	pending = true,
	in_progress = true,
	completed = true,
	cancelled = true,
}

---@param tool_name string|nil
---@return boolean
function M.is_todo_read_tool(tool_name)
	return TODO_READ_TOOLS[tool_name] == true
end

---@param tool_name string|nil
---@return boolean
function M.is_todo_write_tool(tool_name)
	return TODO_WRITE_TOOLS[tool_name] == true
end

---@param tool_name string|nil
---@return boolean
function M.is_todo_tool(tool_name)
	return M.is_todo_read_tool(tool_name) or M.is_todo_write_tool(tool_name)
end

---@return OpenCodeTodoConfig
function M.get_config()
	local ok, app_state = pcall(require, "opencode.state")
	local full_config = ok and app_state.get_config() or {}
	local todo_config = full_config.chat and full_config.chat.todo or {}
	return vim.tbl_deep_extend("force", {}, DEFAULT_CONFIG, todo_config or {})
end

---@param name string
---@param fg_source string
---@param fallback string|nil
---@param extra_opts? table
local function set_dock_hl(name, fg_source, fallback, extra_opts)
	local fg_hl = panel.get_hl(fg_source)
	local fallback_hl = fallback and panel.get_hl(fallback) or {}
	local opts = {}
	if fg_hl.fg or fallback_hl.fg then
		opts.fg = fg_hl.fg or fallback_hl.fg
	end
	if extra_opts then
		opts = vim.tbl_extend("force", opts, extra_opts)
	end
	vim.api.nvim_set_hl(0, name, opts)
end

---@param cfg OpenCodeTodoConfig|nil
local function ensure_highlights(cfg)
	cfg = cfg or M.get_config()
	local highlights = cfg.highlights or {}
	panel_helpers.set_hl("OpenCodeTodoMuted", highlights.border or "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeTodoHeader", highlights.header or "Title", "Normal", { bold = true })
	panel_helpers.set_hl("OpenCodeTodoPending", highlights.pending or "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeTodoProgress", highlights.in_progress or "WarningMsg", "WarningMsg")
	panel_helpers.set_hl("OpenCodeTodoCompleted", highlights.completed or "DiagnosticOk", "DiagnosticOk")
	panel_helpers.set_hl("OpenCodeTodoCancelled", highlights.cancelled or "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeTodoPriority", "Special", "Normal")
	panel_helpers.set_hl("OpenCodeTodoOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeTodoError", "DiagnosticError", "ErrorMsg")

	set_dock_hl("OpenCodeTodoDockMuted", highlights.border or "Comment", "Normal")
	set_dock_hl("OpenCodeTodoDockHeader", highlights.header or "Title", "Normal", { bold = true })
	set_dock_hl("OpenCodeTodoDockPending", highlights.pending or "Comment", "Normal")
	set_dock_hl("OpenCodeTodoDockProgress", highlights.in_progress or "WarningMsg", "WarningMsg")
	set_dock_hl("OpenCodeTodoDockCompleted", highlights.completed or "DiagnosticOk", "DiagnosticOk")
	set_dock_hl("OpenCodeTodoDockCancelled", highlights.cancelled or "Comment", "Normal")
	set_dock_hl("OpenCodeTodoDockPriority", "Special", "Normal")
	set_dock_hl("OpenCodeTodoDockOutput", "Normal", nil)
	set_dock_hl("OpenCodeTodoDockError", "DiagnosticError", "ErrorMsg")
end

---@param cfg OpenCodeTodoConfig|nil
---@return boolean
function M.is_enabled(cfg)
	cfg = cfg or M.get_config()
	return cfg.enabled ~= false
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
local function first_nonempty_trimmed_text(...)
	return text_util.first_nonempty_trimmed_text(stringify, ...)
end

---@param text any
---@return string
local function normalize_content(text)
	return vim.trim(normalize_text(text):gsub("\n+", " "))
end

---@param status any
---@return string
local function normalize_status(status)
	if type(status) ~= "string" or not VALID_STATUS[status] then
		return "pending"
	end
	return status
end

---@param priority any
---@return string|nil
local function normalize_priority(priority)
	if priority == "high" or priority == "medium" or priority == "low" then
		return priority
	end
	return nil
end

---@param tool_part table
---@return table|string
local function get_input(tool_part)
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local state_input = tool_state.input
	local part_input = tool_part.input
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

---@param todos any
---@return OpenCodeTodo[]
function M.normalize_todos(todos)
	if type(todos) ~= "table" then
		return {}
	end

	local normalized = {}
	for _, todo in ipairs(todos) do
		if type(todo) == "table" then
			local content = normalize_content(todo.content)
			if content ~= "" then
				table.insert(normalized, {
					content = content,
					status = normalize_status(todo.status),
					priority = normalize_priority(todo.priority),
				})
			end
		end
	end
	return normalized
end

---@param tool_part table
---@return OpenCodeTodo[]
function M.extract_tool_todos(tool_part)
	if type(tool_part) ~= "table" then
		return {}
	end

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local input = get_input(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	local output = type(tool_state.output) == "table" and tool_state.output or {}

	local function first_nonempty(...)
		for i = 1, select("#", ...) do
			local value = select(i, ...)
			local normalized = M.normalize_todos(value)
			if #normalized > 0 then
				return normalized
			end
			if type(value) == "table" then
				normalized = M.normalize_todos(value.todos or value.todo)
				if #normalized > 0 then
					return normalized
				end
			end
		end
		return nil
	end

	local normalized = first_nonempty(input)
	if normalized then
		return normalized
	end
	normalized = first_nonempty(metadata, output, tool_part.todos)
	if normalized then
		return normalized
	end
	return {}
end

---@param status string
---@return boolean
function M.is_terminal(status)
	return status == "completed" or status == "cancelled"
end

---@param todos OpenCodeTodo[]
---@return table counts
local function count_by_status(todos)
	local counts = {
		pending = 0,
		in_progress = 0,
		completed = 0,
		cancelled = 0,
	}
	for _, todo in ipairs(todos) do
		if counts[todo.status] ~= nil then
			counts[todo.status] = counts[todo.status] + 1
		end
	end
	return counts
end

---@param todos OpenCodeTodo[]
---@return string summary
local function format_summary(todos)
	if #todos == 0 then
		return ""
	end
	local counts = count_by_status(todos)
	local parts = { string.format("%d/%d done", counts.completed, #todos) }
	if counts.in_progress > 0 then
		table.insert(parts, tostring(counts.in_progress) .. " active")
	end
	if counts.pending > 0 then
		table.insert(parts, tostring(counts.pending) .. " pending")
	end
	if counts.cancelled > 0 then
		table.insert(parts, tostring(counts.cancelled) .. " cancelled")
	end
	return table.concat(parts, " · ")
end

---@param todos OpenCodeTodo[]
---@return boolean
local function has_in_progress(todos)
	for _, todo in ipairs(todos) do
		if todo.status == "in_progress" then
			return true
		end
	end
	return false
end

---@param todos OpenCodeTodo[]
---@return OpenCodeTodo|nil
local function active_preview_todo(todos)
	for _, todo in ipairs(todos) do
		if todo.status == "in_progress" then
			return todo
		end
	end
	for _, todo in ipairs(todos) do
		if not M.is_terminal(todo.status) then
			return todo
		end
	end
	return todos[1]
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

---@param result table
---@param text string
---@param hl_group string|nil
local function add_line(result, text, hl_group)
	table.insert(result.lines, text)
	if hl_group then
		table.insert(result.highlights, {
			line = #result.lines - 1,
			col_start = 0,
			col_end = -1,
			hl_group = hl_group,
		})
	end
end

---@param result table
---@param text string
---@param hl_group string|nil
---@param prefix string
---@param prefix_hl_group string|nil
local function add_prefixed_line(result, text, hl_group, prefix, prefix_hl_group)
	add_line(result, text, hl_group)
	if not prefix_hl_group or prefix == "" then
		return
	end
	table.insert(result.highlights, {
		line = #result.lines - 1,
		col_start = 0,
		col_end = #prefix,
		hl_group = prefix_hl_group,
		priority = PANEL_PREFIX_HL_PRIORITY,
	})
end

---@param hl_group string
---@return string
local function dock_highlight_group(hl_group)
	return DOCK_HIGHLIGHTS[hl_group] or hl_group
end

---@param cfg OpenCodeTodoConfig
---@param status string
---@return string
local function status_icon(cfg, status)
	return (cfg.icons and cfg.icons[status]) or DEFAULT_CONFIG.icons[status] or DEFAULT_CONFIG.icons.pending
end

---@param _cfg OpenCodeTodoConfig
---@param status string
---@return string
local function status_highlight(_cfg, status)
	return STATUS_HIGHLIGHTS[status] or STATUS_HIGHLIGHTS.pending
end

---@return string
local function get_anim_frame()
	return TODO_ANIM_FRAMES[state.task_anim_frame] or TODO_ANIM_FRAMES[1]
end

---@param priority string|nil
---@return string
local function priority_marker(priority)
	return priority and PRIORITY_MARKERS[priority] or ""
end

---@param result table
---@param todo OpenCodeTodo
---@param cfg OpenCodeTodoConfig
---@param width number|nil
local function add_panel_todo_item(result, todo, cfg, width)
	width = width or get_chat_text_width()
	local icon = status_icon(cfg, todo.status)
	local priority = priority_marker(todo.priority)
	local first_prefix = priority ~= "" and (icon .. " " .. priority .. " ") or (icon .. " ")
	local continuation_prefix = string.rep(" ", vim.fn.strdisplaywidth(first_prefix))
	local available = math.max(
		8,
		width - vim.fn.strdisplaywidth(PANEL_PREFIX) - vim.fn.strdisplaywidth(first_prefix)
	)
	local wrapped = render.wrap_text(todo.content, available, {
		initial_col = vim.fn.strdisplaywidth(PANEL_PREFIX .. first_prefix),
	})
	if #wrapped == 0 then
		wrapped = { "" }
	end

	local hl_group = status_highlight(cfg, todo.status)
	for idx, text in ipairs(wrapped) do
		local line_prefix = idx == 1 and first_prefix or continuation_prefix
		local _, _, rows = add_panel_raw_line(result, line_prefix .. text, hl_group, {
			width = width,
			wrap = false,
		})
		if idx == 1 and priority ~= "" then
			panel_helpers.highlight_text(result, rows, priority, "OpenCodeTodoPriority")
		end
	end
end

---@param result table
---@param todo OpenCodeTodo
---@param cfg OpenCodeTodoConfig
---@param opts table|nil
local function add_todo_item(result, todo, cfg, opts)
	opts = opts or {}

	local prefix = opts.prefix or ""
	local prefix_hl_group = opts.prefix_hl_group
	local width = opts.width or get_chat_text_width()
	local icon = status_icon(cfg, todo.status)
	local first_prefix = prefix .. icon .. " "
	local continuation_prefix = prefix .. string.rep(" ", vim.fn.strdisplaywidth(icon) + 1)
	local available = math.max(8, width - vim.fn.strdisplaywidth(first_prefix))
	local wrapped = render.wrap_text(todo.content, available)
	if #wrapped == 0 then
		wrapped = { "" }
	end

	local hl_group = status_highlight(cfg, todo.status)
	for idx, text in ipairs(wrapped) do
		local line_prefix = idx == 1 and first_prefix or continuation_prefix
		add_prefixed_line(result, line_prefix .. text, hl_group, prefix, prefix_hl_group)
	end
end

---@param todos OpenCodeTodo[]
---@param cfg OpenCodeTodoConfig|nil
---@return boolean
function M.should_show_dock(todos, cfg)
	cfg = cfg or M.get_config()
	if not M.is_enabled(cfg) or cfg.show_dock == false or #todos == 0 then
		return false
	end
	if cfg.hide_when_done == false then
		return true
	end
	for _, todo in ipairs(todos) do
		if not M.is_terminal(todo.status) then
			return true
		end
	end
	return false
end

---@param session_id string
---@param todos OpenCodeTodo[]
---@param cfg OpenCodeTodoConfig|nil
---@return boolean
function M.is_dock_collapsed(session_id, todos, cfg)
	local explicit = state.todo_dock_collapsed[session_id]
	if explicit ~= nil then
		return explicit == true
	end

	cfg = cfg or M.get_config()
	if #todos <= 2 or has_in_progress(todos) then
		return false
	end
	return cfg.default_collapsed == true
end

---@param todos OpenCodeTodo[]
---@param opts? table Render options
---@return table result
function M.render_block(todos, opts)
	opts = opts or {}
	local cfg = M.get_config()
	ensure_highlights(cfg)
	local normalized = M.normalize_todos(todos)
	local result = { lines = {}, highlights = {} }
	if not M.is_enabled(cfg) then
		return result
	end

	local width = opts.width or get_chat_text_width()
	local title = opts.title or "# Todos"
	local status = opts.status or "completed"
	local working = status == "pending" or status == "running"
	local error_body = opts.error or ""
	local has_error = status == "error" or error_body ~= ""
	local expanded = opts.expanded == true
	local has_overflow = #normalized > MAX_COLLAPSED_OUTPUT_LINES
	local summary = format_summary(normalized)

	local header = title
	if working then
		header = "~ " .. (opts.pending_label or "Updating todos...") .. " " .. get_anim_frame()
	elseif has_error then
		header = "# Todo update failed"
	end
	if summary ~= "" then
		header = header .. " " .. summary
	end
	if (has_overflow or expanded) and not working then
		header = (expanded and "▾ " or "▸ ") .. header
	end

	local header_hl = "OpenCodeTodoHeader"
	if has_error then
		header_hl = "OpenCodeTodoError"
	elseif working then
		header_hl = "OpenCodeTodoProgress"
	end

	add_panel_blank(result)
	add_panel_line(result, header, header_hl)

	if error_body ~= "" then
		add_panel_blank(result)
		add_panel_line(result, error_body, "OpenCodeTodoError")
	end

	if #normalized == 0 then
		if not working and error_body == "" then
			add_panel_blank(result)
			add_panel_line(result, "No todos", "OpenCodeTodoMuted")
		end
		add_panel_blank(result)
		return result
	end

	add_panel_blank(result)

	local limit = expanded and #normalized or math.min(MAX_COLLAPSED_OUTPUT_LINES, #normalized)
	for idx = 1, limit do
		add_panel_todo_item(result, normalized[idx], cfg, width)
	end

	if not expanded and has_overflow then
		local remaining = #normalized - MAX_COLLAPSED_OUTPUT_LINES
		local suffix = remaining == 1 and "todo" or "todos"
		add_panel_line(
			result,
			"… (" .. tostring(remaining) .. " more " .. suffix .. ", press O to expand)",
			"OpenCodeTodoMuted"
		)
	end

	add_panel_blank(result)

	return result
end

---@param session_id string
---@param todos any
---@param opts? table { width?: number }
---@return table|nil result
function M.render_dock(session_id, todos, opts)
	opts = opts or {}
	local cfg = M.get_config()
	ensure_highlights(cfg)
	local normalized = M.normalize_todos(todos)
	if not session_id or not M.should_show_dock(normalized, cfg) then
		return nil
	end

	local collapsed = M.is_dock_collapsed(session_id, normalized, cfg)
	local result = { lines = {}, highlights = {}, collapsed = collapsed }
	local summary = format_summary(normalized)
	local header_hl = "OpenCodeTodoHeader"
	local header = collapsed and ("▶ Todos " .. summary) or ("▼ Todos " .. summary)
	add_line(result, header, header_hl)

	if collapsed then
		local preview = active_preview_todo(normalized)
		if preview then
			add_todo_item(result, preview, cfg, { width = opts.width or get_chat_text_width() })
		end
		add_line(result, "", "OpenCodeTodoOutput")
		return result
	end

	for _, todo in ipairs(normalized) do
		add_todo_item(result, todo, cfg, { width = opts.width or get_chat_text_width() })
	end
	add_line(result, "", "OpenCodeTodoOutput")
	return result
end

---@param tool_part table
---@param is_expanded boolean
---@return table|nil result
function M.render_tool(tool_part, is_expanded)
	local done = perf.start("chat.todos.render_tool")
	local cfg = M.get_config()
	if not M.is_enabled(cfg) or type(tool_part) ~= "table" then
		done({ skipped = true })
		return nil
	end

	local tool_name = tool_part.tool
	if not M.is_todo_tool(tool_name) then
		done({ tool = tool_name, skipped = true })
		return nil
	end

	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local metadata = render.get_tool_metadata(tool_part)
	local tool_status = tool_state.status or "pending"
	local is_read = M.is_todo_read_tool(tool_name)
	local pending_label = is_read and "Reading todos..." or "Updating todos..."
	local title = is_read and "# Read todos" or "# Updated todos"
	local error_body = first_nonempty_trimmed_text(tool_state.error, metadata.error, tool_part.error)
	local todos = M.extract_tool_todos(tool_part)
	local result = M.render_block(todos, {
		title = title,
		status = tool_status,
		pending_label = pending_label,
		error = error_body,
		expanded = is_expanded == true,
	})
	if #result.lines > 0 then
		table.insert(result.lines, "")
	end
	done({
		tool = tool_name,
		status = tool_status,
		todos = #todos,
		expanded = is_expanded == true,
		lines = #(result.lines or {}),
		highlights = #(result.highlights or {}),
	})
	return result
end

---@return boolean
local function todo_window_is_valid()
	return state.todo_winid and vim.api.nvim_win_is_valid(state.todo_winid) or false
end

---@return boolean
local function todo_buffer_is_valid()
	return state.todo_bufnr and vim.api.nvim_buf_is_valid(state.todo_bufnr) or false
end

local function setup_todo_buffer()
	if todo_buffer_is_valid() then
		return state.todo_bufnr
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	state.todo_bufnr = bufnr
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode_todo"
	vim.bo[bufnr].modifiable = false

	local opts = { buffer = bufnr, noremap = true, silent = true }
	local cfg = M.get_config()
	local toggle_key = cfg.keymaps and cfg.keymaps.toggle or "T"
	vim.keymap.set("n", "<CR>", function()
		M.toggle_current_dock()
	end, opts)
	if toggle_key and toggle_key ~= "" then
		vim.keymap.set("n", toggle_key, function()
			M.toggle_current_dock()
		end, opts)
	end
	vim.keymap.set("n", "q", function()
		M.close_window()
	end, opts)

	return bufnr
end

local function setup_todo_window_options(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end

	local wo = vim.wo[winid]
	wo.fillchars = "eob: "
	wo.wrap = true
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.cursorline = false
	wo.cursorcolumn = false
	pcall(function()
		wo.statuscolumn = ""
	end)
end

---@return table|nil frame
local function get_chat_frame()
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil
	end

	if state.config and state.config.layout == "float" and state.float_dims then
		return vim.deepcopy(state.float_dims)
	end

	local pos = vim.api.nvim_win_get_position(state.winid)
	return {
		row = pos[1],
		col = pos[2],
		width = vim.api.nvim_win_get_width(state.winid),
		height = vim.api.nvim_win_get_height(state.winid),
	}
end

---@param value number
---@param min_value number
---@param max_value number
---@return number
local function clamp(value, min_value, max_value)
	return math.max(min_value, math.min(value, max_value))
end

---@param frame table
---@param line_count number
---@return table|nil
local function calculate_window_config(frame, line_count)
	local cfg = state.config or {}
	local layout = cfg.layout or "vertical"
	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }

	local max_width = math.max(20, frame.width - 4)
	local width
	if layout == "vertical" then
		width = max_width
	else
		width = math.min(max_width, math.max(24, math.floor(frame.width * 0.38)))
	end

	width = clamp(width, 20, math.max(20, ui.width - 4))

	local max_height = math.max(1, frame.height - 4)
	if layout == "vertical" then
		max_height = math.max(1, math.min(max_height, 10))
	elseif layout == "horizontal" then
		max_height = math.max(1, math.min(max_height, frame.height - 2))
	else
		max_height = math.max(1, math.min(max_height, 12))
	end
	local height = clamp(line_count, 1, max_height)

	local row = frame.row + 1
	local col = frame.col + 1
	if layout == "horizontal" or layout == "float" then
		col = frame.col + frame.width - width - 2
	end

	row = clamp(row, 0, math.max(0, ui.height - height - 2))
	col = clamp(col, 0, math.max(0, ui.width - width - 2))

	return {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "single",
		focusable = true,
		zindex = 70,
	}
end

function M.close_window()
	if todo_window_is_valid() then
		pcall(vim.api.nvim_win_close, state.todo_winid, true)
	end
	state.todo_winid = nil
end

function M.update_window()
	local done = perf.start("chat.todos.update_window")
	local app_state = require("opencode.state")
	local sync = require("opencode.sync")
	local current = app_state.get_session()
	local session_id = current and current.id
	local frame = get_chat_frame()
	if not frame or not session_id then
		M.close_window()
		done({ skipped = true, reason = "no_frame_or_session" })
		return
	end

	local cfg = M.get_config()
	local todos = M.normalize_todos(sync.get_todos(session_id))
	if not M.should_show_dock(todos, cfg) then
		M.close_window()
		done({ session_id = session_id, todos = #todos, skipped = true, reason = "hidden" })
		return
	end

	local preliminary = calculate_window_config(frame, #todos + 1)
	if not preliminary then
		M.close_window()
		done({ session_id = session_id, todos = #todos, skipped = true, reason = "no_preliminary_config" })
		return
	end

	local result = M.render_dock(session_id, todos, { width = preliminary.width })
	if not result or #result.lines == 0 then
		M.close_window()
		done({ session_id = session_id, todos = #todos, skipped = true, reason = "empty_render" })
		return
	end

	local win_config = calculate_window_config(frame, #result.lines)
	if not win_config then
		M.close_window()
		done({ session_id = session_id, todos = #todos, lines = #result.lines, skipped = true, reason = "no_window_config" })
		return
	end

	local bufnr = setup_todo_buffer()
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result.lines)
	vim.api.nvim_buf_clear_namespace(bufnr, todo_hl_ns, 0, -1)
	for _, hl in ipairs(result.highlights or {}) do
		local line_idx = hl.line
		if line_idx >= 0 and line_idx < #result.lines then
			local end_col = hl.col_end
			if end_col == -1 then
				end_col = #result.lines[line_idx + 1]
			end
			local mark_opts = {
				end_col = end_col,
				hl_group = dock_highlight_group(hl.hl_group),
			}
			if hl.priority then
				mark_opts.priority = hl.priority
			end
			pcall(vim.api.nvim_buf_set_extmark, bufnr, todo_hl_ns, line_idx, hl.col_start, mark_opts)
		end
	end
	vim.bo[bufnr].modifiable = false

	if todo_window_is_valid() then
		vim.api.nvim_win_set_config(state.todo_winid, win_config)
		if vim.api.nvim_win_get_buf(state.todo_winid) ~= bufnr then
			vim.api.nvim_win_set_buf(state.todo_winid, bufnr)
		end
	else
		state.todo_winid = vim.api.nvim_open_win(bufnr, false, win_config)
	end

	setup_todo_window_options(state.todo_winid)
	done({
		session_id = session_id,
		todos = #todos,
		lines = #result.lines,
		highlights = #(result.highlights or {}),
	})
end

---@return string|nil session_id
function M.get_dock_at_cursor()
	if todo_window_is_valid() and vim.api.nvim_get_current_win() == state.todo_winid then
		local app_state = require("opencode.state")
		local current = app_state.get_session()
		return current and current.id or nil
	end
	return nil
end

---@param session_id string|nil
function M.toggle_dock(session_id)
	local app_state = require("opencode.state")
	local sync = require("opencode.sync")
	local current = app_state.get_session()
	session_id = session_id or (current and current.id)
	if not session_id then
		return
	end

	local todos = M.normalize_todos(sync.get_todos(session_id))
	if #todos == 0 then
		return
	end

	local cfg = M.get_config()
	state.todo_dock_collapsed[session_id] = not M.is_dock_collapsed(session_id, todos, cfg)

	M.update_window()
end

function M.toggle_current_dock()
	local session_id = M.get_dock_at_cursor()
	if session_id then
		M.toggle_dock(session_id)
		return
	end

	local app_state = require("opencode.state")
	local current = app_state.get_session()
	M.toggle_dock(current and current.id)
end

return M
