local M = {}

local NuiLine = require("nui.line")

local actions = require("opencode.actions")
local panel = require("opencode.ui.panel")
local selectors = require("opencode.selectors")

local state = require("opencode.ui.chat.state").state

local session_tabs_hl_ns = vim.api.nvim_create_namespace("opencode_session_tabs_hl")
local session_tabs_augroup = vim.api.nvim_create_augroup("OpenCodeSessionTabs", { clear = false })
local FLOAT_SESSION_TABS_ZINDEX = 75

local session_tabs_refresh_autocmds_setup = false

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
	session_tabs = {
		enabled = true,
		auto_fit = false,
		max_tabs = 3,
		separator = " │ ",
		colors = {},
		icons = {
			running = "●",
			waiting = "◈",
			idle = "○",
			error = "✕",
		},
	},
}

local function emit_refresh()
	vim.schedule(function()
		if state.visible and type(M.update_winbar) == "function" then
			M.update_winbar()
		end
	end)
end

local function get_config()
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}
	return vim.tbl_deep_extend("force", {}, defaults, full_config.chat or {}, state.config or {})
end

local function has_highlight_options(opts)
	return type(opts) == "table" and next(opts) ~= nil
end

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

local function set_winbar_hl(name, opts, fallback)
	local ok = pcall(vim.api.nvim_set_hl, 0, name, opts)
	if not ok and fallback then
		pcall(vim.api.nvim_set_hl, 0, name, fallback)
	end
end

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

local function escape_winbar_text(text)
	local escaped = tostring(text or ""):gsub("%%", "%%%%")
	return escaped
end

local function session_tab_icon(session, icons)
	if session:is_waiting() then
		return icons.waiting or "◈", "OpenCodeWinbarWaiting"
	end
	if session:is_busy() then
		return icons.running or "●", "OpenCodeWinbarRunning"
	end
	if session:is_error() then
		return icons.error or "✕", "OpenCodeWinbarError"
	end
	return icons.idle or "○", "OpenCodeWinbarIdle"
end

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

local function clamp(value, min_value, max_value)
	if value < min_value then
		return min_value
	end
	if value > max_value then
		return max_value
	end
	return value
end

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

local function current_session_tab_index(sessions, active_session, current_root_session_id)
	for index, session in ipairs(sessions) do
		if
			session:is_current_session()
			or session:is_current_root()
			or session.id == active_session.id
			or session.id == current_root_session_id
		then
			return index, session.id
		end
	end
	return nil, current_root_session_id or active_session.id
end

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

local function visible_session_tabs_start(sessions, max_tabs, current_index, current_session_id, commit)
	commit = commit == true
	local session_count = #sessions
	if session_count <= max_tabs then
		if commit then
			state.session_tabs_start = nil
			state.session_tabs_current_id = current_session_id
		end
		return 1
	end

	local max_start = session_count - max_tabs + 1
	local stored_start = tonumber(state.session_tabs_start)
	if stored_start and state.session_tabs_current_id == current_session_id then
		local start_index = clamp(math.floor(stored_start), 1, max_start)
		if commit then
			state.session_tabs_start = start_index
		end
		return start_index
	end

	local start_index = centered_session_tabs_start(session_count, max_tabs, current_index)
	if commit then
		state.session_tabs_start = start_index
		state.session_tabs_current_id = current_session_id
	end
	return start_index
end

local function session_tabs_auto_fit_enabled(tabs_cfg)
	tabs_cfg = type(tabs_cfg) == "table" and tabs_cfg or {}
	local max_tabs = tabs_cfg.max_tabs
	return tabs_cfg.auto_fit == true or (type(max_tabs) == "string" and max_tabs:lower() == "auto")
end

local function numeric_session_tabs_max(tabs_cfg)
	tabs_cfg = type(tabs_cfg) == "table" and tabs_cfg or {}
	return math.max(1, tonumber(tabs_cfg.max_tabs) or 3)
end

local function build_session_tabs_line(tabs_cfg, sessions, active_session, current_root_session_id, max_tabs, opts)
	opts = opts or {}
	local preview = opts.preview == true
	max_tabs = math.max(1, tonumber(max_tabs) or 1)
	local separator = tabs_cfg.separator or " │ "
	local icons = tabs_cfg.icons or {}
	local parts = {}
	local line = NuiLine()
	local has_tabs = false
	local display_col = 0
	local target_id = 0
	local winbar_targets = {}
	local mouse_targets = {}
	if not preview then
		state.winbar_targets = winbar_targets
		state.session_tabs_mouse_targets = mouse_targets
	end

	local current_index, current_session_id = current_session_tab_index(sessions, active_session, current_root_session_id)
	local start_index = visible_session_tabs_start(sessions, max_tabs, current_index, current_session_id, not preview)
	local end_index = math.min(#sessions, start_index + max_tabs - 1)
	local max_start = math.max(1, #sessions - max_tabs + 1)

	local function append_text(text, hl)
		line:append(text, hl)
		display_col = display_col + vim.fn.strdisplaywidth(text)
	end

	local function append_separator()
		if has_tabs then
			append_text(separator, "OpenCodeWinbar")
		end
	end

	local function register_target(target)
		target_id = target_id + 1
		if not preview then
			winbar_targets[target_id] = target
		end
		return target_id
	end

	local function register_mouse_target(id, start_col, end_col)
		if preview then
			return
		end
		if end_col < start_col then
			return
		end
		table.insert(mouse_targets, {
			target = id,
			start_col = start_col,
			end_col = end_col,
		})
	end

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
		table.insert(parts, string.format("%%%d@v:lua.__opencode_chat_winbar_click@%%#OpenCodeWinbar#%s%%T", id, escape_winbar_text(label)))
	end

	if #sessions > max_tabs and start_index > 1 then
		append_ellipsis(start_index - max_tabs, start_index - 1)
	end

	for index = start_index, end_index do
		local session = sessions[index]
		local icon, icon_hl = session_tab_icon(session, icons)
		local title = session:title() or session.id
		local display_title = truncate_title(title, 18)
		local is_current = session:is_current_session()
			or session:is_current_root()
			or active_session.id == session.id
			or current_root_session_id == session.id
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
		table.insert(parts, string.format("%%%d@v:lua.__opencode_chat_winbar_click@%%#%s#%s%%#%s#%s%%T", id, display_icon_hl, escape_winbar_text(display_icon), label_hl, escape_winbar_text(display_label)))
	end

	if #sessions > max_tabs and end_index < #sessions then
		append_ellipsis(start_index + max_tabs, #sessions - end_index)
	end

	local running = 0
	local waiting = 0
	for _, session in ipairs(sessions) do
		if session:is_busy() then
			running = running + 1
		end
		if session:is_waiting() then
			waiting = waiting + 1
		end
	end

	if running > 0 or waiting > 0 then
		append_separator()
		append_text((icons.running or "●") .. tostring(running), "OpenCodeWinbarRunning")
		append_text(" ", "OpenCodeWinbar")
		append_text((icons.waiting or "◈") .. tostring(waiting), "OpenCodeWinbarWaiting")
		has_tabs = true
		table.insert(parts, string.format("%%#OpenCodeWinbar#%s%%#OpenCodeWinbarRunning#%s%d %%#OpenCodeWinbarWaiting#%s%d", "", escape_winbar_text(icons.running or "●"), running, escape_winbar_text(icons.waiting or "◈"), waiting))
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

local function resolve_session_tabs_max(tabs_cfg, sessions, active_session, current_root_session_id, available_width)
	if not session_tabs_auto_fit_enabled(tabs_cfg) then
		return numeric_session_tabs_max(tabs_cfg)
	end

	local session_count = #sessions
	if session_count <= 0 then
		return 1
	end

	local width = tonumber(available_width) or 0
	if width <= 0 then
		return 1
	end

	for candidate = session_count, 1, -1 do
		local preview = build_session_tabs_line(tabs_cfg, sessions, active_session, current_root_session_id, candidate, {
			preview = true,
		})
		if vim.fn.strdisplaywidth(preview.line:content()) <= width then
			return candidate
		end
	end

	return 1
end

local function build_session_tabs(tabs_cfg, current_session, opts)
	opts = opts or {}
	ensure_winbar_highlights(tabs_cfg)

	local sessions = selectors.get_active_session_views()
	local current_view = selectors.get_current_session_view()
	local active_session = current_session or (current_view and current_view:to_record()) or {}
	local current_root_session_id = selectors.get_current_runtime_root_id()
	local max_tabs = resolve_session_tabs_max(tabs_cfg, sessions, active_session, current_root_session_id, opts.available_width)

	return build_session_tabs_line(tabs_cfg, sessions, active_session, current_root_session_id, max_tabs)
end

local function session_tabs_window_is_valid()
	return state.session_tabs_winid and vim.api.nvim_win_is_valid(state.session_tabs_winid) or false
end

local function session_tabs_buffer_is_valid()
	return state.session_tabs_bufnr and vim.api.nvim_buf_is_valid(state.session_tabs_bufnr) or false
end

function M.close_float_window()
	if session_tabs_window_is_valid() then
		pcall(vim.api.nvim_win_close, state.session_tabs_winid, true)
	end
	state.session_tabs_winid = nil
	state.session_tabs_mouse_targets = {}
end

function M.focus_chat_window()
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		pcall(vim.api.nvim_set_current_win, state.winid)
	end
end

local function is_visual_or_select_mode(mode)
	return mode == "v" or mode == "V" or mode == string.char(22) or mode == "s" or mode == "S" or mode == string.char(19)
end

local function leave_session_tabs_visual_mode()
	if is_visual_or_select_mode(vim.api.nvim_get_mode().mode) then
		local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
		vim.api.nvim_feedkeys(esc, "nx", false)
	end
	M.focus_chat_window()
end

local function handle_session_tabs_mouse_click()
	local mouse = vim.fn.getmousepos()
	if not mouse or mouse.winid ~= state.session_tabs_winid then
		M.focus_chat_window()
		return
	end

	local col = tonumber(mouse.wincol or 0) or 0
	if col <= 0 then
		col = tonumber(mouse.column or 0) or 0
	end
	if col <= 0 then
		M.focus_chat_window()
		return
	end

	for _, target in ipairs(state.session_tabs_mouse_targets or {}) do
		if col >= target.start_col and col <= target.end_col then
			M.select_winbar_session(target.target)
			M.focus_chat_window()
			return
		end
	end

	M.focus_chat_window()
end

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

local function update_float_session_tabs_window(tabs_cfg, current_session)
	if not state.visible or not state.config or state.config.layout ~= "float" or tabs_cfg.enabled == false then
		M.close_float_window()
		return false
	end
	if not state.float_dims then
		M.close_float_window()
		return false
	end

	local win_config = calculate_session_tabs_window_config(state.float_dims)
	if not win_config then
		M.close_float_window()
		return false
	end

	local tabs = build_session_tabs(tabs_cfg, current_session, { available_width = win_config.width })
	if not tabs.has_tabs then
		M.close_float_window()
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
		M.close_float_window()
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
		M.close_float_window()
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

	M.close_float_window()
	local tabs = build_session_tabs(tabs_cfg, nil, { available_width = vim.api.nvim_win_get_width(state.winid) })

	pcall(function()
		vim.wo[state.winid].winbar = table.concat(tabs.parts, escape_winbar_text(tabs.separator))
	end)
end

function M.select_winbar_session(target)
	local index = tonumber(target)
	local entry = index and state.winbar_targets[index] or nil
	if type(entry) == "table" and entry.kind == "page" then
		state.session_tabs_start = entry.start
		state.session_tabs_current_id = entry.current_session_id
		M.update_winbar()
		M.focus_chat_window()
		return
	end

	local session_id = type(entry) == "table" and entry.session_id or entry
	if not session_id then
		M.focus_chat_window()
		return
	end
	local view = selectors.get_session_view(session_id)
	local record = view and view:to_record() or { id = session_id }
	actions.switch_session(record, {
		notify = false,
		reason = "winbar",
	})
	M.focus_chat_window()
end

local function switch_to_session_tab(target, current_session)
	if type(target) ~= "table" or not target.id then
		return false
	end

	local current_view = selectors.get_current_session_view()
	local current = current_session or (current_view and current_view:to_record()) or {}
	if target.id == current.id then
		return false
	end

	local record = type(target.to_record) == "function" and target:to_record() or target
	actions.switch_session(record, {
		notify = false,
		reason = "winbar",
	})
	return true
end

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

	local sessions = selectors.get_active_session_views()
	local current_view = selectors.get_current_session_view()
	return switch_to_session_tab(sessions[target_index], current_view and current_view:to_record() or {})
end

function M.cycle_session(direction)
	local sessions = selectors.get_active_session_views()
	if #sessions <= 1 then
		return false
	end

	local current_view = selectors.get_current_session_view()
	local current = current_view and current_view:to_record() or {}
	local current_index = nil
	for index, session in ipairs(sessions) do
		if session.id == current.id or session:is_current_session() then
			current_index = index
			break
		end
	end

	if not current_index then
		for index, session in ipairs(sessions) do
			if session:is_current_root() then
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

function M.setup_refresh_autocmds()
	if session_tabs_refresh_autocmds_setup then
		return
	end
	session_tabs_refresh_autocmds_setup = true

	vim.api.nvim_create_autocmd("ColorScheme", {
		group = session_tabs_augroup,
		callback = emit_refresh,
		desc = "Refresh OpenCode session tabs after colorscheme changes",
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = session_tabs_augroup,
		pattern = "background",
		callback = emit_refresh,
		desc = "Refresh OpenCode session tabs after background changes",
	})
	vim.api.nvim_create_autocmd("VimResized", {
		group = session_tabs_augroup,
		callback = emit_refresh,
		desc = "Refresh OpenCode session tabs after editor resize",
	})
	pcall(vim.api.nvim_create_autocmd, "WinResized", {
		group = session_tabs_augroup,
		callback = emit_refresh,
		desc = "Refresh OpenCode session tabs after window resize",
	})
end

_G.__opencode_chat_winbar_click = _G.__opencode_chat_winbar_click or function(minwid)
	if type(M.select_winbar_session) == "function" then
		M.select_winbar_session(minwid)
	end
end

return M
