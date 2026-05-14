-- Todo list rendering and live dock helpers for the chat buffer.
-- Mirrors OpenCode TUI's todowrite -> session todo state -> renderer flow.

local M = {}

local render = require("opencode.ui.chat.render")
local cs = require("opencode.ui.chat.state")
local state = cs.state

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
		completed = "Comment",
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

---@return OpenCodeTodoConfig
function M.get_config()
	local ok, app_state = pcall(require, "opencode.state")
	local full_config = ok and app_state.get_config() or {}
	local todo_config = full_config.chat and full_config.chat.todo or {}
	return vim.tbl_deep_extend("force", {}, DEFAULT_CONFIG, todo_config or {})
end

---@param cfg OpenCodeTodoConfig|nil
---@return boolean
function M.is_enabled(cfg)
	cfg = cfg or M.get_config()
	return cfg.enabled ~= false
end

---@param text any
---@return string
local function normalize_content(text)
	if text == nil or text == vim.NIL then
		return ""
	end
	return vim.trim(tostring(text):gsub("\r\n", " "):gsub("\r", " "):gsub("\n", " "))
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
	local input = type(tool_state.input) == "table" and tool_state.input or tool_part.input
	local metadata = render.get_tool_metadata(tool_part)
	local output = type(tool_state.output) == "table" and tool_state.output or {}

	local function first_nonempty(todos)
		local normalized = M.normalize_todos(todos)
		if #normalized > 0 then
			return normalized
		end
		return nil
	end

	local normalized = first_nonempty(type(input) == "table" and input.todos or nil)
	if normalized then
		return normalized
	end
	normalized = first_nonempty(metadata.todos)
	if normalized then
		return normalized
	end
	normalized = first_nonempty(output.todos)
	if normalized then
		return normalized
	end
	normalized = first_nonempty(tool_part.todos)
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
---@return number
local function count_completed(todos)
	local count = 0
	for _, todo in ipairs(todos) do
		if todo.status == "completed" then
			count = count + 1
		end
	end
	return count
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

---@param cfg OpenCodeTodoConfig
---@param status string
---@return string
local function status_icon(cfg, status)
	return (cfg.icons and cfg.icons[status]) or DEFAULT_CONFIG.icons[status] or DEFAULT_CONFIG.icons.pending
end

---@param cfg OpenCodeTodoConfig
---@param status string
---@return string
local function status_highlight(cfg, status)
	return (cfg.highlights and cfg.highlights[status]) or DEFAULT_CONFIG.highlights[status] or "Comment"
end

---@param result table
---@param todo OpenCodeTodo
---@param cfg OpenCodeTodoConfig
---@param opts table|nil
local function add_todo_item(result, todo, cfg, opts)
	opts = opts or {}

	local prefix = opts.prefix or ""
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
		add_line(result, line_prefix .. text, hl_group)
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
---@param opts? table { title?: string, prefix?: string, width?: number }
---@return table result
function M.render_block(todos, opts)
	opts = opts or {}
	local cfg = M.get_config()
	local normalized = M.normalize_todos(todos)
	local result = { lines = {}, highlights = {} }
	if not M.is_enabled(cfg) or #normalized == 0 then
		return result
	end

	local prefix = opts.prefix or "┃  "
	local width = opts.width or get_chat_text_width()
	local title = opts.title or "# Todos"
	local header_hl = cfg.highlights and cfg.highlights.header or "Title"

	add_line(result, prefix .. title, header_hl)
	for _, todo in ipairs(normalized) do
		add_todo_item(result, todo, cfg, {
			prefix = prefix,
			width = width,
		})
	end

	return result
end

---@param session_id string
---@param todos any
---@return table|nil result
function M.render_dock(session_id, todos)
	local cfg = M.get_config()
	local normalized = M.normalize_todos(todos)
	if not session_id or not M.should_show_dock(normalized, cfg) then
		return nil
	end

	local collapsed = M.is_dock_collapsed(session_id, normalized, cfg)
	local result = { lines = {}, highlights = {}, collapsed = collapsed }
	local completed = count_completed(normalized)
	local header_hl = cfg.highlights and cfg.highlights.header or "Title"
	local header = collapsed and string.format("▶ Todo %d/%d", completed, #normalized) or "▼ Todo"
	add_line(result, header, header_hl)

	if collapsed then
		local preview = active_preview_todo(normalized)
		if preview then
			add_todo_item(result, preview, cfg, { width = get_chat_text_width() })
		end
		return result
	end

	for _, todo in ipairs(normalized) do
		add_todo_item(result, todo, cfg, { width = get_chat_text_width() })
	end
	return result
end

---@param tool_part table
---@return table|nil result
function M.render_tool(tool_part)
	local cfg = M.get_config()
	if not M.is_enabled(cfg) or type(tool_part) ~= "table" then
		return nil
	end

	local tool_name = tool_part.tool
	if tool_name ~= "todowrite" and tool_name ~= "todoread" then
		return nil
	end

	local tool_status = tool_part.state and tool_part.state.status or "pending"
	if tool_status ~= "completed" then
		return {
			lines = { "~ Updating todos..." },
			highlights = {
				{ line = 0, col_start = 0, col_end = -1, hl_group = "Comment" },
			},
		}
	end

	local todos = M.extract_tool_todos(tool_part)
	if #todos == 0 then
		return nil
	end

	return M.render_block(todos)
end

---@return string|nil session_id
---@return table|nil dock_info
function M.get_dock_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local dock = state.todo_dock
	if not dock or not dock.header_line then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1
	if cursor_line == dock.header_line then
		return dock.session_id, dock
	end

	return nil, nil
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

	local ok, chat = pcall(require, "opencode.ui.chat")
	if ok and chat.schedule_render then
		chat.schedule_render()
	end
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
