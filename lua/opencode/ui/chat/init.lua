-- opencode.nvim - Chat buffer UI module
-- Main chat interface with configurable layouts
-- This module mirrors the TUI's session/index.tsx rendering approach

local M = {}

local Popup = require("nui.popup")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local input = require("opencode.ui.input")
local thinking = require("opencode.ui.thinking")
local spinner = require("opencode.ui.spinner")
local locale = require("opencode.util.locale")
local session_util = require("opencode.util.session")
local event_util = require("opencode.events.util")

-- ─── Shared state & sub-modules ──────────────────────────────────────────────

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns
local session_tabs_hl_ns = vim.api.nvim_create_namespace("opencode_session_tabs_hl")
local session_tabs_augroup = vim.api.nvim_create_augroup("OpenCodeSessionTabs", { clear = false })
local FLOAT_SESSION_TABS_ZINDEX = 75
local FLOAT_CHAT_TOP_PADDING = 2
local SESSION_TAB_COUNT_MAPPING_LIMIT = 99

local render = require("opencode.ui.chat.render")
local panel = require("opencode.ui.panel")
local chat_tasks = require("opencode.ui.chat.tasks")
local chat_todos = require("opencode.ui.chat.todos")
local chat_questions = require("opencode.ui.chat.questions")
local chat_permissions = require("opencode.ui.chat.permissions")
local chat_edits = require("opencode.ui.chat.edits")
local chat_nav = require("opencode.ui.chat.nav")
local widget_support = require("opencode.ui.chat.widget_support")

local question_widget = require("opencode.ui.question_widget")
local widget_base = require("opencode.ui.widget_base")
local question_state = require("opencode.question.state")
local permission_widget = require("opencode.ui.permission_widget")
local permission_state = require("opencode.permission.state")
local edit_widget = require("opencode.ui.edit_widget")
local edit_state = require("opencode.edit.state")
local apply_widget_focus_cursor

local EDIT_WIDGET_TOOL_ROWS = {
	write = true,
	edit = true,
	apply_patch = true,
	neovim_edit = true,
	neovim_apply_patch = true,
}

-- ─── Configuration ────────────────────────────────────────────────────────────

local defaults = {
	layout = "vertical",
	position = "right",
	width = 80,
	height = 20,
	close_on_focus_lost = true,
	float = {
		width = 0.8,
		height = 0.8,
		border = "rounded",
		title = " OpenCode ",
		title_pos = "center",
	},
	message_display = {
		user_prefix = "> ",
	},
	todo = {
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
	},
	keymaps = {
		close = "q",
		close_session = "x",
		focus_input = "i",
		scroll_up = "<C-u>",
		scroll_down = "<C-d>",
		goto_top = "gg",
		goto_bottom = "G",
		abort = "<C-c>",
	},
}

---@param event_type string
---@param data table
local function emit(event_type, data)
	local ok, events = pcall(require, "opencode.events")
	if ok and events and type(events.emit) == "function" then
		events.emit(event_type, data)
	end
end

local function get_config()
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}
	return vim.tbl_deep_extend("force", defaults, full_config.chat or {})
end

local RENDER_CACHE_MAX_BLOCKS = 300

local function ensure_render_cache()
	if type(state.render_cache) ~= "table" then
		state.render_cache = { blocks = {}, order = {} }
	end
	state.render_cache.blocks = state.render_cache.blocks or {}
	state.render_cache.order = state.render_cache.order or {}
	return state.render_cache
end

local function clear_render_cache()
	state.render_cache = { blocks = {}, order = {} }
	state.last_render_highlight_signature = nil
end

local function render_cache_key(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...) or "")
	end
	return table.concat(parts, "\0")
end

local function render_cache_get(key)
	local cache = ensure_render_cache()
	return cache.blocks[key]
end

local function render_cache_put(key, value)
	if not key or not value then
		return value
	end
	local cache = ensure_render_cache()
	if cache.blocks[key] == nil then
		table.insert(cache.order, key)
	end
	cache.blocks[key] = value
	while #cache.order > RENDER_CACHE_MAX_BLOCKS do
		local oldest = table.remove(cache.order, 1)
		cache.blocks[oldest] = nil
	end
	return value
end

local function append_highlight_signature(parts, highlights, start_line)
	if type(highlights) ~= "table" then
		return
	end
	start_line = start_line or 0
	for _, hl in ipairs(highlights) do
		if type(hl) == "table" and hl.hl_group then
			local line = start_line + (hl.line or 0)
			local end_line = hl.end_line and (start_line + hl.end_line) or line
			table.insert(
				parts,
				table.concat({
					tostring(line),
					tostring(end_line),
					tostring(hl.col_start or 0),
					tostring(hl.col_end or hl.end_col or ""),
					tostring(hl.hl_group or ""),
					tostring(hl.priority or ""),
					tostring(hl.hl_eol or ""),
				}, ":")
			)
		end
	end
end

local function render_highlight_signature(content_highlights)
	local parts = {}
	append_highlight_signature(parts, content_highlights, 0)

	local function append_line_map(line_map)
		local keys = {}
		for key in pairs(line_map or {}) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			local pos = line_map[key]
			append_highlight_signature(parts, pos and pos.highlights, pos and pos.start_line or 0)
		end
	end

	for _, line_map in ipairs({ state.questions, state.permissions, state.edits, state.tasks, state.tools }) do
		append_line_map(line_map)
	end
	return table.concat(parts, "|")
end

local function highlight_clear_start(changed_start, content_highlights)
	local clear_start = changed_start or 0
	local function consider(highlights, start_line)
		local moved = false
		if type(highlights) ~= "table" then
			return moved
		end
		start_line = start_line or 0
		for _, hl in ipairs(highlights) do
			if type(hl) == "table" then
				local line = start_line + (hl.line or 0)
				local end_line = hl.end_line and (start_line + hl.end_line) or line
				if line < clear_start and end_line >= clear_start then
					clear_start = line
					moved = true
				end
			end
		end
		return moved
	end

	local moved = true
	while moved do
		moved = consider(content_highlights, 0)
		for _, line_map in ipairs({ state.questions, state.permissions, state.edits, state.tasks, state.tools }) do
			for _, pos in pairs(line_map or {}) do
				moved = consider(pos.highlights, pos.start_line or 0) or moved
			end
		end
	end
	return math.max(0, clear_start)
end

local session_tabs_refresh_autocmds_setup = false

local function schedule_session_tabs_refresh()
	vim.schedule(function()
		if state.visible and type(M.update_winbar) == "function" then
			M.update_winbar()
		end
	end)
end

local function setup_session_tabs_refresh_autocmds()
	if session_tabs_refresh_autocmds_setup then
		return
	end
	session_tabs_refresh_autocmds_setup = true

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = session_tabs_augroup,
		callback = schedule_session_tabs_refresh,
		desc = "Refresh OpenCode session tabs after colorscheme changes",
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = session_tabs_augroup,
		pattern = "background",
		callback = schedule_session_tabs_refresh,
		desc = "Refresh OpenCode session tabs after background changes",
	})
end

local function ensure_session_title_highlight()
	local ok, title_hl = pcall(vim.api.nvim_get_hl, 0, { name = "Title", link = false })
	local opts = { bold = true }
	if ok and type(title_hl) == "table" then
		opts = vim.tbl_extend("force", title_hl, opts)
	end
	vim.api.nvim_set_hl(0, "OpenCodeSessionTitle", opts)
end

local function ensure_session_error_highlights()
	panel.set_hl("OpenCodeSessionError", "DiagnosticError", "ErrorMsg")
	panel.set_hl("OpenCodeSessionErrorBorder", "DiagnosticError", "ErrorMsg")
end

local function calculate_dimensions(cfg)
	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }
	local editor_width = (vim.o.columns and vim.o.columns > 0) and vim.o.columns or ui.width
	local width, height, row, col

	if cfg.layout == "float" then
		width = math.floor(editor_width * cfg.float.width)
		height = math.floor(ui.height * cfg.float.height)
		row = math.floor((ui.height - height) / 2)
		col = math.floor((editor_width - width) / 2)
	elseif cfg.layout == "vertical" then
		width = cfg.width
		height = ui.height
		row = 0
		col = cfg.position == "right" and (editor_width - width) or 0
	else
		width = editor_width
		height = cfg.height
		row = cfg.position == "bottom" and (ui.height - height) or 0
		col = 0
	end

	return { width = width, height = height, row = row, col = col }
end

---@param winid number|nil
local function setup_chat_window_options(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end

	local wo = vim.wo[winid]
	wo.fillchars = "eob: "
	wo.wrap = true
	wo.linebreak = true
	wo.breakindent = true
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

---@param opts table
---@return boolean
local function has_highlight_options(opts)
	return type(opts) == "table" and next(opts) ~= nil
end

---@param colors table
---@param keys string[]
---@param fallback any
---@return any
local function tab_color(colors, keys, fallback)
	if type(colors) ~= "table" then
		return fallback
	end
	for _, key in ipairs(keys) do
		local value = colors[key]
		if value ~= nil and value ~= "" then
			return value
		end
	end
	return fallback
end

---@param colors table|function|nil
---@return table
local function resolve_tab_colors(colors)
	if type(colors) == "function" then
		local ok, resolved = pcall(colors)
		if ok and type(resolved) == "table" then
			return resolved
		end
		return {}
	end
	if type(colors) == "table" then
		return colors
	end
	return {}
end

---@param name string
---@param opts table
---@param fallback table|nil
local function set_winbar_hl(name, opts, fallback)
	local ok = pcall(vim.api.nvim_set_hl, 0, name, opts)
	if not ok and fallback then
		pcall(vim.api.nvim_set_hl, 0, name, fallback)
	end
end

---@param tabs_cfg table|nil
local function ensure_winbar_highlights(tabs_cfg)
	local function get_hl(name)
		local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
		return ok and value or {}
	end

	local colors = resolve_tab_colors(type(tabs_cfg) == "table" and tabs_cfg.colors or nil)
	local normal = get_hl("Normal")
	local selected = get_hl("PmenuSel")
	local visual = get_hl("Visual")
	local tab_selected = get_hl("TabLineSel")
	local search = get_hl("Search")
	local fallback_active_bg = selected.bg or visual.bg or tab_selected.bg or search.bg or "#2d5f87"
	local fallback_active_fg = selected.fg or normal.fg or tab_selected.fg or "#ffffff"
	local active_bg = tab_color(colors, { "active_bg", "current_bg" }, fallback_active_bg)
	local active_fg = tab_color(colors, { "active_fg", "current_fg" }, fallback_active_fg)
	local inactive_bg = tab_color(colors, { "inactive_bg" }, nil)
	local inactive_fg = tab_color(colors, { "inactive_fg" }, nil)
	local running_fg = tab_color(colors, { "running_fg" }, nil)
	local waiting_fg = tab_color(colors, { "waiting_fg" }, nil)
	local error_fg = tab_color(colors, { "error_fg" }, nil)
	local idle_fg = tab_color(colors, { "idle_fg" }, nil)
	local active_running_fg = tab_color(colors, { "active_running_fg", "current_running_fg" }, running_fg)
	local active_waiting_fg = tab_color(colors, { "active_waiting_fg", "current_waiting_fg" }, waiting_fg)
	local active_error_fg = tab_color(colors, { "active_error_fg", "current_error_fg" }, error_fg)
	local active_idle_fg = tab_color(colors, { "active_idle_fg", "current_idle_fg" }, idle_fg)
	local inactive_opts = {
		fg = inactive_fg,
		bg = inactive_bg,
	}

	if has_highlight_options(inactive_opts) then
		set_winbar_hl("OpenCodeWinbar", inactive_opts, { link = "StatusLine", default = true })
	else
		set_winbar_hl("OpenCodeWinbar", { link = "StatusLine", default = true })
	end

	local function set_status_hl(name, source, fg)
		if fg or inactive_bg then
			local source_hl = get_hl(source)
			set_winbar_hl(name, {
				fg = fg or source_hl.fg,
				bg = inactive_bg,
			}, { link = source, default = true })
			return
		end
		set_winbar_hl(name, { link = source, default = true })
	end

	set_status_hl("OpenCodeWinbarRunning", "DiagnosticOk", running_fg)
	set_status_hl("OpenCodeWinbarWaiting", "DiagnosticWarn", waiting_fg)
	set_status_hl("OpenCodeWinbarError", "DiagnosticError", error_fg)
	set_status_hl("OpenCodeWinbarIdle", "Comment", idle_fg)

	local active_opts = {
		fg = active_fg,
		bg = active_bg,
		bold = true,
	}

	set_winbar_hl("OpenCodeWinbarCurrent", active_opts, {
		fg = fallback_active_fg,
		bg = fallback_active_bg,
		bold = true,
	})

	local function set_active_icon_hl(name, source, fg)
		local source_hl = get_hl(source)
		set_winbar_hl(name, {
			fg = fg or source_hl.fg or active_fg,
			bg = active_bg,
			bold = true,
		}, {
			fg = source_hl.fg or fallback_active_fg,
			bg = fallback_active_bg,
			bold = true,
		})
	end

	set_active_icon_hl("OpenCodeWinbarCurrentRunning", "DiagnosticOk", active_running_fg)
	set_active_icon_hl("OpenCodeWinbarCurrentWaiting", "DiagnosticWarn", active_waiting_fg)
	set_active_icon_hl("OpenCodeWinbarCurrentError", "DiagnosticError", active_error_fg)
	set_active_icon_hl("OpenCodeWinbarCurrentIdle", "Normal", active_idle_fg)
end

---@param text string
---@return string
local function escape_winbar_text(text)
	local escaped = tostring(text or ""):gsub("%%", "%%%%")
	return escaped
end

---@param pending table|nil
---@return number
local function pending_total(pending)
	pending = pending or {}
	return (pending.permissions or 0) + (pending.questions or 0) + (pending.edits or 0)
end

---@param session table
---@param icons table
---@return string icon
---@return string hl
local function session_tab_icon(session, icons)
	local status = session.status or {}
	local status_type = type(status) == "table" and status.type or status
	if pending_total(session.pending) > 0 then
		return icons.waiting or "◈", "OpenCodeWinbarWaiting"
	end
	if status_type == "busy" or status_type == "retry" or status_type == "streaming" then
		return icons.running or "●", "OpenCodeWinbarRunning"
	end
	if status_type == "error" then
		return icons.error or "✕", "OpenCodeWinbarError"
	end
	return icons.idle or "○", "OpenCodeWinbarIdle"
end

---@param icon_hl string
---@return string
local function current_session_tab_icon_hl(icon_hl)
	if icon_hl == "OpenCodeWinbarRunning" then
		return "OpenCodeWinbarCurrentRunning"
	end
	if icon_hl == "OpenCodeWinbarWaiting" then
		return "OpenCodeWinbarCurrentWaiting"
	end
	if icon_hl == "OpenCodeWinbarError" then
		return "OpenCodeWinbarCurrentError"
	end
	return "OpenCodeWinbarCurrentIdle"
end

---@param title string
---@param max_len number
---@return string
local function truncate_title(title, max_len)
	title = tostring(title or "")
	max_len = math.max(0, tonumber(max_len) or 0)
	if vim.fn.strchars(title) <= max_len then
		return title
	end
	if max_len == 0 then
		return ""
	end
	if max_len <= 3 then
		return vim.fn.strcharpart(title, 0, max_len)
	end
	return vim.fn.strcharpart(title, 0, max_len - 3) .. "..."
end

---@param value number
---@param min_value number
---@param max_value number
---@return number
local function clamp(value, min_value, max_value)
	if value < min_value then
		return min_value
	end
	if value > max_value then
		return max_value
	end
	return value
end

---@param text string|table|nil
---@param align string|nil
---@return boolean
local function set_float_border_title(text, align)
	if not state.config or state.config.layout ~= "float" then
		return false
	end
	if not state.layout or not state.layout.border or type(state.layout.border.set_text) ~= "function" then
		return false
	end

	local cfg = state.config or get_config()
	local fallback = cfg.float and cfg.float.title or " OpenCode "
	local title = fallback
	if type(text) == "string" and text ~= "" then
		title = " " .. text .. " "
	elseif type(text) == "table" then
		title = text
	end
	local title_align = align or (cfg.float and cfg.float.title_pos) or "center"

	local ok = pcall(function()
		state.layout.border:set_text("top", title, title_align)
	end)
	return ok
end

---@param sessions table[]
---@param active_session table
---@param current_root_session_id string|nil
---@return number|nil index
---@return string|nil session_id
local function current_session_tab_index(sessions, active_session, current_root_session_id)
	for index, session in ipairs(sessions) do
		if session.is_current or session.id == active_session.id or session.id == current_root_session_id then
			return index, session.id
		end
	end
	return nil, current_root_session_id or active_session.id
end

---@param session_count number
---@param max_tabs number
---@param current_index number|nil
---@return number start_index
local function centered_session_tabs_start(session_count, max_tabs, current_index)
	if session_count <= max_tabs then
		return 1
	end
	if not current_index then
		return 1
	end

	local max_start = session_count - max_tabs + 1
	local start_index = current_index - math.floor(max_tabs / 2)
	return clamp(start_index, 1, max_start)
end

---@param sessions table[]
---@param max_tabs number
---@param current_index number|nil
---@param current_session_id string|nil
---@return number start_index
local function visible_session_tabs_start(sessions, max_tabs, current_index, current_session_id)
	local session_count = #sessions
	if session_count <= max_tabs then
		state.session_tabs_start = nil
		state.session_tabs_current_id = current_session_id
		return 1
	end

	local max_start = session_count - max_tabs + 1
	local stored_start = tonumber(state.session_tabs_start)
	if stored_start and state.session_tabs_current_id == current_session_id then
		local start_index = clamp(math.floor(stored_start), 1, max_start)
		state.session_tabs_start = start_index
		return start_index
	end

	local start_index = centered_session_tabs_start(session_count, max_tabs, current_index)
	state.session_tabs_start = start_index
	state.session_tabs_current_id = current_session_id
	return start_index
end

---@param tabs_cfg table
---@param current_session table|nil
---@return table tabs
local function build_session_tabs(tabs_cfg, current_session)
	ensure_winbar_highlights(tabs_cfg)

	local app_state = require("opencode.state")
	local sessions = app_state.get_active_sessions()
	local active_session = current_session or app_state.get_session() or {}
	local current_root_session_id = nil
	if active_session.id and not app_state.is_runtime_session(active_session.id) then
		for _, session in ipairs(sessions) do
			if event_util.session_owns_task_child(session.id, active_session.id) then
				current_root_session_id = session.id
				break
			end
		end
	end

	local max_tabs = math.max(1, tonumber(tabs_cfg.max_tabs) or 3)
	local separator = tabs_cfg.separator or " │ "
	local icons = tabs_cfg.icons or {}
	local parts = {}
	local line = NuiLine()
	local has_tabs = false
	local display_col = 0
	local target_id = 0
	state.winbar_targets = {}
	state.session_tabs_mouse_targets = {}

	local current_index, current_session_id = current_session_tab_index(sessions, active_session, current_root_session_id)
	local start_index = visible_session_tabs_start(sessions, max_tabs, current_index, current_session_id)
	local end_index = math.min(#sessions, start_index + max_tabs - 1)
	local max_start = math.max(1, #sessions - max_tabs + 1)

	---@param text string
	---@param hl string
	local function append_text(text, hl)
		line:append(text, hl)
		display_col = display_col + vim.fn.strdisplaywidth(text)
	end

	local function append_separator()
		if has_tabs then
			append_text(separator, "OpenCodeWinbar")
		end
	end

	---@param target table
	---@return number
	local function register_target(target)
		target_id = target_id + 1
		state.winbar_targets[target_id] = target
		return target_id
	end

	---@param id number
	---@param start_col number
	---@param end_col number
	local function register_mouse_target(id, start_col, end_col)
		if end_col < start_col then
			return
		end
		table.insert(state.session_tabs_mouse_targets, {
			target = id,
			start_col = start_col,
			end_col = end_col,
		})
	end

	---@param page_start number
	---@param hidden_count number
	local function append_ellipsis(page_start, hidden_count)
		append_separator()
		local id = register_target({
			kind = "page",
			start = clamp(page_start, 1, max_start),
			current_session_id = current_session_id,
		})
		local label = "..." .. tostring(hidden_count)
		local start_col = display_col + 1
		append_text(label, "OpenCodeWinbar")
		register_mouse_target(id, start_col, display_col)
		has_tabs = true
		table.insert(
			parts,
			string.format(
				"%%%d@v:lua.__opencode_chat_winbar_click@%%#OpenCodeWinbar#%s%%T",
				id,
				escape_winbar_text(label)
			)
		)
	end

	if #sessions > max_tabs and start_index > 1 then
		append_ellipsis(start_index - max_tabs, start_index - 1)
	end

	for index = start_index, end_index do
		local session = sessions[index]
		local icon, icon_hl = session_tab_icon(session, icons)
		local title = session_util.displayTitle(session.title or session.name) or session.id
		local display_title = truncate_title(title, 18)
		local is_current = session.is_current or active_session.id == session.id or current_root_session_id == session.id
		local label_hl = is_current and "OpenCodeWinbarCurrent" or "OpenCodeWinbar"
		local display_icon = is_current and (" " .. icon) or icon
		local display_label = is_current and (" " .. display_title .. " ") or (" " .. display_title)
		local display_icon_hl = is_current and current_session_tab_icon_hl(icon_hl) or icon_hl
		append_separator()
		local id = register_target({
			kind = "session",
			session_id = session.id,
		})
		local start_col = display_col + 1
		append_text(display_icon, display_icon_hl)
		append_text(display_label, label_hl)
		register_mouse_target(id, start_col, display_col)
		has_tabs = true
		table.insert(
			parts,
			string.format(
				"%%%d@v:lua.__opencode_chat_winbar_click@%%#%s#%s%%#%s#%s%%T",
				id,
				display_icon_hl,
				escape_winbar_text(display_icon),
				label_hl,
				escape_winbar_text(display_label)
			)
		)
	end

	if #sessions > max_tabs and end_index < #sessions then
		append_ellipsis(start_index + max_tabs, #sessions - end_index)
	end

	local running = 0
	local waiting = 0
	for _, session in ipairs(sessions) do
		local status = session.status or {}
		local status_type = type(status) == "table" and status.type or status
		if status_type == "busy" or status_type == "retry" or status_type == "streaming" then
			running = running + 1
		end
		if pending_total(session.pending) > 0 then
			waiting = waiting + 1
		end
	end

	if running > 0 or waiting > 0 then
		append_separator()
		append_text((icons.running or "●") .. tostring(running), "OpenCodeWinbarRunning")
		append_text(" ", "OpenCodeWinbar")
		append_text((icons.waiting or "◈") .. tostring(waiting), "OpenCodeWinbarWaiting")
		has_tabs = true
		table.insert(
			parts,
			string.format(
				"%%#OpenCodeWinbar#%s%%#OpenCodeWinbarRunning#%s%d %%#OpenCodeWinbarWaiting#%s%d",
				"",
				escape_winbar_text(icons.running or "●"),
				running,
				escape_winbar_text(icons.waiting or "◈"),
				waiting
			)
		)
	end

	if has_tabs then
		append_text(" ", "OpenCodeWinbar")
	end

	return {
		line = line,
		parts = parts,
		separator = separator,
		has_tabs = has_tabs,
	}
end

---@return boolean
local function session_tabs_window_is_valid()
	return state.session_tabs_winid and vim.api.nvim_win_is_valid(state.session_tabs_winid) or false
end

---@return boolean
local function session_tabs_buffer_is_valid()
	return state.session_tabs_bufnr and vim.api.nvim_buf_is_valid(state.session_tabs_bufnr) or false
end

local function close_float_session_tabs_window()
	if session_tabs_window_is_valid() then
		pcall(vim.api.nvim_win_close, state.session_tabs_winid, true)
	end
	state.session_tabs_winid = nil
	state.session_tabs_mouse_targets = {}
end

local function focus_chat_window()
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		pcall(vim.api.nvim_set_current_win, state.winid)
	end
end

---@param mode string
---@return boolean
local function is_visual_or_select_mode(mode)
	return mode == "v" or mode == "V" or mode == string.char(22) or mode == "s" or mode == "S" or mode == string.char(19)
end

local function leave_session_tabs_visual_mode()
	if is_visual_or_select_mode(vim.api.nvim_get_mode().mode) then
		local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
		vim.api.nvim_feedkeys(esc, "nx", false)
	end
	focus_chat_window()
end

local function handle_session_tabs_mouse_click()
	local mouse = vim.fn.getmousepos()
	if not mouse or mouse.winid ~= state.session_tabs_winid then
		focus_chat_window()
		return
	end

	local col = tonumber(mouse.wincol or 0) or 0
	if col <= 0 then
		col = tonumber(mouse.column or 0) or 0
	end
	if col <= 0 then
		focus_chat_window()
		return
	end

	for _, target in ipairs(state.session_tabs_mouse_targets or {}) do
		if col >= target.start_col and col <= target.end_col then
			M.select_winbar_session(target.target)
			focus_chat_window()
			return
		end
	end

	focus_chat_window()
end

---@return number bufnr
local function setup_session_tabs_buffer()
	if session_tabs_buffer_is_valid() then
		return state.session_tabs_bufnr
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	state.session_tabs_bufnr = bufnr
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode_session_tabs"
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true

	local function map(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, {
			buffer = bufnr,
			noremap = true,
			silent = true,
			nowait = true,
			desc = desc,
		})
	end

	map("n", "<LeftMouse>", handle_session_tabs_mouse_click, "Select OpenCode session tab")
	map({ "v", "s" }, "<LeftMouse>", leave_session_tabs_visual_mode, "Leave OpenCode session tab selection")
	map({ "n", "v", "s" }, "<LeftDrag>", leave_session_tabs_visual_mode, "Ignore OpenCode session tab drag")
	map({ "n", "v", "s" }, "<LeftRelease>", leave_session_tabs_visual_mode, "Ignore OpenCode session tab release")
	map("n", "v", leave_session_tabs_visual_mode, "Disable OpenCode session tab visual mode")
	map("n", "V", leave_session_tabs_visual_mode, "Disable OpenCode session tab linewise visual mode")
	map("n", "<C-v>", leave_session_tabs_visual_mode, "Disable OpenCode session tab block visual mode")

	pcall(vim.api.nvim_create_autocmd, "ModeChanged", {
		group = session_tabs_augroup,
		buffer = bufnr,
		callback = function()
			if not session_tabs_window_is_valid() or vim.api.nvim_get_current_win() ~= state.session_tabs_winid then
				return
			end
			if is_visual_or_select_mode(vim.api.nvim_get_mode().mode) then
				vim.schedule(leave_session_tabs_visual_mode)
			end
		end,
	})

	return bufnr
end

---@param winid number|nil
local function setup_session_tabs_window_options(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end

	local wo = vim.wo[winid]
	wo.fillchars = "eob: "
	wo.wrap = false
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "no"
	wo.foldcolumn = "0"
	wo.cursorline = false
	wo.cursorcolumn = false
	wo.winhighlight = "Normal:OpenCodeWinbar,EndOfBuffer:OpenCodeWinbar"
	pcall(function()
		wo.statuscolumn = ""
	end)
	pcall(function()
		wo.winbar = ""
	end)
end

---@param frame table
---@param _tab_width number
---@return table|nil
local function calculate_session_tabs_window_config(frame, _tab_width)
	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }
	local max_width = math.max(1, (tonumber(frame.width) or 0) - 2)
	local width = max_width
	local row = math.max(0, tonumber(frame.row) or 0)
	local col = math.max(0, tonumber(frame.col) or 0) + 1

	if width <= 0 or row >= ui.height or col >= ui.width then
		return nil
	end

	width = math.min(width, math.max(1, ui.width - col))

	return {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = 1,
		style = "minimal",
		focusable = true,
		zindex = FLOAT_SESSION_TABS_ZINDEX,
	}
end

---@param tabs_cfg table
---@param current_session table|nil
---@return boolean visible
local function update_float_session_tabs_window(tabs_cfg, current_session)
	if not state.visible or not state.config or state.config.layout ~= "float" or tabs_cfg.enabled == false then
		close_float_session_tabs_window()
		return false
	end
	if not state.float_dims then
		close_float_session_tabs_window()
		return false
	end

	local tabs = build_session_tabs(tabs_cfg, current_session)
	if not tabs.has_tabs then
		close_float_session_tabs_window()
		return false
	end

	local tab_width = vim.fn.strdisplaywidth(tabs.line:content())
	local win_config = calculate_session_tabs_window_config(state.float_dims, tab_width)
	if not win_config then
		close_float_session_tabs_window()
		return false
	end

	local bufnr = setup_session_tabs_buffer()
	vim.bo[bufnr].readonly = false
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { tabs.line:content() })
	vim.api.nvim_buf_clear_namespace(bufnr, session_tabs_hl_ns, 0, -1)
	tabs.line:highlight(bufnr, session_tabs_hl_ns, 1)
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true

	if session_tabs_window_is_valid() then
		vim.api.nvim_win_set_config(state.session_tabs_winid, win_config)
		if vim.api.nvim_win_get_buf(state.session_tabs_winid) ~= bufnr then
			vim.api.nvim_win_set_buf(state.session_tabs_winid, bufnr)
		end
	else
		state.session_tabs_winid = vim.api.nvim_open_win(bufnr, false, win_config)
	end

	setup_session_tabs_window_options(state.session_tabs_winid)
	return true
end

function M.update_winbar()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		close_float_session_tabs_window()
		return
	end
	local cfg = state.config or get_config()
	local tabs_cfg = cfg.session_tabs or {}
	if tabs_cfg.enabled == false then
		pcall(function()
			vim.wo[state.winid].winbar = ""
		end)
		state.winbar_targets = {}
		state.session_tabs_mouse_targets = {}
		set_float_border_title(nil)
		close_float_session_tabs_window()
		return
	end

	if cfg.layout == "float" then
		pcall(function()
			vim.wo[state.winid].winbar = ""
		end)
		set_float_border_title(nil)
		update_float_session_tabs_window(tabs_cfg)
		return
	end

	close_float_session_tabs_window()
	local tabs = build_session_tabs(tabs_cfg)

	pcall(function()
		vim.wo[state.winid].winbar = table.concat(tabs.parts, escape_winbar_text(tabs.separator))
	end)
end

---@param target number|string
function M.select_winbar_session(target)
	local index = tonumber(target)
	local entry = index and state.winbar_targets[index] or nil
	if type(entry) == "table" and entry.kind == "page" then
		state.session_tabs_start = entry.start
		state.session_tabs_current_id = entry.current_session_id
		M.update_winbar()
		focus_chat_window()
		return
	end

	local session_id = type(entry) == "table" and entry.session_id or entry
	if not session_id then
		focus_chat_window()
		return
	end
	local app_state = require("opencode.state")
	local record = app_state.get_session_record(session_id) or { id = session_id }
	require("opencode.session").switch_to(record, {
		notify = false,
		reason = "winbar",
	})
	focus_chat_window()
end

---@param target table|nil
---@param current_session table|nil
---@return boolean switched
local function switch_to_session_tab(target, current_session)
	if type(target) ~= "table" or not target.id then
		return false
	end

	local current = current_session or require("opencode.state").get_session() or {}
	if target.id == current.id then
		return false
	end

	local app_state = require("opencode.state")
	local record = app_state.get_session_record(target.id) or target
	require("opencode.session").switch_to(record, {
		notify = false,
		reason = "winbar",
	})
	return true
end

---@param index number
---@return boolean switched
function M.go_to_session_tab(index)
	local target_index = tonumber(index)
	if not target_index then
		return false
	end

	if target_index == 0 then
		target_index = 1
	else
		target_index = math.floor(target_index)
	end
	if target_index < 1 then
		return false
	end

	local app_state = require("opencode.state")
	local sessions = app_state.get_active_sessions()
	return switch_to_session_tab(sessions[target_index], app_state.get_session())
end

---@param direction number
---@return boolean switched
function M.cycle_session(direction)
	local app_state = require("opencode.state")
	local sessions = app_state.get_active_sessions()
	if #sessions <= 1 then
		return false
	end

	local current = app_state.get_session() or {}
	local current_index = nil
	for index, session in ipairs(sessions) do
		if session.id == current.id or session.is_current then
			current_index = index
			break
		end
	end

	if not current_index and current.id then
		for index, session in ipairs(sessions) do
			if event_util.session_owns_task_child(session.id, current.id) then
				current_index = index
				break
			end
		end
	end

	local step = direction < 0 and -1 or 1
	if not current_index then
		current_index = step > 0 and 0 or 1
	end

	local next_index = ((current_index - 1 + step) % #sessions) + 1
	local target = sessions[next_index]
	return switch_to_session_tab(target, current)
end

_G.__opencode_chat_winbar_click = _G.__opencode_chat_winbar_click or function(minwid)
	local ok, chat = pcall(require, "opencode.ui.chat")
	if ok and type(chat.select_winbar_session) == "function" then
		chat.select_winbar_session(minwid)
	end
end

-- ─── Float focus autocmds ─────────────────────────────────────────────────────

local function clear_float_focus_autocmds()
	if not state.focus_augroup then
		return
	end
	pcall(vim.api.nvim_del_augroup_by_id, state.focus_augroup)
	state.focus_augroup = nil
end

local function is_opencode_related_window(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return false
	end
	if state.winid and winid == state.winid then
		return true
	end
	if state.session_tabs_winid and winid == state.session_tabs_winid then
		return true
	end
	if type(chat_edits.is_inline_diff_window) == "function" and chat_edits.is_inline_diff_window(winid) then
		return true
	end

	local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
	if ok_buf and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		local ft = vim.bo[bufnr].filetype
		if type(ft) == "string" and ft:match("^opencode") then
			return true
		end
	end

	local ok_input, input_ui = pcall(require, "opencode.ui.input")
	if ok_input and type(input_ui.get_winids) == "function" then
		for _, candidate in ipairs(input_ui.get_winids()) do
			if winid == candidate then
				return true
			end
		end
	end

	local ok_palette, palette = pcall(require, "opencode.ui.palette")
	if ok_palette and type(palette.get_winids) == "function" then
		for _, candidate in ipairs(palette.get_winids()) do
			if winid == candidate then
				return true
			end
		end
	end

	return false
end

---@param current_win number|nil
---@return boolean
local function mouse_is_inside_float_frame(current_win)
	if not state.float_dims then
		return false
	end
	local mouse = vim.fn.getmousepos()
	if type(mouse) ~= "table" then
		return false
	end
	local mouse_winid = tonumber(mouse.winid or 0) or 0
	if current_win and mouse_winid > 0 and mouse_winid ~= current_win then
		return false
	end

	local row = (tonumber(mouse.screenrow or 0) or 0) - 1
	local col = (tonumber(mouse.screencol or 0) or 0) - 1
	if row < 0 or col < 0 then
		return false
	end

	local frame = state.float_dims
	local frame_row = tonumber(frame.row) or 0
	local frame_col = tonumber(frame.col) or 0
	local frame_height = tonumber(frame.height) or 0
	local frame_width = tonumber(frame.width) or 0

	return row >= frame_row and row < frame_row + frame_height and col >= frame_col and col < frame_col + frame_width
end

local function setup_float_focus_autocmds()
	clear_float_focus_autocmds()

	state.focus_augroup =
		vim.api.nvim_create_augroup("OpenCodeFloatFocus_" .. tostring(state.bufnr or 0), { clear = true })

	vim.api.nvim_create_autocmd("WinEnter", {
		group = state.focus_augroup,
		callback = function()
			vim.schedule(function()
				if not state.visible then
					return
				end
				if state.tabpage and state.tabpage ~= vim.api.nvim_get_current_tabpage() then
					return
				end
				if not state.config or state.config.layout ~= "float" then
					return
				end
				if state.config.close_on_focus_lost == false then
					return
				end

				-- Don't close when the user is in the native diff tab
				local nd_ok, nd = pcall(require, "opencode.ui.native_diff")
				if nd_ok and nd.is_active and nd.is_active() then
					return
				end

				local current_win = vim.api.nvim_get_current_win()
				if is_opencode_related_window(current_win) then
					return
				end
				if mouse_is_inside_float_frame(current_win) then
					focus_chat_window()
					return
				end

				M.close()
			end)
		end,
	})
end

-- ─── Cursor preservation ──────────────────────────────────────────────────────

---@class OpenCodeWidgetCursorContext
---@field kind "question" | "permission" | "edit"
---@field id string
---@field relative_line number

---@param kind "question" | "permission" | "edit"
---@return table
local function get_widget_positions(kind)
	if kind == "question" then
		return state.questions
	end
	if kind == "permission" then
		return state.permissions
	end
	return state.edits
end

---@param kind "question" | "permission" | "edit"
---@param pos table|nil
---@return boolean
local function is_widget_cursor_target(kind, pos)
	if not pos then
		return false
	end

	if kind == "question" then
		return pos.status == "pending" or pos.status == "confirming"
	end
	if kind == "permission" then
		return pos.status == "pending"
	end
	return pos.status ~= "sent"
end

---@return number|nil min_line
---@return number|nil max_line
local function interactive_widget_bounds()
	local min_line = nil
	local max_line = nil
	local widget_kinds = { "question", "permission", "edit" }
	for _, kind in ipairs(widget_kinds) do
		for _, pos in pairs(get_widget_positions(kind)) do
			if is_widget_cursor_target(kind, pos) then
				min_line = min_line and math.min(min_line, pos.start_line) or pos.start_line
				max_line = max_line and math.max(max_line, pos.end_line) or pos.end_line
			end
		end
	end
	return min_line, max_line
end

---@return OpenCodeWidgetCursorContext|nil
local function capture_widget_cursor_context()
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil
	end

	local cursor_line = vim.api.nvim_win_get_cursor(state.winid)[1] - 1
	local widget_kinds = { "question", "permission", "edit" }

	for _, kind in ipairs(widget_kinds) do
		for widget_id, pos in pairs(get_widget_positions(kind)) do
			if
				is_widget_cursor_target(kind, pos)
				and cursor_line >= pos.start_line
				and cursor_line <= pos.end_line
			then
				return {
					kind = kind,
					id = widget_id,
					relative_line = cursor_line - pos.start_line,
				}
			end
		end
	end

	return nil
end

---@param widget_cursor OpenCodeWidgetCursorContext|nil
---@return boolean
local function restore_widget_cursor_context(widget_cursor)
	if not widget_cursor then
		return false
	end
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return false
	end
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end

	local pos = get_widget_positions(widget_cursor.kind)[widget_cursor.id]
	if not is_widget_cursor_target(widget_cursor.kind, pos) then
		return false
	end

	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	local min_line = math.min(pos.start_line + 1, buf_lines)
	local max_line = math.min(pos.end_line + 1, buf_lines)
	if min_line <= 0 or max_line <= 0 then
		return false
	end

	local target_line = pos.start_line + widget_cursor.relative_line + 1
	target_line = math.max(min_line, math.min(target_line, max_line))

	vim.api.nvim_win_set_cursor(state.winid, { target_line, 0 })
	M.sync_widget_selection_from_cursor()
	return true
end

---@param widget_cursor OpenCodeWidgetCursorContext|nil
---@return boolean
local function should_auto_scroll(widget_cursor)
	if widget_cursor then
		return false
	end
	if not state.auto_scroll or not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local win_height = vim.api.nvim_win_get_height(state.winid)
	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	return cursor[1] >= buf_lines - win_height - 1
end

-- ─── Buffer setup ────────────────────────────────────────────────────────────

local function setup_buffer(bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode"
	vim.bo[bufnr].modifiable = false
	pcall(vim.api.nvim_buf_set_name, bufnr, "opencode")

	local cfg = state.config
	local opts = { buffer = bufnr, noremap = true, silent = true }

	vim.keymap.set("n", cfg.keymaps.close, function()
		M.close()
	end, opts)

	vim.keymap.set("n", cfg.keymaps.focus_input, function()
		M.focus_input()
	end, opts)

	vim.keymap.set("n", cfg.keymaps.scroll_up, "<C-u>", opts)
	vim.keymap.set("n", cfg.keymaps.scroll_down, "<C-d>", opts)
	vim.keymap.set("n", cfg.keymaps.goto_top, "gg", opts)
	vim.keymap.set("n", cfg.keymaps.goto_bottom, "G", opts)

	vim.keymap.set("n", cfg.keymaps.abort, function()
		require("opencode.actions").abort()
	end, vim.tbl_extend("force", opts, { desc = "Stop current generation" }))

	vim.keymap.set("n", "a", function()
		M.toggle_auto_scroll()
	end, vim.tbl_extend("force", opts, { desc = "Toggle auto-scroll" }))

	local todo_keymap = cfg.todo
		and cfg.todo.keymaps
		and cfg.todo.keymaps.toggle
	if todo_keymap and todo_keymap ~= "" then
		vim.keymap.set("n", todo_keymap, function()
			chat_todos.toggle_current_dock()
		end, vim.tbl_extend("force", opts, { desc = "Toggle todo window" }))
	end

	vim.keymap.set("n", "?", function()
		M.show_help()
	end, opts)

	vim.keymap.set("n", "<C-p>", function()
		local palette = require("opencode.ui.palette")
		palette.show()
	end, { buffer = bufnr, noremap = true, silent = true, desc = "Open command palette" })

	vim.keymap.set("n", "N", function()
		require("opencode.actions").new_session()
	end, { buffer = bufnr, noremap = true, silent = true, desc = "Start new session" })

	if cfg.keymaps.close_session and cfg.keymaps.close_session ~= "" then
		vim.keymap.set("n", cfg.keymaps.close_session, function()
			require("opencode.actions").close_session({ notify = true })
		end, vim.tbl_extend("force", opts, { desc = "Close current OpenCode session tab" }))
	end

	vim.keymap.set("n", "gt", function()
		local count = tonumber(vim.v.count) or 0
		if count > 0 then
			M.go_to_session_tab(count)
			return
		end
		M.cycle_session(1)
	end, vim.tbl_extend("force", opts, { desc = "Next or counted OpenCode session" }))

	vim.keymap.set("n", "0gt", function()
		M.go_to_session_tab(0)
	end, vim.tbl_extend("force", opts, { desc = "First OpenCode session" }))

	for i = 1, SESSION_TAB_COUNT_MAPPING_LIMIT do
		local index = i
		vim.keymap.set("n", tostring(index) .. "gt", function()
			M.go_to_session_tab(index)
		end, vim.tbl_extend("force", opts, { desc = string.format("OpenCode session %d", index) }))
	end

	vim.keymap.set("n", "gT", function()
		M.cycle_session(-1)
	end, vim.tbl_extend("force", opts, { desc = "Previous OpenCode session" }))

	-- Question / permission / edit navigation (cursor moves first; widget selection follows cursor)
	vim.keymap.set("n", "j", function()
		M.handle_question_navigation("down")
	end, opts)
	vim.keymap.set("n", "k", function()
		M.handle_question_navigation("up")
	end, opts)
	vim.keymap.set("n", "<Down>", function()
		M.handle_question_navigation("down")
	end, opts)
	vim.keymap.set("n", "<Up>", function()
		M.handle_question_navigation("up")
	end, opts)

	vim.keymap.set("n", "<CR>", function()
		M.handle_question_confirm()
	end, opts)

	vim.keymap.set("n", "<Tab>", function()
		M.handle_question_next_tab()
	end, opts)
	vim.keymap.set("n", "<S-Tab>", function()
		M.handle_question_prev_tab()
	end, opts)

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			M.handle_question_number_select(i)
		end, opts)
	end

	vim.keymap.set("n", "c", function()
		M.handle_question_custom_input()
	end, opts)

	vim.keymap.set("n", "m", function()
		M.handle_widget_message()
	end, opts)

	vim.keymap.set("n", "<Space>", function()
		M.handle_question_toggle()
	end, opts)

	-- Edit widget keybindings
	vim.keymap.set("n", "<C-a>", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_accept_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-a>", true, false, true), "n", false)
		end
	end, opts)

	vim.keymap.set("n", "<C-x>", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_reject_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x>", true, false, true), "n", false)
		end
	end, opts)

	vim.keymap.set("n", "<C-m>", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_resolve_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-m>", true, false, true), "n", false)
		end
	end, opts)

	vim.keymap.set("n", "=", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_toggle_diff()
		else
			vim.api.nvim_feedkeys("=", "n", false)
		end
	end, opts)

	vim.keymap.set("n", "A", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_accept_all()
		else
			vim.api.nvim_feedkeys("A", "n", false)
		end
	end, opts)

	vim.keymap.set("n", "X", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_reject_all()
		else
			vim.api.nvim_feedkeys("X", "n", false)
		end
	end, opts)

	vim.keymap.set("n", "M", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_resolve_all()
		else
			vim.api.nvim_feedkeys("M", "n", false)
		end
	end, opts)

	vim.keymap.set("n", "dt", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_diff_tab()
		end
	end, vim.tbl_extend("force", opts, { nowait = true }))

	vim.keymap.set("n", "dv", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_diff_split()
		end
	end, vim.tbl_extend("force", opts, { nowait = true }))

	-- Task / subagent navigation
	vim.keymap.set("n", "gd", function()
		local task_part_id = chat_tasks.get_task_at_cursor()
		if task_part_id then
			chat_nav.enter_child_session(task_part_id)
		end
	end, vim.tbl_extend("force", opts, { nowait = true }))

	vim.keymap.set("n", "<BS>", function()
		if #state.session_stack > 0 then
			chat_nav.leave_child_session()
		end
	end, opts)

	vim.keymap.set("n", "O", function()
		-- Task blocks are registered in state.tasks with their full line range,
		-- so get_task_at_cursor() covers the header AND all ├/└ summary lines.
		-- Check task first so no task line ever falls through to handle_tool_toggle.
		local task_part_id = chat_tasks.get_task_at_cursor()
		if task_part_id then
			chat_tasks.handle_task_toggle(task_part_id)
			return
		end
		-- Regular (non-task) tools: expand/collapse raw I/O.
		local tool_part_id = chat_tasks.get_tool_at_cursor()
		if tool_part_id then
			chat_tasks.handle_tool_toggle(tool_part_id)
			return
		end
	end, vim.tbl_extend("force", opts, { desc = "Toggle tool output", nowait = true }))

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = bufnr,
		callback = function()
			if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
				return
			end
			if vim.api.nvim_get_current_win() ~= state.winid then
				return
			end
			M.sync_widget_selection_from_cursor()
		end,
	})
end

local function create_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	setup_buffer(bufnr)
	return bufnr
end

local SPINNER_ANIM_INTERVAL_MS = 80

local function stop_spinner_animation_timer()
	if not state.spinner_anim_timer then
		return
	end
	if vim.uv.is_closing(state.spinner_anim_timer) then
		state.spinner_anim_timer = nil
		return
	end
	state.spinner_anim_timer:stop()
	state.spinner_anim_timer:close()
	state.spinner_anim_timer = nil
end

local function start_spinner_animation_timer()
	if state.spinner_anim_timer then
		return
	end
	if not state.visible or not spinner.is_active() then
		return
	end

	local timer = vim.uv.new_timer()
	if not timer then
		return
	end

	state.spinner_anim_timer = timer
	timer:start(
		SPINNER_ANIM_INTERVAL_MS,
		SPINNER_ANIM_INTERVAL_MS,
		vim.schedule_wrap(function()
			if not state.visible or not spinner.is_active() then
				stop_spinner_animation_timer()
				return
			end
			M.update_spinner_only()
		end)
	)
end

local function resume_render_animation_timers()
	if not state.visible then
		return
	end
	if spinner.is_active() then
		start_spinner_animation_timer()
	end
	if chat_tasks.has_active_task_rows() then
		chat_tasks.start_task_animation_timer()
	end
end

-- ─── Window lifecycle ─────────────────────────────────────────────────────────

function M.toggle_auto_scroll()
	state.auto_scroll = not state.auto_scroll
	vim.notify(string.format("Auto-scroll %s", state.auto_scroll and "enabled" or "disabled"), vim.log.levels.INFO)
end

function M.show_help()
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "NormalFloat", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBorder", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputInfo", { link = "Comment", default = true })

	local todo_toggle = state.config
		and state.config.todo
		and state.config.todo.keymaps
		and state.config.todo.keymaps.toggle
		or "T"
	local close_session_key = state.config
		and state.config.keymaps
		and state.config.keymaps.close_session
		or "x"

	local lines = {
		"Chat Buffer Keymaps",
		"",
		"q          Close chat",
		"i          Focus input",
		"a          Toggle auto-scroll",
		"<C-c>      Stop generation",
		"<C-p>      Command palette",
		"N          Start new session",
		string.format("%-10s Close current session tab", close_session_key),
		"gt         Next session",
		"Ngt        Go to session N",
		"0gt        Go to first session",
		"gT         Previous session",
		"<C-u>      Scroll up",
		"<C-d>      Scroll down",
		"gg         Go to top",
		"G          Go to bottom",
		"?          Show this help",
		"",
		"Input Mode",
		"<C-g>      Send message",
		"<C-v>      Paste clipboard",
		"<Esc>      Cancel",
		"↑/↓        Navigate history",
		"<C-s>      Stash input",
		"<C-r>      Restore input",
		"",
		"Tool Calls",
		"O          Toggle task expand (tool I/O in subagent view only)",
		"<CR>       Toggle details",
		"gd         Enter subagent output",
		"<BS>       Go back to parent",
		"gD         View diff",
		"",
		"Todos",
		string.format("%-10s Toggle todo window", todo_toggle),
		"",
		"Question Tool",
		"1-9        Select option by number",
		"↑/↓ j/k    Move cursor (selection follows)",
		"Space      Toggle multi-select",
		"c          Custom input",
		"<CR>       Confirm selection",
		"<Esc>      Cancel question",
		"<Tab>      Next question tab",
		"<S-Tab>    Previous question tab",
		"",
		"Permissions",
		"1-3        Select option by number",
		"↑/↓ j/k    Move cursor (selection follows)",
		"<CR>       Confirm permission",
		"<Esc>      Reject permission",
		"",
		"Edit Review",
		"<C-a>      Accept selected file",
		"<C-x>      Reject selected file",
		"<C-m>      Resolve file manually",
		"=          Toggle inline diff",
		"dt         Open diff in new tab",
		"dv         Open diff vsplit",
		"A          Accept all files",
		"X          Reject all files",
		"M          Resolve all manually",
		"<CR>       Open file in editor",
		"1-9        Jump to file N",
		"",
		"Press any key to close",
	}

	local width = 42
	local height = #lines

	local chat_winid = vim.api.nvim_get_current_win()
	local chat_pos = vim.api.nvim_win_get_position(chat_winid)
	local chat_win_width = vim.api.nvim_win_get_width(chat_winid)
	local chat_win_height = vim.api.nvim_win_get_height(chat_winid)

	local row = chat_pos[1] + math.floor((chat_win_height - height) / 2)
	local col = chat_pos[2] + math.floor((chat_win_width - width) / 2)

	local popup = Popup({
		enter = true,
		focusable = true,
		border = { style = { "", "", "", "", "", "", "", "┃" } },
		position = { row = row, col = col },
		size = { width = width - 1, height = height },
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg,FloatBorder:OpenCodeInputBorder",
		},
	})

	popup:mount()
	vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
	vim.bo[popup.bufnr].modifiable = false

	local ns = vim.api.nvim_create_namespace("opencode_help")
	local section_headers = {
		["Chat Buffer Keymaps"] = true,
		["Input Mode"] = true,
		["Tool Calls"] = true,
		["Todos"] = true,
		["Question Tool"] = true,
		["Permissions"] = true,
		["Edit Review"] = true,
	}
	for i, line in ipairs(lines) do
		if section_headers[line] then
			vim.api.nvim_buf_set_extmark(
				popup.bufnr,
				ns,
				i - 1,
				0,
				{ end_col = #line, hl_group = "OpenCodeInputBorder" }
			)
		elseif line == "Press any key to close" then
			vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, 0, { end_col = #line, hl_group = "OpenCodeInputInfo" })
		elseif line ~= "" then
			local key_end = line:find("  ")
			if key_end then
				vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, 0, { end_col = key_end - 1, hl_group = "Normal" })
				vim.api.nvim_buf_set_extmark(
					popup.bufnr,
					ns,
					i - 1,
					key_end - 1,
					{ end_col = #line, hl_group = "OpenCodeInputInfo" }
				)
			end
		end
	end

	local close_keys = { "q", "<Esc>", "<CR>", "<Space>" }
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, function()
			popup:unmount()
		end, { buffer = popup.bufnr, noremap = true, silent = true })
	end

	for i = 32, 126 do
		local char = string.char(i)
		if not char:match("[qQ]") then
			pcall(function()
				vim.keymap.set("n", char, function()
					popup:unmount()
				end, { buffer = popup.bufnr, noremap = true, silent = true, nowait = true })
			end)
		end
	end
end

function M.create()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end

	state.config = get_config()
	setup_session_tabs_refresh_autocmds()
	state.bufnr = create_buffer()
	state.local_notices = {}
	state.stream_blocks = {}
	clear_render_cache()

	local events = require("opencode.events")

	events.on("chat_render", function(data)
		vim.schedule(function()
			M.schedule_render()
		end)
	end)

	events.on("chat_stream_part_updated", function(data)
		vim.schedule(function()
			local part = data and data.part
			if not part or part.type ~= "text" or not part.messageID then
				return
			end
			if not state.visible or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
				return
			end
			if not M.update_stream_text_block(part.messageID, part.id) then
				M.schedule_render()
			end
		end)
	end)

	events.on("local_notice", function(data)
		vim.schedule(function()
			if type(data) ~= "table" then
				return
			end
			M.add_message(data.role or "system", data.content or "", {
				kind = data.kind,
				session_id = data.session_id,
				render = false,
			})
		end)
	end)

	local function has_pending_interaction()
		local current_session = require("opencode.state").get_session()
		local in_child_session_view = #state.session_stack > 0

		local question_ok, question_state_mod = pcall(require, "opencode.question.state")
		if question_ok and question_state_mod.get_all_active then
			for _, qstate in ipairs(question_state_mod.get_all_active()) do
				if widget_support.should_render(qstate.session_id, qstate.status, current_session.id, in_child_session_view) then
					return true
				end
			end
		end

		local perm_ok, perm_state_mod = pcall(require, "opencode.permission.state")
		if perm_ok and perm_state_mod.get_all_active then
			for _, pstate in ipairs(perm_state_mod.get_all_active()) do
				if widget_support.should_render(pstate.session_id, pstate.status, current_session.id, in_child_session_view) then
					return true
				end
			end
		end

		local edit_ok, edit_state_mod = pcall(require, "opencode.edit.state")
		if edit_ok and edit_state_mod.get_all_active then
			for _, estate in ipairs(edit_state_mod.get_all_active()) do
				if widget_support.should_render(estate.session_id, estate.status, current_session.id, in_child_session_view) then
					return true
				end
			end
		end

		return false
	end

	events.on("status_change", function(data)
		vim.schedule(function()
			local new_status = data and data.status
			if new_status == "streaming" or new_status == "thinking" then
				if has_pending_interaction() then
					if spinner.is_active() then
						spinner.stop()
						M.schedule_render()
					end
					stop_spinner_animation_timer()
					return
				end

				if not spinner.is_active() then
					spinner.start()
					M.schedule_render()
				end
				if state.visible then
					start_spinner_animation_timer()
					chat_tasks.start_task_animation_timer()
				end
			else
				if spinner.is_active() then
					spinner.stop()
					M.schedule_render()
				end
				stop_spinner_animation_timer()
				chat_tasks.stop_task_animation_timer()
			end
		end)
	end)

	events.on("session_change", function(data)
		local preserve_cache = data and data.preserve_cache
		local reason = data and data.reason
		local changed_session = data and data.previous_id ~= data.id
		vim.schedule(function()
			if not preserve_cache then
				if spinner.is_active() then
					spinner.stop()
				end
				stop_spinner_animation_timer()
				chat_tasks.stop_task_animation_timer()
			end
			state.questions = {}
			state.permissions = {}
			state.edits = {}
			state.tasks = {}
			state.expanded_tasks = {}
			state.task_child_cache = {}
			state.tools = {}
			state.expanded_tools = {}
			state.stream_blocks = {}
			state.spinner_footer_line = nil
			clear_render_cache()
			if not preserve_cache or (changed_session and reason ~= "child_navigation") then
				state.session_stack = {}
			end
			chat_todos.update_window()
		end)
	end)

	M.do_render()

	return state.bufnr
end

local function request_focus_for_pending_widgets()
	local current_session = require("opencode.state").get_session()
	local in_child_session_view = #state.session_stack > 0
	for _, qstate in ipairs(question_state.get_all()) do
		if
			(qstate.status == "pending" or qstate.status == "confirming")
			and widget_support.should_render(qstate.session_id, qstate.status, current_session.id, in_child_session_view)
		then
			return widget_support.request_focus("question", qstate.request_id, qstate.status)
		end
	end
	for _, pstate in ipairs(permission_state.get_all()) do
		if
			pstate.status == "pending"
			and widget_support.should_render(pstate.session_id, pstate.status, current_session.id, in_child_session_view)
		then
			return widget_support.request_focus("permission", pstate.permission_id, pstate.status)
		end
	end
	for _, estate in ipairs(edit_state.get_all()) do
		if
			estate.status == "pending"
			and widget_support.should_render(estate.session_id, estate.status, current_session.id, in_child_session_view)
		then
			return widget_support.request_focus("edit", estate.permission_id, estate.status)
		end
	end
	return false
end

function M.open()
	if M.is_visible() then
		return
	end
	if state.visible then
		M.close()
	end

	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		M.create()
	end

	local cfg = state.config
	local dims = calculate_dimensions(cfg)

	if cfg.layout == "float" then
		-- Keep the outer frame stable while reserving top space for the fixed tabbar.
		local popup_row = dims.row + math.floor(FLOAT_CHAT_TOP_PADDING / 2)
		local popup_height = math.max(1, dims.height - FLOAT_CHAT_TOP_PADDING)
		local popup = Popup({
			relative = "editor",
			enter = true,
			focusable = true,
			border = {
				style = cfg.float.border,
				text = {
					top = cfg.float.title,
					top_align = cfg.float.title_pos,
				},
				padding = { FLOAT_CHAT_TOP_PADDING, 1, 0, 1 },
			},
			position = {
				relative = "editor",
				row = popup_row,
				col = dims.col,
			},
			size = { width = dims.width, height = popup_height },
			bufnr = state.bufnr,
			win_options = {
				fillchars = "eob: ",
				wrap = true,
				number = false,
				relativenumber = false,
				signcolumn = "no",
				foldcolumn = "0",
			},
		})

		popup:mount()
		state.layout = popup
		state.winid = popup.winid
		state.tabpage = vim.api.nvim_get_current_tabpage()
		setup_chat_window_options(state.winid)
		M.update_winbar()
		if cfg.close_on_focus_lost ~= false then
			setup_float_focus_autocmds()
		end
		state.float_dims = dims

		local popup_winid = popup.winid
		if popup_winid and vim.api.nvim_win_is_valid(popup_winid) then
			vim.api.nvim_create_autocmd("WinClosed", {
				pattern = tostring(popup_winid),
				once = true,
				callback = function()
					if state.winid == popup_winid then
						clear_float_focus_autocmds()
						chat_todos.close_window()
						close_float_session_tabs_window()
						state.visible = false
						state.winid = nil
						state.tabpage = nil
						state.layout = nil
						state.float_dims = nil
						stop_spinner_animation_timer()
						chat_tasks.stop_task_animation_timer()
					end
				end,
			})
		end
	else
		local split_cmd = "split"
		local split_opts = {}

		if cfg.layout == "vertical" then
			split_cmd = cfg.position == "right" and "botright vsplit" or "topleft vsplit"
			split_opts.width = cfg.width
		else
			split_cmd = cfg.position == "bottom" and "botright split" or "topleft split"
			split_opts.height = cfg.height
		end

		vim.cmd(split_cmd)
		state.winid = vim.api.nvim_get_current_win()
		state.tabpage = vim.api.nvim_get_current_tabpage()
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)

		if cfg.layout == "vertical" then
			vim.api.nvim_win_set_width(state.winid, cfg.width)
		else
			vim.api.nvim_win_set_height(state.winid, cfg.height)
		end

		vim.wo[state.winid].winfixwidth = cfg.layout == "vertical"
		vim.wo[state.winid].winfixheight = cfg.layout == "horizontal"
		setup_chat_window_options(state.winid)
		M.update_winbar()
	end

	state.visible = true
	local focused_pending_widget = request_focus_for_pending_widgets()
	M.do_render()
	do
		local ok_state, app_state = pcall(require, "opencode.state")
		if ok_state then
			local status = app_state.get_status()
			if status == "streaming" or status == "thinking" then
				if spinner.is_active() then
					start_spinner_animation_timer()
				end
				chat_tasks.start_task_animation_timer()
			end
		end
	end

	local line_count = vim.api.nvim_buf_line_count(state.bufnr)
	if line_count > 0 and not focused_pending_widget then
		vim.api.nvim_win_set_cursor(state.winid or 0, { line_count, 0 })
	end
end

function M.close()
	if not state.visible then
		chat_todos.close_window()
		close_float_session_tabs_window()
		return
	end

	clear_float_focus_autocmds()
	chat_todos.close_window()
	close_float_session_tabs_window()

	if input.is_visible() then
		input.close()
	end

	if state.config.layout == "float" and state.layout then
		state.layout:unmount()
	else
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			vim.api.nvim_win_close(state.winid, true)
		end
	end

	state.visible = false
	state.winid = nil
	state.tabpage = nil
	state.layout = nil
	state.float_dims = nil
	stop_spinner_animation_timer()
	chat_tasks.stop_task_animation_timer()
end

function M.toggle()
	if M.is_visible() then
		M.close()
	else
		M.open()
	end
end

function M.is_visible()
	return state.visible
		and state.winid
		and vim.api.nvim_win_is_valid(state.winid)
		and (not state.tabpage or state.tabpage == vim.api.nvim_get_current_tabpage())
end

function M.get_winid()
	if M.is_visible() and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		return state.winid
	end
	return nil
end

function M.get_float_dims()
	if not M.is_visible() or not state.float_dims then
		return nil
	end
	return vim.deepcopy(state.float_dims)
end

function M.get_bufnr()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		M.create()
	end
	return state.bufnr
end

function M.focus()
	if not M.is_visible() then
		M.open()
	end
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_set_current_win(state.winid)
	end
end

function M.focus_input()
	if not state.visible then
		M.open()
	end
	M.focus()

	input.show({
		winid = state.winid,
		float_dims = state.float_dims,
		on_send = function(text, parts)
			local actions = require("opencode.actions")
			local slash_ok, slash = pcall(require, "opencode.slash")
			local has_parts = type(parts) == "table" and #parts > 0
			if not has_parts and slash_ok and type(slash.parse) == "function" and type(slash.execute) == "function" then
				local parsed = slash.parse(text)
				if parsed then
					slash.execute(parsed)
					return
				end
			end
			actions.send(text, { parts = parts })
		end,
		on_cancel = function()
			M.focus()
		end,
	})
end

function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", get_config(), opts or {})
end

-- ─── Legacy message API ───────────────────────────────────────────────────────

---@param role string
---@param content string
---@param opts? table
function M.add_message(role, content, opts)
	opts = opts or {}

	local message = {
		role = role,
		content = content,
		timestamp = opts.timestamp or os.time(),
		id = opts.id or tostring(os.time()) .. "_" .. #state.local_notices,
		session_id = opts.session_id,
		agent = opts.agent,
		kind = opts.kind,
		optimistic = opts.optimistic,
		tool_calls = opts.tool_calls,
	}

	table.insert(state.local_notices, message)
	if opts.render == false then
		M.schedule_render()
	else
		M.render_message(message)
	end
	return message.id
end

function M.render_message(message)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local lines = {}
	local highlights = {}

	if
		message.role == "assistant"
		and (not message.content or message.content == "")
		and (not message.reasoning or message.reasoning == "")
	then
		return
	end

	local role_display = message.role == "user" and "You" or (message.role == "assistant" and "Assistant" or "System")
	local time_str = os.date("%H:%M", message.timestamp)
	local id_display = message.id or "??????"
	local header_padding = string.rep(" ", math.max(1, 50 - #role_display - #time_str - #id_display - 3))
	local header_text = string.format(
		"%s [%s] %s%s",
		role_display,
		id_display,
		header_padding,
		time_str
	)
	table.insert(lines, header_text)
	table.insert(highlights, {
		line = #lines - 1,
		col_start = 0,
		col_end = #role_display,
		hl_group = message.role == "user" and "Identifier" or "Constant",
	})

	table.insert(lines, string.rep("─", 60))

	local content_lines = vim.split(message.content or "", "\n", { plain = true })
	for _, line in ipairs(content_lines) do
		table.insert(lines, line)
	end

	table.insert(lines, "")

	vim.bo[state.bufnr].modifiable = true
	local line_count = vim.api.nvim_buf_line_count(state.bufnr)
	vim.api.nvim_buf_set_lines(state.bufnr, line_count, line_count, false, lines)

	for _, hl in ipairs(highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(state.bufnr, line_count + hl.line, line_count + hl.line + 1, false)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(
			state.bufnr,
			chat_hl_ns,
			line_count + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	if state.auto_scroll and state.visible and state.winid then
		local cursor = vim.api.nvim_win_get_cursor(state.winid)
		local win_height = vim.api.nvim_win_get_height(state.winid)
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		if cursor[1] >= buf_lines - win_height - 1 then
			vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
		end
	end
end

function M.clear()
	chat_todos.close_window()
	state.local_notices = {}
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.tasks = {}
	state.expanded_tasks = {}
	state.task_child_cache = {}
	state.tools = {}
	state.expanded_tools = {}
	state.stream_blocks = {}
	state.spinner_footer_line = nil
	state.last_render_time = 0
	state.render_scheduled = false
	clear_render_cache()

	if spinner.is_active() then
		spinner.stop()
	end
	stop_spinner_animation_timer()
	chat_tasks.stop_task_animation_timer()
	state.task_anim_frame = 1

	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
		vim.bo[state.bufnr].modifiable = false
	end

	local ok, qs = pcall(require, "opencode.question.state")
	if ok then
		for _, request_id in ipairs(qs.clear_all() or {}) do
			emit("question_removed", { request_id = request_id })
		end
	end
	local ok2, ps = pcall(require, "opencode.permission.state")
	if ok2 then
		for _, permission_id in ipairs(ps.clear_all() or {}) do
			emit("permission_removed", { permission_id = permission_id })
		end
	end
	local ok3, es = pcall(require, "opencode.edit.state")
	if ok3 then
		for _, permission_id in ipairs(es.clear_all() or {}) do
			emit("edit_removed", { permission_id = permission_id })
		end
	end
end

---@param session_id string|nil
function M.clear_session_view(session_id)
	state.local_notices = vim.tbl_filter(function(message)
		if not session_id or session_id == "" then
			return false
		end
		return message.session_id and message.session_id ~= session_id
	end, state.local_notices or {})

	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.tasks = {}
	state.expanded_tasks = {}
	state.task_child_cache = {}
	state.tools = {}
	state.expanded_tools = {}
	state.stream_blocks = {}
	state.spinner_footer_line = nil
	state.last_render_time = 0
	state.render_scheduled = false
	clear_render_cache()

	M.schedule_render()
end

function M.get_messages()
	return vim.deepcopy(state.local_notices)
end

function M.load_messages(messages)
	if not messages or #messages == 0 then
		return
	end
	local sync = require("opencode.sync")
	for _, msg in ipairs(messages) do
		local role = msg.role or "assistant"
		local content = ""
		if msg.parts then
			local texts = {}
			for _, part in ipairs(msg.parts) do
				if part.type == "text" and part.text then
					table.insert(texts, part.text)
				end
			end
			content = table.concat(texts, "\n")
		else
			content = sync.get_message_text(msg.id)
		end
		M.add_message(role, content, {
			id = msg.id,
			timestamp = msg.time and msg.time.created or os.time(),
		})
	end
end

-- Legacy tool call API (no-op wrappers kept for backward compat)
function M.add_tool_call(tool_name, args, opts)
	opts = opts or {}
	local tool_call = {
		name = tool_name,
		args = vim.json.encode(args),
		status = opts.status or "pending",
		result = opts.result,
		timestamp = os.time(),
	}
	local content = string.format("```tool-call\n%s\n```", vim.json.encode(tool_call))
	return M.add_message("system", content, { tool_calls = { tool_call } })
end

function M.update_tool_call(message_id, tool_index, status, result)
	M.schedule_render()
	return true
end

function M.update_tool_activity(message_id, tool_name, status, input)
	M.schedule_render()
end

function M.clear_tool_activity(message_id) end

-- ─── Line tracking ────────────────────────────────────────────────────────────

local function shift_tracked_lines(old_end, delta, skip_stream_message_id)
	widget_support.shift_tracked_lines(old_end, delta, {
		skip_stream_message_id = skip_stream_message_id,
	})
end

function M.update_stream_text_block(message_id, part_id)
	if not message_id then
		return false
	end
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end

	local block = state.stream_blocks[message_id]
	if not block then
		return false
	end
	if block.part_id and part_id and block.part_id ~= part_id then
		return false
	end

	local widget_cursor = capture_widget_cursor_context()

	local sync = require("opencode.sync")
	local part = block.part_id and sync.get_part(message_id, block.part_id) or nil
	local content = (part and part.text) or sync.get_message_text(message_id)
	local content_lines = render.render_content(content, { stream_plain = true })
	if #content_lines == 0 then
		local empty = NuiLine()
		empty:append("")
		content_lines = { empty }
	end
	local replacement = render.extract_lines(content_lines)

	local should_scroll = should_auto_scroll(widget_cursor)

	local old_end = block.end_line
	local old_count = old_end - block.start_line + 1
	local new_count = #replacement
	local delta = new_count - old_count

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, block.start_line, old_end + 1, false, replacement)

	local clear_end = math.max(old_end + 1, block.start_line + new_count)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, block.start_line, clear_end)
	render.apply_highlights(content_lines, state.bufnr, chat_hl_ns, block.start_line)
	vim.bo[state.bufnr].modifiable = false

	block.end_line = block.start_line + new_count - 1
	shift_tracked_lines(old_end, delta, message_id)

	if apply_widget_focus_cursor and apply_widget_focus_cursor() then
		vim.cmd("redraw")
		return true
	end

	if restore_widget_cursor_context(widget_cursor) then
		vim.cmd("redraw")
		return true
	end

	if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
	end

	vim.cmd("redraw")
	return true
end

-- ─── Main render ─────────────────────────────────────────────────────────────

---Build full buffer content using NuiLine components.
---@return string[] raw_lines, NuiLine[] nui_lines, table[] content_highlights
function M.render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return {}, {}, {}
	end

	local sync = require("opencode.sync")
	local app_state = require("opencode.state")
	local current_session = app_state.get_session()
	local in_child_session_view = #state.session_stack > 0

	local nui_lines = {}
	local raw_lines = {}
	local content_highlights = {}
	local last_block_kind = nil -- "tool" | "non_tool"
	local chat_width = render.get_chat_text_width()

	local function cached_nui_lines(key, build)
		local cached = key and render_cache_get(key)
		if cached and cached.nui_lines then
			return cached.nui_lines
		end
		local lines = build()
		if key then
			render_cache_put(key, { nui_lines = lines })
		end
		return lines
	end

	local function cached_render_result(key, build)
		local cached = key and render_cache_get(key)
		if cached and cached.result then
			return cached.result
		end
		local result = build()
		if key then
			render_cache_put(key, { result = result })
		end
		return result
	end

	local function push_line(text, nui_line)
		local safe_text = render.sanitize_buffer_line(text)
		if safe_text ~= text then
			nui_line = NuiLine()
			nui_line:append(safe_text)
			text = safe_text
		end
		table.insert(nui_lines, nui_line)
		table.insert(raw_lines, text)
	end

	local function ensure_single_blank_separator()
		while #raw_lines > 0 and raw_lines[#raw_lines] == "" do
			table.remove(raw_lines)
			table.remove(nui_lines)
		end
		local line = NuiLine()
		line:append("")
		push_line("", line)
	end

	local function normalize_block_transition(next_kind)
		if not next_kind or next_kind == "blank" then
			return
		end
		if last_block_kind and last_block_kind ~= next_kind then
			ensure_single_blank_separator()
		end
		last_block_kind = next_kind
	end

	local function add_line(nui_line, kind)
		local text = nui_line:content()
		local line_kind = kind or (text == "" and "blank" or "non_tool")
		normalize_block_transition(line_kind)
		push_line(text, nui_line)
	end

	local function add_raw_line(text, kind)
		local line = NuiLine()
		line:append(text)
		local line_kind = kind or (text == "" and "blank" or "non_tool")
		normalize_block_transition(line_kind)
		push_line(text, line)
	end

	local function append_relative_highlights(highlights, base_line)
		if type(highlights) ~= "table" or type(base_line) ~= "number" then
			return
		end
		for _, hl in ipairs(highlights) do
			if type(hl) == "table" then
				table.insert(content_highlights, vim.tbl_extend("force", {}, hl, {
					line = base_line + (hl.line or 0),
					end_line = hl.end_line and (base_line + hl.end_line) or nil,
				}))
			end
		end
	end

	local function add_nui_lines(lines, kind)
		local base_line = nil
		for _, nl in ipairs(lines) do
			add_line(nl, kind)
			if base_line == nil then
				base_line = #raw_lines - 1
			end
		end
		append_relative_highlights(lines._opencode_highlights, base_line)
	end

	---@return number
	local function prepare_widget_start()
		normalize_block_transition("non_tool")
		return #raw_lines
	end

	---@param owner_session_id string|nil
	---@param widget_status string|nil
	---@return boolean
	local function should_render_session_widget(owner_session_id, widget_status)
		return widget_support.should_render(owner_session_id, widget_status, current_session.id, in_child_session_view)
	end

	---@param kind string
	---@param widget_id string
	---@param widget_start number
	---@param meta OpenCodeWidgetMeta|nil
	local function capture_widget_focus(kind, widget_id, widget_start, meta)
		local focus_offset = widget_base.get_focus_offset(meta)
		if focus_offset == nil then
			return
		end

		widget_support.capture_focus_line(kind, widget_id, widget_start + focus_offset + 1)
	end

	-- Reset position-tracking tables: render() always fully rebuilds them from
	-- scratch, so any stale entries from a previous frame (e.g. a subagent edit
	-- that is now suppressed) must be cleared.  Without this, a removed widget's
	-- old line-range can match the cursor and incorrectly re-trigger rerender_edit.
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.tasks = {}
	state.tools = {}

	local rendered_question_ids = {}
	local rendered_perm_ids = {}
	local rendered_edit_ids = {}
	local next_stream_blocks = {}
	state.spinner_footer_line = nil
	local widget_order = {
		question = 1,
		permission = 2,
		edit = 3,
	}

	local function render_single_question(qstate)
		if not qstate then
			return
		end
		local request_id = qstate.request_id
		local q_lines, q_highlights, q_meta
		local q_start_line
		local status = qstate.status or "pending"
		local owner_session_id = qstate.session_id

		if not should_render_session_widget(owner_session_id, status) then
			return
		end

		if status == "answered" then
			q_lines, q_highlights = question_widget.get_answered_lines(
				request_id,
				{ questions = qstate.questions, timestamp = qstate.timestamp },
				qstate.answers
			)
			q_meta = widget_base.make_meta()
		elseif status == "rejected" then
			q_lines, q_highlights = question_widget.get_rejected_lines(request_id, {
				questions = qstate.questions,
				timestamp = qstate.timestamp,
			})
			q_meta = widget_base.make_meta()
		else
			q_lines, q_highlights, q_meta =
				question_widget.get_lines_for_question(request_id, { questions = qstate.questions }, qstate, status)
		end

		q_start_line = prepare_widget_start()
		capture_widget_focus("question", request_id, q_start_line, q_meta)

		for _, line_text in ipairs(q_lines) do
			add_raw_line(line_text)
		end

		state.questions[request_id] = {
			start_line = q_start_line,
			end_line = q_start_line + #q_lines - 1,
			status = status,
			highlights = q_highlights,
		}

		add_raw_line("")
	end

	local function render_single_permission(pstate)
		local perm_id = pstate.permission_id
		local pstatus = pstate.status or "pending"
		local p_lines, p_highlights, p_meta

		if pstatus == "approved" then
			p_lines, p_highlights = permission_widget.get_approved_lines(perm_id, pstate)
			p_meta = widget_base.make_meta()
		elseif pstatus == "rejected" then
			p_lines, p_highlights = permission_widget.get_rejected_lines(perm_id, pstate)
			p_meta = widget_base.make_meta()
		else
			p_lines, p_highlights, p_meta = permission_widget.get_lines_for_permission(perm_id, pstate)
		end

		if p_lines then
			local perm_start = prepare_widget_start()
			capture_widget_focus("permission", perm_id, perm_start, p_meta)
			for _, line_text in ipairs(p_lines) do
				add_raw_line(line_text)
			end
			state.permissions[perm_id] = {
				start_line = perm_start,
				end_line = perm_start + #p_lines - 1,
				status = pstatus,
				highlights = p_highlights,
			}
			add_raw_line("")
		end
	end

	local function render_single_edit(estate)
		local eid = estate.permission_id
		local estatus = estate.status or "pending"
		local e_lines, e_highlights, e_meta

		if estatus == "sent" then
			e_lines, e_highlights = edit_widget.get_resolved_lines(eid, estate)
			e_meta = widget_base.make_meta()
		else
			e_lines, e_highlights, e_meta = edit_widget.get_lines_for_edit(eid, estate)
		end

		if e_lines then
			local edit_start = prepare_widget_start()
			capture_widget_focus("edit", eid, edit_start, e_meta)
			for _, line_text in ipairs(e_lines) do
				add_raw_line(line_text)
			end
			state.edits[eid] = {
				start_line = edit_start,
				end_line = edit_start + #e_lines - 1,
				status = estatus,
				highlights = e_highlights,
				meta = e_meta,
			}
			add_raw_line("")
		end
	end

	---@param widget_items table
	local function render_widget_items(widget_items)
		table.sort(widget_items, function(a, b)
			if a.timestamp ~= b.timestamp then
				return a.timestamp < b.timestamp
			end

			local a_order = widget_order[a.kind] or 99
			local b_order = widget_order[b.kind] or 99
			if a_order ~= b_order then
				return a_order < b_order
			end

			return tostring(a.id or "") < tostring(b.id or "")
		end)

		for _, item in ipairs(widget_items) do
			if item.kind == "question" then
				rendered_question_ids[item.id] = true
				render_single_question(item.data)
			elseif item.kind == "permission" then
				rendered_perm_ids[item.id] = true
				if should_render_session_widget(item.data.session_id, item.data.status) then
					render_single_permission(item.data)
				end
			elseif item.kind == "edit" then
				rendered_edit_ids[item.id] = true
				if should_render_session_widget(item.data.session_id, item.data.status) then
					render_single_edit(item.data)
				end
			end
		end
	end

	local function render_widgets_for_message(message_id)
		local widget_items = {}

		for _, qstate in ipairs(question_state.get_questions_for_message(message_id)) do
			if not rendered_question_ids[qstate.request_id] then
				table.insert(widget_items, {
					kind = "question",
					id = qstate.request_id,
					timestamp = qstate.timestamp or 0,
					data = qstate,
				})
			end
		end

		local perms = permission_state.get_permissions_for_message(message_id)
		for _, pstate in ipairs(perms) do
			if not pstate.call_id then
				table.insert(widget_items, {
					kind = "permission",
					id = pstate.permission_id,
					timestamp = pstate.timestamp or 0,
					data = pstate,
				})
			end
		end

		local edits = edit_state.get_edits_for_message(message_id)
		for _, estate in ipairs(edits) do
			if not estate.call_id then
				table.insert(widget_items, {
					kind = "edit",
					id = estate.permission_id,
					timestamp = estate.timestamp or 0,
					data = estate,
				})
			end
		end

		render_widget_items(widget_items)
	end

	local function has_question_widget_for_tool_call(message_id, call_id)
		for _, qstate in ipairs(question_state.get_questions_for_message(message_id)) do
			if
				(not qstate.call_id or qstate.call_id == call_id)
				and should_render_session_widget(qstate.session_id, qstate.status)
			then
				return true
			end
		end

		if type(call_id) ~= "string" or call_id == "" then
			return false
		end

		for _, qstate in ipairs(question_state.get_all()) do
			if
				not qstate.message_id
				and qstate.call_id == call_id
				and qstate.session_id == current_session.id
				and should_render_session_widget(qstate.session_id, qstate.status)
			then
				return true
			end
		end

		return false
	end

	local function has_edit_widget_for_tool_call(message_id, call_id)
		for _, estate in ipairs(edit_state.get_edits_for_message(message_id)) do
			if
				(not estate.call_id or estate.call_id == call_id)
				and should_render_session_widget(estate.session_id, estate.status)
			then
				return true
			end
		end

		if type(call_id) ~= "string" or call_id == "" then
			return false
		end

		for _, estate in ipairs(edit_state.get_all()) do
			if
				not estate.message_id
				and estate.call_id == call_id
				and estate.session_id == current_session.id
				and should_render_session_widget(estate.session_id, estate.status)
			then
				return true
			end
		end

		return false
	end

	local function render_widgets_for_tool_call(message_id, call_id)
		if type(call_id) ~= "string" or call_id == "" then
			return
		end

		local widget_items = {}

		for _, qstate in ipairs(question_state.get_questions_for_message(message_id)) do
			if qstate.call_id == call_id then
				table.insert(widget_items, {
					kind = "question",
					id = qstate.request_id,
					timestamp = qstate.timestamp or 0,
					data = qstate,
				})
			end
		end

		for _, qstate in ipairs(question_state.get_all()) do
			if
				not qstate.message_id
				and qstate.call_id == call_id
				and qstate.session_id == current_session.id
				and not rendered_question_ids[qstate.request_id]
			then
				table.insert(widget_items, {
					kind = "question",
					id = qstate.request_id,
					timestamp = qstate.timestamp or 0,
					data = qstate,
				})
			end
		end

		local perms = permission_state.get_permissions_for_message(message_id)
		for _, pstate in ipairs(perms) do
			if pstate.call_id == call_id then
				table.insert(widget_items, {
					kind = "permission",
					id = pstate.permission_id,
					timestamp = pstate.timestamp or 0,
					data = pstate,
				})
			end
		end

		for _, pstate in ipairs(permission_state.get_all()) do
			if
				not pstate.message_id
				and pstate.call_id == call_id
				and pstate.session_id == current_session.id
				and not rendered_perm_ids[pstate.permission_id]
			then
				table.insert(widget_items, {
					kind = "permission",
					id = pstate.permission_id,
					timestamp = pstate.timestamp or 0,
					data = pstate,
				})
			end
		end

		local edits = edit_state.get_edits_for_message(message_id)
		for _, estate in ipairs(edits) do
			if estate.call_id == call_id then
				table.insert(widget_items, {
					kind = "edit",
					id = estate.permission_id,
					timestamp = estate.timestamp or 0,
					data = estate,
				})
			end
		end

		for _, estate in ipairs(edit_state.get_all()) do
			if
				not estate.message_id
				and estate.call_id == call_id
				and estate.session_id == current_session.id
				and not rendered_edit_ids[estate.permission_id]
			then
				table.insert(widget_items, {
					kind = "edit",
					id = estate.permission_id,
					timestamp = estate.timestamp or 0,
					data = estate,
				})
			end
		end

		render_widget_items(widget_items)
	end

	---@param result table
	---@param kind string
	---@return number base_line
	local function add_render_result(result, kind)
		-- Block transitions can insert a separator; highlights must start after it.
		normalize_block_transition(kind)
		local base_line = #raw_lines
		for _, text in ipairs(result.lines or {}) do
			local nl = NuiLine()
			nl:append(text)
			push_line(text, nl)
		end
		return base_line
	end

	---@param tool_part table
	local function render_tool_part(tool_part)
		if tool_part.tool == "task" then
			local is_expanded = state.expanded_tasks[tool_part.id] or false
			local cached = state.task_child_cache[tool_part.id]
			local cache_key = nil
			if not is_expanded and not chat_tasks.is_animating_tool_part(tool_part) then
				cache_key = render_cache_key(
					"task",
					current_session.id,
					tool_part.messageID,
					tool_part.id,
					sync.get_message_revision(tool_part.messageID),
					sync.get_part_revision(tool_part.messageID, tool_part.id),
					chat_width,
					is_expanded
				)
			end
			local result = cached_render_result(cache_key, function()
				return chat_tasks.render_task_tool(tool_part, is_expanded, cached)
			end)
			local base_line = add_render_result(result, "tool")
			state.tasks[tool_part.id] = {
				start_line = base_line,
				end_line = base_line + #result.lines - 1,
				tool_part = tool_part,
				highlights = result.highlights,
			}
			return
		end

		local is_expanded = state.expanded_tools[tool_part.id] or false
		local cache_key = nil
		if not chat_tasks.is_animating_tool_part(tool_part) then
			cache_key = render_cache_key(
				"tool",
				current_session.id,
				tool_part.messageID,
				tool_part.id,
				sync.get_message_revision(tool_part.messageID),
				sync.get_part_revision(tool_part.messageID, tool_part.id),
				chat_width,
				is_expanded
			)
		end
		local result = cached_render_result(cache_key, function()
			return chat_tasks.render_regular_tool(tool_part, is_expanded)
		end)
		local base_line = add_render_result(result, "tool")
		state.tools[tool_part.id] = {
			start_line = base_line,
			end_line = base_line + #result.lines - 1,
			tool_part = tool_part,
			highlights = result.highlights,
		}
	end

	local chat_config = state.config or get_config()
	local tabs_cfg = chat_config.session_tabs or {}

	-- Breadcrumb navigation (when inside a child session)
	if #state.session_stack > 0 then
		local bc_line = NuiLine()
		for i, entry in ipairs(state.session_stack) do
			if i > 1 then
				bc_line:append(NuiText(" > ", "Comment"))
			end
			bc_line:append(NuiText(entry.name, "Comment"))
		end
		bc_line:append(NuiText(" > ", "Comment"))
		bc_line:append(NuiText(current_session.name or "Subagent", "Special"))
		add_line(bc_line)

		local hint_line = NuiLine()
		hint_line:append(NuiText("<BS> Go back", "Comment"))
		add_line(hint_line)
		add_raw_line("")
	end

	-- Session header is kept for child views and for users who disable fixed tabs.
	if tabs_cfg.enabled == false or in_child_session_view then
		ensure_session_title_highlight()
		local session_name = current_session.name or "New session"
		local header = NuiLine()
		header:append(NuiText(session_name, "OpenCodeSessionTitle"))
		add_line(header)
		add_raw_line("")
	end

	local messages = current_session.id and sync.get_messages(current_session.id) or {}
	local spinner_active = spinner.is_active()
	local spinner_footer_rendered = false

	local last_assistant_idx = nil
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" then
			last_assistant_idx = i
			break
		end
	end

	for msg_idx, message in ipairs(messages) do
		local content = sync.get_message_text(message.id, message.role == "user" and { include_synthetic = false } or nil)
		local reasoning = sync.get_message_reasoning(message.id)
		local tool_parts = sync.get_message_tools(message.id)
		local parts = sync.get_parts(message.id)
		local incomplete_assistant = message.role == "assistant" and not (message.time and message.time.completed)
		local render_as_plain_stream = app_state.get_status() == "streaming" and incomplete_assistant

		local has_content = content and content ~= ""
		local has_reasoning = reasoning and reasoning ~= ""
		local has_tools = #tool_parts > 0
		local is_last_assistant = (msg_idx == last_assistant_idx)
		local force_processing_render = spinner_active and is_last_assistant and incomplete_assistant
		local should_render = message.role ~= "assistant"
			or has_content
			or has_reasoning
			or has_tools
			or force_processing_render

		if should_render then
			if message.role == "user" then
				local file_parts = {}
				for _, part in ipairs(parts or {}) do
					if
						part.type == "file"
						and not part.synthetic
						and part.mime ~= "text/plain"
						and part.mime ~= "application/x-directory"
					then
						table.insert(file_parts, part)
					end
				end
				local msg_lines = cached_nui_lines(
					render_cache_key(
						"user",
						current_session.id,
						message.id,
						sync.get_message_revision(message.id),
						chat_width,
						message.agent or ""
					),
					function()
						return render.render_user_message(content, message.agent, file_parts)
					end
				)
				for _, nl in ipairs(msg_lines) do
					add_line(nl)
				end

				local session_status = current_session.id and sync.get_session_status(current_session.id)
				if session_status and session_status.type == "retry" then
					local is_last_user = true
					for j = msg_idx + 1, #messages do
						if messages[j].role == "user" then
							is_last_user = false
							break
						end
					end
					if is_last_user then
						local retry_msg = session_status.message or "Retrying..."
						if #retry_msg > 80 then
							retry_msg = retry_msg:sub(1, 80) .. "..."
						end
						local attempt = session_status.attempt or 0
						local retry_info = ""
						if session_status.next then
							local wait_sec = math.max(0, math.floor((session_status.next - os.time() * 1000) / 1000))
							if wait_sec > 0 then
								retry_info = string.format(" [retrying in %ds attempt #%d]", wait_sec, attempt)
							else
								retry_info = string.format(" [retrying attempt #%d]", attempt)
							end
						else
							retry_info = string.format(" [attempt #%d]", attempt)
						end
						local status_text = retry_msg .. retry_info
						local status_line = NuiLine()
						status_line:append(NuiText(status_text, "ErrorMsg"))
						add_line(status_line)
					end
				end

				add_raw_line("")
			else
				-- Assistant message
				for part_idx, part in ipairs(parts) do
					if part.type == "reasoning" and part.text and part.text ~= "" and thinking.is_enabled() then
						local cache_key = nil
						if not incomplete_assistant then
							cache_key = render_cache_key(
								"reasoning",
								current_session.id,
								message.id,
								part.id or part_idx,
								sync.get_message_revision(message.id),
								sync.get_part_revision(message.id, part.id),
								chat_width
							)
						end
						local reasoning_lines = cached_nui_lines(cache_key, function()
							return render.render_reasoning(part.text)
						end)
						for _, nl in ipairs(reasoning_lines) do
							add_line(nl)
						end
					elseif part.type == "text" and part.text and part.text ~= "" then
						local content_start = #raw_lines
						local cache_key = nil
						if not incomplete_assistant then
							cache_key = render_cache_key(
								"text",
								current_session.id,
								message.id,
								part.id or part_idx,
								sync.get_message_revision(message.id),
								sync.get_part_revision(message.id, part.id),
								chat_width,
								render_as_plain_stream
							)
						end
						local content_lines = cached_nui_lines(cache_key, function()
							return render.render_content(part.text, { stream_plain = render_as_plain_stream })
						end)
						add_nui_lines(content_lines)
						if incomplete_assistant and #content_lines > 0 then
							next_stream_blocks[message.id] = {
								start_line = content_start,
								end_line = #raw_lines - 1,
								part_id = part.id,
							}
						end
					elseif part.type == "tool" then
						local skip_tool_row = false
						if part.tool == "question" then
							skip_tool_row = has_question_widget_for_tool_call(message.id, part.callID)
						elseif EDIT_WIDGET_TOOL_ROWS[part.tool] then
							skip_tool_row = has_edit_widget_for_tool_call(message.id, part.callID)
						end
						if not skip_tool_row then
							render_tool_part(part)
						end
						render_widgets_for_tool_call(message.id, part.callID)
					end
				end

				render_widgets_for_message(message.id)

				if force_processing_render or render.should_show_footer(message, is_last_assistant) then
					ensure_single_blank_separator()
					local footer_line_idx = #raw_lines
					local show_spinner = spinner_active and is_last_assistant and incomplete_assistant
					add_line(render.render_metadata_footer(message, messages, {
						spinner_frame = show_spinner and spinner.get_frame() or nil,
					}))
					if show_spinner then
						state.spinner_footer_line = footer_line_idx
						spinner_footer_rendered = true
					end
					add_raw_line("")
				end
			end
		end
	end

	local function has_server_user_echo(local_message)
		if local_message.role ~= "user" or type(local_message.content) ~= "string" then
			return false
		end
		local local_ms = (local_message.timestamp or 0) * 1000
		for _, synced in ipairs(messages) do
			local created = synced.time and synced.time.created
			local same_turn = not created or local_ms == 0 or created >= local_ms - 5000
			if
				synced.role == "user"
				and same_turn
				and sync.get_message_text(synced.id, { include_synthetic = false }) == local_message.content
			then
				return true
			end
		end
		return false
	end

	-- Local notices (legacy user/system notices not backed by server state)
	for _, message in ipairs(state.local_notices) do
		if message.session_id and current_session.id and message.session_id ~= current_session.id then
			goto continue_local_message
		end
		if message.id and current_session.id then
			local sync_msg = sync.get_message(current_session.id, message.id)
			if sync_msg then
				goto continue_local_message
			end
		end

		if message.role == "user" then
			if message.optimistic then
				goto continue_local_message
			end
			if has_server_user_echo(message) then
				goto continue_local_message
			end
			local msg_lines = render.render_user_message(message.content or "", message.agent)
			for _, nl in ipairs(msg_lines) do
				add_line(nl)
			end
			add_raw_line("")
			goto continue_local_message
		end

		local has_content = message.content and message.content ~= ""
		if has_content then
			if message.kind == "session_error" then
				ensure_session_error_highlights()
				local result = { lines = {}, highlights = {} }
				render.add_panel_line(result, message.content, "OpenCodeSessionError", {
					prefix_hl_group = "OpenCodeSessionErrorBorder",
				})
				local base_line = add_render_result(result, "non_tool")
				append_relative_highlights(result.highlights, base_line)
			else
				local content_lines = render.render_content(message.content)
				add_nui_lines(content_lines)
			end
			add_raw_line("")
		end
		::continue_local_message::
	end

	local session_msg_ids = {}
	for _, message in ipairs(messages) do
		session_msg_ids[message.id] = true
	end

	for _, qstate in ipairs(question_state.get_all()) do
		if
			not rendered_question_ids[qstate.request_id]
			and not (qstate.message_id and session_msg_ids[qstate.message_id])
			and should_render_session_widget(qstate.session_id, qstate.status)
		then
			render_single_question(qstate)
		end
	end

	-- Orphan permissions from other sessions:
	-- parent view shows cross-session widgets only while pending;
	-- child view shows current-session widgets only.
	local all_perms = permission_state.get_all()
	for _, pstate in ipairs(all_perms) do
		if
			not rendered_perm_ids[pstate.permission_id]
			and not (pstate.message_id and session_msg_ids[pstate.message_id])
			and should_render_session_widget(pstate.session_id, pstate.status)
		then
			render_single_permission(pstate)
		end
	end

	-- Orphan edits from other sessions:
	-- parent view shows cross-session widgets only while pending;
	-- child view shows current-session widgets only.
	local all_edits = edit_state.get_all()
	for _, estate in ipairs(all_edits) do
		local not_already_rendered = not rendered_edit_ids[estate.permission_id]
		local not_inline = not (estate.message_id and session_msg_ids[estate.message_id])
		if not_already_rendered and not_inline and should_render_session_widget(estate.session_id, estate.status) then
			render_single_edit(estate)
		end
	end

	if spinner_active and not spinner_footer_rendered then
		local app_agent = app_state.get_agent() or {}
		local app_model = app_state.get_model() or {}
		local fallback_agent = app_agent.name or app_agent.id or "assistant"
		local fallback_model_id = app_model.id
		local fallback_provider_id = app_model.provider
		local local_ok, local_state = pcall(require, "opencode.local")
		if local_ok then
			local current_agent = local_state.agent.current()
			local current_model = local_state.model.current()
			if current_agent and current_agent.name then
				fallback_agent = current_agent.name
			end
			if current_model then
				fallback_model_id = current_model.modelID
				fallback_provider_id = current_model.providerID
			end
		end
		local fallback_message = {
			role = "assistant",
			agent = fallback_agent,
			mode = fallback_agent,
			modelID = fallback_model_id,
			providerID = fallback_provider_id,
		}

		ensure_single_blank_separator()
		local footer_line_idx = #raw_lines
		add_line(render.render_metadata_footer(fallback_message, messages, {
			spinner_frame = spinner.get_frame(),
		}))
		state.spinner_footer_line = footer_line_idx
		add_raw_line("")
	end

	-- Empty state
	if #raw_lines == 0 then
		if not current_session.id then
			add_raw_line(" No active session")
		end
		add_raw_line(" Press 'i' to focus input")
		add_raw_line(" Press '<C-p>' for command palette")
		add_raw_line(" Press '?' for help")
		add_raw_line("")
	end

	state.stream_blocks = next_stream_blocks
	return raw_lines, nui_lines, content_highlights
end

-- ─── Render engine ────────────────────────────────────────────────────────────

function M.update_spinner_only()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end
	if not state.visible then
		return
	end
	if not spinner.is_active() then
		return
	end

	local footer_line = state.spinner_footer_line
	if type(footer_line) ~= "number" then
		return
	end

	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	if footer_line < 0 or footer_line >= buf_lines then
		return
	end

	local current_line = vim.api.nvim_buf_get_lines(state.bufnr, footer_line, footer_line + 1, false)[1] or ""
	if current_line == "" then
		return
	end

	local second_char = vim.fn.strcharpart(current_line, 1, 1)
	if second_char ~= " " then
		return
	end

	local next_frame = spinner.get_frame()
	if next_frame == "" then
		return
	end

	local current_frame = vim.fn.strcharpart(current_line, 0, 1)
	if current_frame == next_frame then
		return
	end

	local current_frame_bytes = #current_frame
	if current_frame_bytes <= 0 then
		return
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_text(state.bufnr, footer_line, 0, footer_line, current_frame_bytes, { next_frame })
	vim.bo[state.bufnr].modifiable = false
end

local RENDER_THROTTLE_MS = 16

function M.schedule_render()
	if state.render_scheduled then
		return
	end

	local now = vim.uv.now()
	local elapsed = now - state.last_render_time

	if elapsed >= RENDER_THROTTLE_MS then
		state.last_render_time = now
		M.do_render()
	else
		state.render_scheduled = true
		vim.defer_fn(function()
			state.render_scheduled = false
			state.last_render_time = vim.uv.now()
			M.do_render()
		end, RENDER_THROTTLE_MS - elapsed)
	end
end

---@return string|nil
apply_widget_focus_cursor = function()
	local focused_kind = widget_support.apply_focus_cursor()
	if focused_kind then
		M.sync_widget_selection_from_cursor()
	end
	return focused_kind
end

function M.do_render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end
	M.update_winbar()

	local widget_cursor = capture_widget_cursor_context()
	local should_scroll = should_auto_scroll(widget_cursor)

	local new_lines, nui_lines, content_highlights = M.render()
	chat_todos.update_window()
	resume_render_animation_timers()
	local highlight_signature = render_highlight_signature(content_highlights)

	local function apply_render_highlights(changed_start)
		if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
			return
		end

		local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)
		local clear_start = highlight_clear_start(changed_start or 0, content_highlights)
		vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, clear_start, -1)

		for i = clear_start + 1, #nui_lines do
			local nui_line = nui_lines[i]
			if i <= buf_line_count then
				nui_line:highlight(state.bufnr, chat_hl_ns, i)
			end
		end

		local function apply_widget_extmarks(line_map)
			for _, pos in pairs(line_map) do
				if pos.highlights then
					render.apply_extmark_highlights(state.bufnr, chat_hl_ns, pos.highlights, pos.start_line, {
						min_line = clear_start,
						max_line = buf_line_count,
					})
				end
			end
		end

		apply_widget_extmarks(state.questions)
		apply_widget_extmarks(state.permissions)
		apply_widget_extmarks(state.edits)
		apply_widget_extmarks(state.tasks)
		apply_widget_extmarks(state.tools)
		render.apply_extmark_highlights(state.bufnr, chat_hl_ns, content_highlights, 0, {
			min_line = clear_start,
			max_line = buf_line_count,
		})
		state.last_render_highlight_signature = highlight_signature
	end

	if #new_lines == 0 or #nui_lines == 0 then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
		vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, 0, -1)
		vim.bo[state.bufnr].modifiable = false
		state.last_render_highlight_signature = nil
		if apply_widget_focus_cursor() then
			vim.cmd("redraw")
		end
		return
	end

	local old_lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)

	local first_diff = nil
	local min_len = math.min(#old_lines, #new_lines)
	for i = 1, min_len do
		if old_lines[i] ~= new_lines[i] then
			first_diff = i - 1
			break
		end
	end

	if first_diff == nil then
		if #old_lines == #new_lines then
			if state.last_render_highlight_signature ~= highlight_signature then
				apply_render_highlights(0)
			end
			if apply_widget_focus_cursor() then
				vim.cmd("redraw")
			end
			return
		end
		first_diff = min_len
	end

	first_diff = math.min(first_diff, buf_line_count - 1)
	if first_diff < 0 then
		first_diff = 0
	end

	local replacement = {}
	for i = first_diff + 1, #new_lines do
		table.insert(replacement, new_lines[i])
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, first_diff, -1, false, replacement)

	apply_render_highlights(first_diff)
	vim.bo[state.bufnr].modifiable = false

	if apply_widget_focus_cursor() then
		vim.cmd("redraw")
		return
	end

	if restore_widget_cursor_context(widget_cursor) then
		vim.cmd("redraw")
		return
	end

	if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
	end

	vim.cmd("redraw")
end

-- Legacy compatibility
function M.update_assistant_message(message_id, content)
	M.schedule_render()
end

function M.update_reasoning(message_id, reasoning_text)
	if not thinking.is_enabled() then
		return
	end
	thinking.store_reasoning(message_id, reasoning_text)
	if not thinking.should_update() then
		return
	end
	M.schedule_render()
end

function M.clear_streaming_state() end

-- ─── Cross-domain key routers ─────────────────────────────────────────────────

function M.sync_widget_selection_from_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end
	local min_line, max_line = interactive_widget_bounds()
	if not min_line or not max_line then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(state.winid)[1] - 1
	if cursor_line < min_line or cursor_line > max_line then
		return
	end
	chat_questions.sync_selected_option_from_cursor()
	chat_permissions.sync_selected_option_from_cursor()
	chat_edits.sync_selected_file_from_cursor()
end

---Move cursor first, then sync widget selection to cursor.
---@param direction "up" | "down"
function M.handle_question_navigation(direction)
	local key = direction == "up" and "k" or "j"
	vim.cmd("normal! " .. key)

	M.sync_widget_selection_from_cursor()
end

---Route 1-9 to whichever widget is under cursor.
---@param number number
function M.handle_question_number_select(number)
	local request_id = chat_questions.get_question_at_cursor()
	if request_id then
		if question_state.select_option(request_id, number) then
			local qstate = question_state.get_question(request_id)
			emit("question_selection_changed", {
				request_id = request_id,
				tab_index = qstate and qstate.current_tab or nil,
				selected = { number },
			})
			emit("interaction_changed", {
				kind = "question",
				action = "selection_changed",
				id = request_id,
			})
		end
		chat_questions.rerender_question(request_id)
		return
	end

	local perm_id = chat_permissions.get_permission_at_cursor()
	if perm_id and number >= 1 and number <= 3 then
		if permission_state.select_option(perm_id, number) then
			emit("permission_selection_changed", {
				permission_id = perm_id,
				selected = number,
			})
			emit("interaction_changed", {
				kind = "permission",
				action = "selection_changed",
				id = perm_id,
			})
		end
		chat_permissions.rerender_permission(perm_id)
		return
	end

	local eid = chat_edits.get_edit_at_cursor()
	if eid then
		local estate = edit_state.get_edit(eid)
		if estate and number >= 1 and number <= #estate.files then
			edit_state.move_selection_to(eid, number)
			chat_edits.rerender_edit(eid)
		end
		return
	end

	vim.api.nvim_feedkeys(tostring(number), "n", false)
end

---Route Enter to tasks/questions/permissions/edits.
function M.handle_question_confirm()
	local todo_session_id = chat_todos.get_dock_at_cursor()
	if todo_session_id then
		chat_todos.toggle_dock(todo_session_id)
		return
	end

	local task_part_id = chat_tasks.get_task_at_cursor()
	if task_part_id then
		chat_tasks.handle_task_toggle(task_part_id)
		return
	end

	local request_id, qstate = chat_questions.get_question_at_cursor()
	if request_id then
		if qstate.status == "confirming" then
			local current_selection = question_state.get_current_selection(request_id)
			local choice = current_selection and current_selection[1] or 1
			if choice == 1 then
				chat_questions.submit_question_answers(request_id)
			else
				question_state.cancel_confirmation(request_id)
				emit("interaction_changed", {
					kind = "question",
					action = "confirmation_cancelled",
					id = request_id,
				})
				chat_questions.rerender_question(request_id)
			end
			return
		end

		local current_tab = qstate.current_tab
		local total_count = #qstate.questions
		local current_selection = qstate.selections[current_tab]
		local is_current_answered = current_selection and current_selection.is_answered

		if not is_current_answered then
			local _, total = question_state.get_answered_count(request_id)
			if total > 1 then
				local answered, _ = question_state.get_answered_count(request_id)
				vim.notify(
					string.format(
						"Question block: %d/%d answered. Please select an answer for this question.",
						answered,
						total
					),
					vim.log.levels.WARN
				)
			else
				vim.notify("Please select an answer before submitting.", vim.log.levels.WARN)
			end
			return
		end

		if not question_state.is_ready_to_advance(request_id) then
			question_state.mark_ready_to_advance(request_id)
			chat_questions.rerender_question(request_id)
			return
		end

		local all_answered, unanswered_indices = question_state.are_all_answered(request_id)
		if not all_answered then
			if #unanswered_indices > 0 then
				question_state.set_tab(request_id, unanswered_indices[1])
				emit("question_tab_changed", {
					request_id = request_id,
					tab_index = unanswered_indices[1],
				})
				chat_questions.rerender_question(request_id)
			end
			return
		end

		if total_count > 1 then
			question_state.set_confirming(request_id)
			emit("question_confirming", {
				request_id = request_id,
			})
			chat_questions.rerender_question(request_id)
		else
			chat_questions.submit_question_answers(request_id)
		end
		return
	end

	local perm_id, pstate = chat_permissions.get_permission_at_cursor()
	if perm_id and pstate then
		chat_permissions.handle_permission_confirm(perm_id, pstate)
		return
	end

	local eid = chat_edits.get_edit_at_cursor()
	if eid then
		if edit_state.is_readonly(eid) then
			edit_state.accept_all(eid)
			chat_edits.finalize_edit(eid)
			return
		end

		chat_edits.sync_selected_file_from_cursor()
		local file = edit_state.get_selected_file(eid)
		if file and file.filepath and file.filepath ~= "" then
			vim.cmd("edit " .. vim.fn.fnameescape(file.filepath))
		end
		return
	end

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
end

---Route Escape to questions/permissions/edits.
function M.handle_question_cancel()
	local request_id, qstate = chat_questions.get_question_at_cursor()
	if request_id then
		if qstate.status == "confirming" then
			question_state.cancel_confirmation(request_id)
			emit("interaction_changed", {
				kind = "question",
				action = "confirmation_cancelled",
				id = request_id,
			})
			chat_questions.rerender_question(request_id)
			return
		end

		local client = require("opencode.client")
		local current_session = require("opencode.state").get_session()
		local session_id = qstate.session_id or current_session.id
		client.reject_question(session_id, request_id, function(err, success)
			vim.schedule(function()
				if err then
					vim.notify("Failed to cancel question: " .. tostring(err), vim.log.levels.ERROR)
					return
				end
				question_state.mark_rejected(request_id)
				emit("interaction_changed", {
					kind = "question",
					action = "rejected",
					id = request_id,
				})
				chat_questions.update_question_status(request_id, "rejected")
			end)
		end)
		return
	end

	local perm_id = chat_permissions.get_permission_at_cursor()
	if perm_id then
		chat_permissions.handle_permission_reject(perm_id)
		return
	end

	local eid = chat_edits.get_edit_at_cursor()
	if eid then
		chat_edits.handle_edit_reject_all()
		return
	end

	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end

---Route Tab to the active question.
function M.handle_question_next_tab()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
		return
	end
	chat_questions.handle_question_next_tab(request_id)
end

---Route Shift-Tab to the active question.
function M.handle_question_prev_tab()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "n", false)
		return
	end
	chat_questions.handle_question_prev_tab(request_id)
end

---Route 'c' to the active question.
function M.handle_question_custom_input()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys("c", "n", false)
		return
	end
	chat_questions.handle_question_custom_input(request_id)
end

---Route 'm' to the active question or permission widget.
function M.handle_widget_message()
	local request_id = chat_questions.get_question_at_cursor()
	if request_id then
		chat_questions.handle_question_message(request_id)
		return
	end

	local perm_id = chat_permissions.get_permission_at_cursor()
	if perm_id then
		chat_permissions.handle_permission_message(perm_id)
		return
	end

	local edit_id = chat_edits.get_edit_at_cursor()
	if edit_id then
		chat_edits.handle_edit_message()
		return
	end

	vim.api.nvim_feedkeys("m", "n", false)
end

---Route Space to the active question.
function M.handle_question_toggle()
	local request_id = chat_questions.get_question_at_cursor()
	if not request_id then
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>", true, false, true), "n", false)
		return
	end
	chat_questions.handle_question_toggle(request_id)
end

-- ─── Re-exports from sub-modules ─────────────────────────────────────────────

-- Questions
M.add_question_message = chat_questions.add_question_message
M.update_question_status = chat_questions.update_question_status
M.get_question_at_cursor = chat_questions.get_question_at_cursor
M.rerender_question = chat_questions.rerender_question
M.submit_question_answers = chat_questions.submit_question_answers
M.clear_questions = chat_questions.clear_questions
M.debug_questions = chat_questions.debug_questions
M.get_pending_question_count = chat_questions.get_pending_question_count
M.has_pending_questions = chat_questions.has_pending_questions

-- Permissions
M.add_permission_message = chat_permissions.add_permission_message
M.update_permission_status = chat_permissions.update_permission_status
M.get_permission_at_cursor = chat_permissions.get_permission_at_cursor
M.rerender_permission = chat_permissions.rerender_permission
M.handle_permission_confirm = chat_permissions.handle_permission_confirm
M.handle_permission_reject = chat_permissions.handle_permission_reject

-- Edits
M.add_edit_message = chat_edits.add_edit_message
M.get_edit_at_cursor = chat_edits.get_edit_at_cursor
M.rerender_edit = chat_edits.rerender_edit
M.finalize_edit = chat_edits.finalize_edit
M.handle_edit_accept_file = chat_edits.handle_edit_accept_file
M.handle_edit_reject_file = chat_edits.handle_edit_reject_file
M.handle_edit_accept_all = chat_edits.handle_edit_accept_all
M.handle_edit_reject_all = chat_edits.handle_edit_reject_all
M.handle_edit_resolve_file = chat_edits.handle_edit_resolve_file
M.handle_edit_resolve_all = chat_edits.handle_edit_resolve_all
M.handle_edit_toggle_diff = chat_edits.handle_edit_toggle_diff
M.handle_edit_diff_tab = chat_edits.handle_edit_diff_tab
M.handle_edit_diff_split = chat_edits.handle_edit_diff_split
M.open_inline_diff_split = chat_edits.open_inline_diff_split

-- Tasks / tools
M.get_task_at_cursor = chat_tasks.get_task_at_cursor
M.get_tool_at_cursor = chat_tasks.get_tool_at_cursor
M.rerender_task = chat_tasks.rerender_task
M.handle_task_toggle = chat_tasks.handle_task_toggle
M.rerender_tool = chat_tasks.rerender_tool
M.handle_tool_toggle = chat_tasks.handle_tool_toggle

-- Session navigation
M.is_navigating = chat_nav.is_navigating
M.enter_child_session = chat_nav.enter_child_session
M.leave_child_session = chat_nav.leave_child_session

return M
