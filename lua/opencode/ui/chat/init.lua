local cs = require("opencode.ui.chat.state")
local instances = cs.factory("init", function(view)
-- opencode.nvim - Chat buffer UI module
-- Main chat interface with configurable layouts
-- This module mirrors the TUI's session/index.tsx rendering approach

local M = {}

local Popup = require("nui.popup")
local NuiLine = require("nui.line")
local input = require("opencode.ui.input")
local chat_help = cs.module(view, require("opencode.ui.chat.help"))
local chat_float_focus = cs.module(view, require("opencode.ui.chat.float_focus"))
local chat_messages = cs.module(view, require("opencode.ui.chat.messages"))
local chat_keymaps = cs.module(view, require("opencode.ui.chat.keymaps"))
local keymaps = require("opencode.util.keymap")
local chat_session_tabs = cs.module(view, require("opencode.ui.chat.session_tabs"))
local spinner = require("opencode.ui.spinner")
local event_util = require("opencode.events.util")
local logger = require("opencode.logger")

-- ─── Shared state & sub-modules ──────────────────────────────────────────────

local state = view
local chat_hl_ns = cs.chat_hl_ns
local FLOAT_CHAT_TOP_PADDING = 2

local render = cs.module(view, require("opencode.ui.chat.render"))
local chat_highlights = require("opencode.ui.chat.highlights")
local ui_highlights = require("opencode.ui.highlights")
local render_state = cs.module(view, require("opencode.ui.chat.render_state"))
local render_context = cs.module(view, require("opencode.ui.chat.render_context"))
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local widget_index = cs.module(view, require("opencode.ui.chat.widget_index"))
local message_renderer = cs.module(view, require("opencode.ui.chat.message_renderer"))
local edit_previews = cs.module(view, require("opencode.ui.chat.edit_previews"))
local chat_cursor = cs.module(view, require("opencode.ui.chat.cursor"))
local chat_tasks = cs.module(view, require("opencode.ui.chat.tasks"))
local chat_questions = cs.module(view, require("opencode.ui.chat.questions"))
local chat_permissions = cs.module(view, require("opencode.ui.chat.permissions"))
local chat_edits = cs.module(view, require("opencode.ui.chat.edits"))
local chat_interactions = cs.module(view, require("opencode.ui.chat.interactions"))
local chat_nav = cs.module(view, require("opencode.ui.chat.nav"))
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))

chat_messages.set_schedule_render(function(opts)
	M.schedule_render(opts)
end)


local question_state = require("opencode.question.state")
local permission_state = require("opencode.permission.state")
local edit_state = require("opencode.edit.state")
local apply_widget_focus_cursor

-- Headless consumers inspect buffers; screen redraw has no target there.
local function redraw()
	if not cs.workspace.switching and #vim.api.nvim_list_uis() > 0 then vim.cmd("redraw") end
end

-- ─── Configuration ────────────────────────────────────────────────────────────

local defaults = vim.deepcopy(require("opencode.config").defaults.chat)

local function get_config()
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}
	return vim.tbl_deep_extend("force", defaults, full_config.chat or {})
end

local function reset_chat_surface(opts)
	render_state.reset_chat_surface(opts)
	state.transcript_dirty = true
end
local stream_block_key = render_state.stream_block_key
local render_highlight_signature = render_state.render_highlight_signature
local highlight_clear_start = render_state.highlight_clear_start
local clear_chat_highlights = render_state.clear_chat_highlights
local subscriptions = {}
local chat_event_handlers_setup = false
local chat_event_handlers_events = nil
local chat_event_handlers_generation = nil
local config_refresh_scheduled = false
local colorscheme_refresh_scheduled = false
local resize_refresh_autocmds_setup = false
local resize_refresh_scheduled = false
local render_retry_used = false
local render_retry_token = 0
local pending_render_data
local render_schedule_token = 0
local winbar_refresh_scheduled = false
local opening = false
local configure_buffer_keymaps

-- Scheduling follows the transcript buffer in any window. Cursor/detail helpers
-- still follow the owned chat window through cs.is_chat_buffer_displayed(view).
local function chat_surface_is_visible()
	if not cs.valid(view) or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return false end
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(winid) == state.bufnr then return true end
	end
	return false
end

local function invalidate_cached_render_state()
	render_state.clear_render_cache()
	render_state.clear_code_cache()
	render_state.invalidate_render_highlights(0)
	state.force_full_render = true
	state.transcript_dirty = true
end

local function apply_config_change()
	state.config = get_config()
	configure_buffer_keymaps(state.bufnr)
	ui_highlights.refresh()
	invalidate_cached_render_state()
	if chat_surface_is_visible() then
		M.schedule_render({ force = true })
	end
end

local function schedule_config_refresh()
	if config_refresh_scheduled then
		return
	end
	config_refresh_scheduled = true
	vim.schedule(function()
		config_refresh_scheduled = false
		apply_config_change()
	end)
end

function M.handle_colorscheme()
	if colorscheme_refresh_scheduled then
		return
	end
	colorscheme_refresh_scheduled = true
	vim.schedule(function()
		colorscheme_refresh_scheduled = false
		invalidate_cached_render_state()
		if chat_surface_is_visible() then
			M.schedule_render({ force = true })
		end
	end)
end

local function resolve_resize_event_windows(args, event)
	event = event or vim.v.event
	if type(event) == "table" and type(event.windows) == "table" then
		return event.windows
	end

	local data = args and args.data
	if type(data) == "table" and type(data.windows) == "table" then
		return data.windows
	end
	return nil
end

local function resize_event_affects_chat(windows)
	if type(windows) ~= "table" then
		return true
	end

	for _, winid in ipairs(windows) do
		if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == state.bufnr then
			return true
		end
	end
	return false
end

local function schedule_resize_refresh(args, windows)
	if not chat_surface_is_visible() or not resize_event_affects_chat(windows) or resize_refresh_scheduled then
		return
	end
	resize_refresh_scheduled = true
	vim.schedule(function()
		resize_refresh_scheduled = false
		if chat_surface_is_visible() then
			M.schedule_render({ force = true })
		end
	end)
end

local function schedule_window_resize_refresh(args, event)
	local windows = resolve_resize_event_windows(args, event)
	schedule_resize_refresh(args, windows)
end

local function setup_resize_refresh_autocmds()
	if resize_refresh_autocmds_setup then
		return
	end
	resize_refresh_autocmds_setup = true

	local group = vim.api.nvim_create_augroup("OpenCodeChatResize_" .. (view.id or 1), { clear = false })
	vim.api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		callback = function(args)
			if args.buf == state.bufnr and not opening and not state.render_in_progress
				and (state.transcript_dirty or state.force_full_render) then
				M.do_render()
			end
		end,
		desc = "Refresh dirty OpenCode transcript before displaying its buffer",
	})
	vim.api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
		group = group,
		callback = schedule_resize_refresh,
		desc = "Refresh OpenCode chat after editor resize",
	})
	pcall(vim.api.nvim_create_autocmd, "WinResized", {
		group = group,
		callback = schedule_window_resize_refresh,
		desc = "Refresh OpenCode chat after window resize",
	})
end

local capture_widget_cursor_context = chat_cursor.capture_widget_cursor_context
local restore_widget_cursor_context = chat_cursor.restore_widget_cursor_context
local should_auto_scroll = chat_cursor.should_auto_scroll

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

function M.update_winbar()
	return chat_session_tabs.update_winbar()
end

function M.select_winbar_session(target)
	return chat_session_tabs.select_winbar_session(target)
end

function M.cycle_session(direction)
	return chat_session_tabs.cycle_session(direction)
end

-- ─── Float focus autocmds ─────────────────────────────────────────────────────

-- ─── Cursor preservation ──────────────────────────────────────────────────────

local mapped_buffer, mapped_keys, mapped_app_keys, mapped_layout
configure_buffer_keymaps = function(bufnr, refresh)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
	local app_keys = { keymaps.resolve("chat") }
	if refresh and mapped_app_keys and not vim.deep_equal(app_keys, mapped_app_keys) then
		state.config = get_config()
	end
	local keys = { keymaps.resolve("chat", (state.config or {}).keymaps) }
	mapped_app_keys = app_keys
	if mapped_buffer == bufnr and mapped_layout == (state.config or {}).layout and vim.deep_equal(keys, mapped_keys) then return end
	chat_keymaps.setup_buffer(bufnr, {
		close = function()
			M.close()
		end,
		focus_input = function()
			M.focus_input()
		end,
		toggle_auto_scroll = function()
			M.toggle_auto_scroll()
		end,
		show_help = function()
			M.show_help()
		end,
	})
	mapped_buffer, mapped_keys, mapped_layout = bufnr, keys, (state.config or {}).layout
end

local function create_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	configure_buffer_keymaps(bufnr)
	return bufnr
end

local SPINNER_ANIM_INTERVAL_MS = spinner.get_interval_ms()

local stop_spinner_animation_timer = chat_messages.stop_spinner_animation_timer

local function start_spinner_animation_timer()
	if state.spinner_anim_timer then
		return
	end
	if not state.visible then
		return
	end
	if type(state.spinner_footer_line) ~= "number" then
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
			if state.spinner_anim_timer ~= timer then return end
			if not state.visible or type(state.spinner_footer_line) ~= "number" then
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
	if type(state.spinner_footer_line) == "number" then
		start_spinner_animation_timer()
	else
		stop_spinner_animation_timer()
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
	chat_help.show(state.config)
end

function M.create()
	if not cs.valid(view) then return end
	local events = require("opencode.events")
	local function subscribe(event, callback)
		subscriptions[#subscriptions + 1] = { bus = events, event = event, callback = callback }
		events.on(event, callback)
	end
	local listener_generation
	if type(events.get_generation) == "function" then
		listener_generation = events.get_generation()
	elseif type(events.listener_count) == "function" then
		listener_generation = events.listener_count("chat_render")
	end
	local buffer_exists = state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)
	if
		buffer_exists
		and chat_event_handlers_setup
		and chat_event_handlers_events == events
		and (
			(type(events.get_generation) == "function" and listener_generation == chat_event_handlers_generation)
			or (type(events.get_generation) ~= "function" and (type(events.listener_count) ~= "function" or listener_generation > 0))
		)
	then
		configure_buffer_keymaps(state.bufnr, true)
		return state.bufnr
	end

	state.config = get_config()
	chat_session_tabs.setup_refresh_autocmds()
	setup_resize_refresh_autocmds()
	if not buffer_exists then
		state.bufnr = create_buffer()
	else
		configure_buffer_keymaps(state.bufnr)
	end
	reset_chat_surface()

	if
		not chat_event_handlers_setup
		or chat_event_handlers_events ~= events
		or chat_event_handlers_generation ~= listener_generation
	then
	subscribe("chat_render", function(data)
		if not cs.valid(view) then return end
		vim.schedule(function()
			M.schedule_render(data)
		end)
	end)

	local function refresh_winbar()
		if winbar_refresh_scheduled then return end
		winbar_refresh_scheduled = true
		vim.schedule(function()
			winbar_refresh_scheduled = false
			M.update_winbar()
		end)
	end
	for _, event in ipairs({ "sessions_changed", "session_pending_change", "session_status_change" }) do
		subscribe(event, refresh_winbar)
	end

	subscribe("config_change", function()
		schedule_config_refresh()
	end)

	subscribe("chat_stream_part_updated", function(data)
		vim.schedule(function()
			local part = data and data.part
			local session_id = data and (data.session_id or data.sessionID or data.sessionId)
			local message_id = data and (data.message_id or data.messageID or data.messageId)
			local part_id = data and (data.part_id or data.partID or data.partId)
			if part then
				session_id = session_id or part.sessionID
				message_id = message_id or part.messageID
				part_id = part_id or part.id
			end
			if not message_id or not part_id then
				return
			end
			local current_session = cs.session(view)
			local render_session_id = event_util.render_target_session_id(current_session.id, session_id)
			if not render_session_id then
				return
			end
			local nested_child = session_id and session_id ~= current_session.id
			local part_type = part and part.type
			local field = data and data.field
			if nested_child and (part_type == "text" or part_type == "reasoning" or field == "text" or field == "reasoning") then
				return
			end
			if not chat_surface_is_visible() then
				state.transcript_dirty = true
				state.force_full_render = true
				return
			end
			if state.transcript_dirty or not M.update_stream_part_block(render_session_id, message_id, part_id) then
				M.schedule_render(data)
			end
		end)
	end)

	subscribe("local_notice", function(data)
		vim.schedule(function()
			if type(data) ~= "table" then
				return
			end
			M.add_message(data.role or "system", data.content or "", {
				kind = data.kind,
				session_id = data.session_id,
				child_session_id = data.child_session_id,
				render = false,
			})
		end)
	end)

	subscribe("status_change", function(data)
		vim.schedule(function()
			if data and data.session_id and data.session_id ~= cs.session(view).id then return end
			local new_status = data and data.status
			if new_status == "streaming" or new_status == "thinking" then
				if state.visible then
					chat_tasks.start_task_animation_timer()
				end
			else
				chat_tasks.stop_task_animation_timer()
			end
		end)
	end)

	subscribe("session_change", function(data)
		if not cs.valid(view) or (data and data.reason == "pane_focus") then return end
		if data and data.view_id and data.view_id ~= view.id then return end
		if state.session_bound and (not data or data.view_id ~= view.id) then return end
		local preserve_cache = data and data.preserve_cache
		local reason = data and data.reason
		local changed_session = data and data.previous_id ~= data.id
		vim.schedule(function()
			if not preserve_cache or changed_session then
				stop_spinner_animation_timer()
				chat_tasks.stop_task_animation_timer()
			end
			local force_full_render = not preserve_cache or changed_session
			reset_chat_surface({
				reset_expansions = not preserve_cache or (changed_session and reason ~= "child_navigation"),
				preserve_render_cache = preserve_cache == true,
				force_full_render = force_full_render,
			})
			if not preserve_cache or (changed_session and reason ~= "child_navigation") then
				state.session_stack = {}
			end
			if changed_session and state.winid and vim.api.nvim_win_is_valid(state.winid) then
				vim.api.nvim_win_call(state.winid, function()
					vim.fn.winrestview({ topline = 1, leftcol = 0, skipcol = 0 })
				end)
			end
		end)
	end)
	chat_event_handlers_setup = true
	chat_event_handlers_events = events
	chat_event_handlers_generation = listener_generation
	end

	M.do_render()

	return state.bufnr
end

local function request_focus_for_pending_widgets()
	local current_session = cs.session(view)
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

---@return table|nil
local function get_relevant_question()
	local current_session = cs.session(view)
	local in_child_session_view = #state.session_stack > 0
	for _, qstate in ipairs(question_state.get_all()) do
		if
			(qstate.status == "pending" or qstate.status == "confirming")
			and widget_support.should_render(qstate.session_id, qstate.status, current_session.id, in_child_session_view)
		then
			return qstate
		end
	end
	return nil
end

-- Shared teardown for a directly closed chat window (float or split).
-- Idempotent: safe to run again from M.close() after WinClosed fired mid-close.
local function handle_chat_window_closed(closed_winid)
	if state.winid ~= closed_winid then
		return
	end
	input.close_for_view(view)
	if state.config.layout == "tab" and view.session_bound then
		for _, win in ipairs(cs.windows(view)) do
			if win ~= closed_winid then
				M.attach_window(win)
				return
			end
		end
	end
	chat_float_focus.clear()
	chat_session_tabs.close_float_window()
	state.visible = false
	state.winid = nil
	state.tabpage = nil
	state.layout = nil
	state.float_dims = nil
	reset_chat_surface()
	stop_spinner_animation_timer()
	chat_tasks.stop_task_animation_timer()
	if view ~= cs.state then M.dispose() end
	cs.remove(view)
	vim.schedule(function()
		if state.config and state.config.layout == "tab" then
			require("opencode.ui.chat").after_close()
		end
	end)
end

-- Register one-shot WinClosed teardown for the chat window in the given layout.
-- Split layouts need this too: without it state.visible stays true and the
-- animation timers keep mutating a buffer with no window.
local watched_windows = {}
local function register_chat_window_closed_autocmd(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) or watched_windows[winid] then
		return
	end
	watched_windows[winid] = true
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(winid),
		once = true,
		callback = function()
			watched_windows[winid] = nil
			handle_chat_window_closed(winid)
		end,
	})
end

function M.dispose()
	stop_spinner_animation_timer()
	chat_tasks.stop_task_animation_timer()
	for _, item in ipairs(subscriptions) do item.bus.off(item.event, item.callback) end
	subscriptions = {}
	chat_event_handlers_setup = false
	pcall(vim.api.nvim_del_augroup_by_name, "OpenCodeChatResize_" .. (view.id or 1))
	resize_refresh_autocmds_setup = false
	chat_session_tabs.dispose()
	render_state.dispose()
	cs.module(view, require("opencode.ui.chat.tool_group")).dispose()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.schedule(function()
			if not cs.valid(view) then pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true }) end
		end)
	end
end

function M.open()
	configure_buffer_keymaps(state.bufnr, true)
	if M.is_visible() then
		return
	end
	if state.visible then
		if state.config.layout == "tab" and state.winid and vim.api.nvim_win_is_valid(state.winid) then
			require("opencode.ui.chat").focus_view(view)
			return
		end
		M.close()
	end

	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		M.create()
	end
	opening = true
	local opened, open_error = xpcall(function()
	reset_chat_surface()

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
				chat_float_focus.setup({
					close = M.close,
					focus_chat = chat_session_tabs.focus_chat_window,
				})
			end
		state.float_dims = dims

		register_chat_window_closed_autocmd(popup.winid)
	elseif cfg.layout == "tab" then
		require("opencode.context").preserve_source(function()
			vim.cmd("tabnew")
			state.winid = vim.api.nvim_get_current_win()
			state.tabpage = vim.api.nvim_get_current_tabpage()
			vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		end)
		cs.workspace.tabpage = state.tabpage
		M.attach_window(state.winid)
	else
		local split_cmd

		if cfg.layout == "vertical" then
			split_cmd = cfg.position == "right" and "botright vsplit" or "topleft vsplit"
		else
			split_cmd = cfg.position == "bottom" and "botright split" or "topleft split"
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
		register_chat_window_closed_autocmd(state.winid)
		M.update_winbar()
	end

	state.visible = true
	local focused_pending_widget = request_focus_for_pending_widgets()
	state.force_full_render = true
	M.do_render()
	do
		local ok_state, app_state = pcall(require, "opencode.state")
		if ok_state then
			local status = app_state.get_status()
			if status == "streaming" or status == "thinking" then
				chat_tasks.start_task_animation_timer()
			end
		end
	end

	local line_count = vim.api.nvim_buf_line_count(state.bufnr)
	if line_count > 0 and not focused_pending_widget then
		vim.api.nvim_win_set_cursor(state.winid or 0, { line_count, 0 })
	end
	end, debug.traceback)
	opening = false
	if not opened then error(open_error) end
end

function M.attach_window(winid)
	state.winid, state.tabpage = winid, vim.api.nvim_win_get_tabpage(winid)
	state.visible = true
	if state.config.layout == "tab" then cs.workspace.tabpage = state.tabpage end
	if vim.api.nvim_win_get_buf(winid) ~= state.bufnr then vim.api.nvim_win_set_buf(winid, state.bufnr) end
	vim.wo[winid].winfixwidth, vim.wo[winid].winfixheight = false, false
	setup_chat_window_options(winid)
	register_chat_window_closed_autocmd(winid)
	M.update_winbar()
	M.do_render()
end

function M.session_changed(session, opts)
	opts = opts or {}
	local previous = cs.session(view).id
	input.close_for_view(view)
	state.session_id, state.session_name, state.session_bound = session.id, session.title or session.name, true
	state.generation = (state.generation or 0) + 1
	if previous ~= session.id then
		stop_spinner_animation_timer()
		chat_tasks.stop_task_animation_timer()
		reset_chat_surface({ reset_expansions = opts.reason ~= "child_navigation", force_full_render = true })
		if opts.reason ~= "child_navigation" and opts.reason ~= "family_navigation" then state.session_stack = {} end
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			vim.api.nvim_win_call(state.winid, function() vim.fn.winrestview({ topline = 1, leftcol = 0, skipcol = 0 }) end)
		end
	end
	M.schedule_render({ session_id = session.id, force = true })
end

function M.close()
	local current = vim.api.nvim_get_current_win()
	if view.session_bound and state.config.layout == "tab"
		and cs.for_window(current) == view and vim.api.nvim_win_get_buf(current) == state.bufnr then
		state.winid, state.tabpage, state.visible = current, vim.api.nvim_win_get_tabpage(current), true
	end
	if not state.visible then
		chat_session_tabs.close_float_window()
		reset_chat_surface()
		return
	end

	chat_float_focus.clear()
	chat_session_tabs.close_float_window()

	input.close_for_view(view)
	local details = package.loaded["opencode.ui.chat.execute_details"]
	if details then cs.module(view, details).close(false) end
	if state.winid and vim.api.nvim_win_is_valid(state.winid)
		and vim.api.nvim_win_get_buf(state.winid) ~= state.bufnr then
		-- A user may have replaced the transcript with an ordinary file.
		vim.wo[state.winid].winbar = ""
		handle_chat_window_closed(state.winid)
		return
	end

	local closed_winid = state.winid
	if state.config.layout == "float" and state.layout then
		state.layout:unmount()
	else
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			local normal_windows = 0
			for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(state.winid))) do
				if vim.api.nvim_win_get_config(winid).relative == "" then normal_windows = normal_windows + 1 end
			end
			if normal_windows == 1 then
				if state.config.layout == "tab" and #vim.api.nvim_list_tabpages() == 1 then
					vim.cmd("tabnew")
				elseif state.config.layout ~= "tab" then
					-- Closing a diff can leave chat as the tab's only normal window.
					vim.api.nvim_win_call(state.winid, function() vim.cmd("leftabove new") end)
				end
			end
			vim.api.nvim_win_close(closed_winid, true)
		end
	end

	handle_chat_window_closed(closed_winid)
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
	else
		configure_buffer_keymaps(state.bufnr, true)
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

function M.focus_input(context_snapshot, context_error)
	-- Selecting a skill can focus an input that is already open. Focusing the
	-- chat window first would trigger the input's WinLeave handler and close it.
	if input.is_visible() and input.owner_view() == view and not get_relevant_question() then return input.focus() end
	if not context_snapshot and not context_error then context_snapshot, context_error = input.capture_context() end
	if not state.visible then
		M.open()
	end
	M.focus()
	local qstate = get_relevant_question()
	if qstate then
		local pos = state.questions[qstate.request_id]
		if pos and state.winid and vim.api.nvim_win_is_valid(state.winid) then
			local line_count = vim.api.nvim_buf_line_count(state.bufnr)
			vim.api.nvim_win_set_cursor(state.winid, { math.min(pos.start_line + 1, line_count), 0 })
		end
		vim.notify("Answer or cancel the pending question before opening chat input.", vim.log.levels.INFO)
		return false
	end
	if cs.module(view, require("opencode.ui.chat.pending_inputs")).resume_edit(context_snapshot, context_error) then return true end

	local owner_session = cs.session(view).id
	local generation = view.generation
	local shown = input.show({
		view = view, session_id = owner_session,
		winid = state.winid,
		float_dims = state.float_dims,
		allow_chat_commands = true,
		context_snapshot = context_snapshot,
		context_error = context_error,
		on_send = function(text, parts, draft_options)
			if not cs.valid(view, generation) then return end
			local send_session = view.session_bound and owner_session or cs.session(view).id
			draft_options = vim.tbl_extend("force", draft_options or {}, { session_id = send_session or false, view = view })
			local actions = require("opencode.actions")
			if draft_options and draft_options.mode == "shell" then
				return actions.send(text, vim.tbl_extend("force", draft_options, { parts = parts }))
			end
			local slash_ok, slash = pcall(require, "opencode.slash")
			local has_parts = type(parts) == "table" and #parts > 0
			if slash_ok and type(slash.parse) == "function" and type(slash.execute) == "function" then
				local parsed = slash.parse(text)
				if parsed then
					local command = require("opencode.command_registry").get_slash(parsed.command)
					if has_parts and command and command.with_parts == "reject" then
						require("opencode.ui.input.history").set_pending(text, parts, send_session or "")
						vim.notify(command.parts_error or ("/" .. parsed.command .. " does not support attachments"), vim.log.levels.WARN)
						return
					end
					-- Slash-like text with attachments remains a prompt unless the
					-- command explicitly accepts them as a draft-only action.
					if not has_parts or (command and command.with_parts == "execute") then
						local owner_session_id = cs.session(view).id
						local context = {
							source = "slash_submit", view = view, generation = generation,
							args = parsed.args,
							parsed = parsed,
							session_id = owner_session_id,
							resume_input = function()
								if cs.valid(view, generation) and cs.session(view).id == owner_session_id and M.is_visible() then
									M.focus_input()
								end
							end,
						}
						if command and command.on_select then
							-- The input closes after on_send returns. Run actions that
							-- open another view after its teardown.
							vim.schedule(function()
								if cs.valid(view, generation) and cs.session(view).id == owner_session_id then
									slash.execute(parsed, context)
								end
							end)
						else
							slash.execute(parsed, context)
						end
						return
					end
				end
			end
			actions.send(text, vim.tbl_extend("force", draft_options or {}, { parts = parts }))
		end,
		on_cancel = function()
			M.focus()
		end,
	})
	return shown ~= false
end

function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", get_config(), opts or {})
	configure_buffer_keymaps(state.bufnr)
end

-- ─── Local notices and view reset ────────────────────────────────────────────

---@param role string
---@param content string
---@param opts? table
function M.add_message(role, content, opts)
	return chat_messages.add_message(role, content, opts)
end

function M.clear()
	return chat_messages.clear()
end

---@param session_id string|nil
function M.clear_session_view(session_id)
	return chat_messages.clear_session_view(session_id)
end

-- ─── Line tracking ────────────────────────────────────────────────────────────

local function shift_tracked_lines(old_end, delta, skip_stream_block_key)
	widget_support.shift_tracked_lines(old_end, delta, {
		skip_stream_block_key = skip_stream_block_key,
	})
end

function M.update_stream_part_block(session_id, message_id, part_id)
	if not session_id or not message_id then
		return false
	end
	if not part_id then
		return false
	end
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return false
	end

	local sync = require("opencode.sync")
	local part = sync.get_part(message_id, part_id)
	if not part or (part.type ~= "text" and part.type ~= "reasoning") then
		return false
	end
	local effective_session_id = session_id
	if part.sessionID and part.sessionID ~= effective_session_id then
		return false
	end

	if part.type == "reasoning" then
		for id, pos in pairs(state.tools) do
			if pos.activity_group and pos.session_id == effective_session_id then
				for _, ref in ipairs(pos.activity_group.refs) do
					if ref.part.id == part_id and ref.message.id == message_id then
						local cursor = capture_widget_cursor_context()
						local scroll = should_auto_scroll(cursor)
						local updated = chat_tasks.rerender_tool(id)
						if updated then
							if not restore_widget_cursor_context(cursor) and scroll then chat_cursor.scroll_to_bottom() end
							redraw()
						end
						return updated
					end
				end
			end
		end
		return false
	end

	local block_key = stream_block_key(effective_session_id, message_id, part_id, part.type)
	local block = block_key and state.stream_blocks[block_key]
	if not block then
		return false
	end
	if not widget_support.can_update_in_place(block) then
		return false
	end
	if
		block.session_id ~= effective_session_id
		or block.message_id ~= message_id
		or block.part_id ~= part_id
		or block.kind ~= part.type
	then
		return false
	end
	local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)
	if
		type(block.start_line) ~= "number"
		or type(block.end_line) ~= "number"
		or block.start_line < 0
		or block.end_line < block.start_line
		or block.start_line >= buf_line_count
		or block.end_line >= buf_line_count
	then
		if block_key then
			state.stream_blocks[block_key] = nil
		end
		return false
	end

	local widget_cursor = capture_widget_cursor_context()
	local should_scroll = should_auto_scroll(widget_cursor)

	local function finish_stream_update()
		if apply_widget_focus_cursor and apply_widget_focus_cursor() then
			redraw()
			return true
		end

		if restore_widget_cursor_context(widget_cursor) then
			redraw()
			return true
		end

		if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
			chat_cursor.scroll_to_bottom()
		end

		redraw()
		return true
	end

	local content = part.text or ""
	local content_lines = render.render_content(content, {
		highlight_code = render_state.code_highlighter(render_state.render_cache_key(effective_session_id, message_id, part_id)),
	})
	-- An authoritative replacement can remove the entire Markdown part.
	-- Rebuild its surrounding margins/ranges rather than leaving a phantom row.
	if #content_lines == 0 then return false end
	if block.trailing_separator then
		while #content_lines > 0 and content_lines[#content_lines]:content() == ""
			and not content_lines[#content_lines]._opencode_preserve_blank do
			table.remove(content_lines)
		end
		table.insert(content_lines, NuiLine())
	end
	local replacement = render.extract_lines(content_lines)

	local old_end = block.end_line
	local old_count = old_end - block.start_line + 1
	local new_count = #replacement
	local delta = new_count - old_count

	local replaced = render_state.replace_chat_range({
		bufnr = state.bufnr,
		start_line = block.start_line,
		end_line = old_end + 1,
		lines = replacement,
		apply_highlights = function()
			chat_highlights.apply_highlights(content_lines, state.bufnr, chat_hl_ns, block.start_line)
		end,
	})
	if not replaced then
		return false
	end

	block.end_line = block.start_line + new_count - 1
	shift_tracked_lines(old_end, delta, block_key)

	local result = finish_stream_update()
	return result
end

-- ─── Main render ─────────────────────────────────────────────────────────────

---Build full buffer content using NuiLine components.
---@return string[] raw_lines, NuiLine[] nui_lines, table[] content_highlights
function M.render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return {}, {}, {}
	end

	local app_state = require("opencode.state")
	local current_session = cs.session(view)
	local ctx = render_context.new({
		view = view,
		current_session = current_session,
		in_child_session_view = #state.session_stack > 0,
		chat_config = state.config or get_config(),
	})

	-- render() fully rebuilds these maps each frame; stale ranges can
	-- otherwise make cursor-driven widget selection target removed widgets.
	ctx:reset_tracking()

	edit_previews.sync_session(current_session.id)

	local index = widget_index.new({
		current_session = current_session,
		in_child_session_view = ctx.in_child_session_view,
	})
	message_renderer.render(ctx, index)
	ctx:commit_stream_blocks()

	return ctx.raw_lines, ctx.nui_lines, ctx.content_highlights
end

-- ─── Render engine ────────────────────────────────────────────────────────────

function M.update_spinner_only()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end
	if not state.visible then
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

local function apply_scheduled_render()
	local data = pending_render_data
	pending_render_data = nil
	if not render_coordinator.request_relevant(data, cs.session(view).id) then
		M.update_winbar()
		return
	end
	if not chat_surface_is_visible() then
		state.transcript_dirty = true
		state.force_full_render = true
		M.update_winbar()
		return
	end
	if (data and data.force) or state.transcript_dirty then state.force_full_render = true end
	state.last_render_time = vim.uv.now()
	M.do_render()
end

---@param opts? table { force?: boolean }
function M.schedule_render(opts)
	if not cs.valid(view) then return end
	pending_render_data = render_coordinator.merge_requests(pending_render_data, opts)
	if state.render_scheduled then
		return
	end

	local now = vim.uv.now()
	local elapsed = now - state.last_render_time

	if elapsed >= RENDER_THROTTLE_MS then
		apply_scheduled_render()
	else
		state.render_scheduled = true
		render_schedule_token = render_schedule_token + 1
		local token = render_schedule_token
		local delay = RENDER_THROTTLE_MS - elapsed
		vim.defer_fn(function()
			if token ~= render_schedule_token then return end
			state.render_scheduled = false
			apply_scheduled_render()
		end, delay)
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
	if not cs.valid(view) then return end
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end
	-- A synchronous refresh already includes all stored changes. An older
	-- throttle callback must not consume requests queued after this refresh.
	render_schedule_token = render_schedule_token + 1
	pending_render_data = nil
	state.render_scheduled = false
	local render_generation = (state.render_generation or 0) + 1
	state.render_generation = render_generation
	state.render_in_progress = true
	local function mark_render_applied()
		if state.render_generation == render_generation then
			state.applied_render_generation = render_generation
		end
		render_retry_used = false
		render_retry_token = render_retry_token + 1
		state.render_in_progress = false
		state.transcript_dirty = false
	end

	local ok, render_error = xpcall(function()
		chat_tasks.clear_animation_extmarks(state.bufnr)
		local force_full_render = state.force_full_render == true
		state.force_full_render = false
		M.update_winbar()

		local widget_cursor = capture_widget_cursor_context()
		local should_scroll = should_auto_scroll(widget_cursor)

		local new_lines, nui_lines, content_highlights = M.render()
		resume_render_animation_timers()
		local highlight_signature = nil
		local function current_highlight_signature()
			if highlight_signature == nil then
				highlight_signature = render_highlight_signature(content_highlights)
			end
			return highlight_signature
		end

		local function apply_render_highlights(changed_start)
			if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
				return
			end

			local requested_start = tonumber(changed_start) or 0
			local dirty_start = tonumber(state.render_highlights_dirty_start)
			if dirty_start then
				requested_start = math.min(requested_start, dirty_start)
			end

			local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)
			local clear_start = highlight_clear_start(requested_start, content_highlights)
			clear_chat_highlights(state.bufnr, clear_start, -1)

			chat_highlights.apply_nui_line_highlights(nui_lines, state.bufnr, chat_hl_ns, 0, {
				min_line = clear_start,
				max_line = buf_line_count,
			})

			local function apply_widget_extmarks(line_map)
				for _, pos in pairs(line_map) do
					if pos.highlights then
						chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, pos.highlights, pos.start_line, {
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
			chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, content_highlights, 0, {
				min_line = clear_start,
				max_line = buf_line_count,
			})
			state.last_render_highlight_signature = current_highlight_signature()
			state.render_highlights_dirty_start = nil
		end

		if #new_lines == 0 or #nui_lines == 0 then
			vim.bo[state.bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
			clear_chat_highlights(state.bufnr, 0, -1)
			vim.bo[state.bufnr].modifiable = false
			state.last_render_highlight_signature = nil
			state.render_highlights_dirty_start = nil
			if apply_widget_focus_cursor() then
				redraw()
			end
			mark_render_applied()
			return
		end

		local old_lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
		local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)


		local function finish_changed_render()
			if apply_widget_focus_cursor() then
				redraw()
				mark_render_applied()
				return
			end

			if restore_widget_cursor_context(widget_cursor) then
				redraw()
				mark_render_applied()
				return
			end

			if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
				chat_cursor.scroll_to_bottom()
			end

			redraw()
			mark_render_applied()
		end
		if force_full_render then
			vim.bo[state.bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
			apply_render_highlights(0)
			vim.bo[state.bufnr].modifiable = false

			finish_changed_render()
			return
		end

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
				if state.last_render_highlight_signature ~= current_highlight_signature() then
					apply_render_highlights(state.render_highlights_dirty_start or 0)
				end
				if apply_widget_focus_cursor() then
					redraw()
				end
				mark_render_applied()
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

		finish_changed_render()
	end, function(err)
		return err
	end)

	if not ok then
		reset_chat_surface()
		state.force_full_render = true
		logger.error("Chat render failed", { error = render_error })
		if not render_retry_used then
			render_retry_used = true
			render_retry_token = render_retry_token + 1
			local retry_token = render_retry_token
			vim.schedule(function()
				if render_retry_token == retry_token and render_retry_used then
					M.schedule_render({ force = true })
				end
			end)
		end
	end
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.bo[state.bufnr].modifiable = false
	end
	state.render_in_progress = false
end

-- ─── Cross-domain key routers ─────────────────────────────────────────────────

function M.sync_widget_selection_from_cursor()
	return chat_interactions.sync_widget_selection_from_cursor()
end

function M.handle_widget_message()
	return chat_interactions.handle_widget_message()
end

-- ─── Re-exports from sub-modules ─────────────────────────────────────────────

-- Questions
M.update_question_status = chat_questions.update_question_status
M.get_question_at_cursor = chat_questions.get_question_at_cursor
M.rerender_question = chat_questions.rerender_question
M.submit_question_answers = chat_questions.submit_question_answers
M.clear_questions = chat_questions.clear_questions
M.debug_questions = chat_questions.debug_questions
M.get_pending_question_count = chat_questions.get_pending_question_count
M.has_pending_questions = chat_questions.has_pending_questions

-- Permissions
M.update_permission_status = chat_permissions.update_permission_status
M.get_permission_at_cursor = chat_permissions.get_permission_at_cursor
M.rerender_permission = chat_permissions.rerender_permission
M.handle_permission_confirm = chat_permissions.handle_permission_confirm
M.handle_permission_reject = chat_permissions.handle_permission_reject

-- Edits
M.get_edit_at_cursor = chat_edits.get_edit_at_cursor
M.get_diffable_edit_at_cursor = chat_edits.get_diffable_edit_at_cursor
M.rerender_edit = chat_edits.rerender_edit
M.finalize_edit = chat_edits.finalize_edit
M.open_inline_diff_split = chat_edits.open_inline_diff_split

-- Tasks / tools
M.get_task_at_cursor = chat_tasks.get_task_at_cursor
M.get_tool_at_cursor = chat_tasks.get_tool_at_cursor
M.handle_task_toggle = chat_tasks.handle_task_toggle
M.rerender_tool = chat_tasks.rerender_tool
M.handle_tool_toggle = chat_tasks.handle_tool_toggle

-- Session navigation
M.enter_child_session = chat_nav.enter_child_session
M.leave_child_session = chat_nav.leave_child_session

return M

end)

local M = { for_view = instances.for_view }
local creating_split = false
for name, method in pairs(instances) do
	if type(method) == "function" and name ~= "for_view" then
		M[name] = function(...) return instances.for_view(cs.current())[name](...) end
	end
end

function M.get_view() return cs.current() end

local function remember_return_window()
	if vim.api.nvim_get_current_tabpage() ~= cs.workspace.tabpage then
		cs.workspace.return_winid = vim.api.nvim_get_current_win()
	end
end

function M.focus_view(view)
	if view and view.suspended then
		require("opencode.ui.chat.workspace").select(view.workspace_id)
	end
	if not cs.valid(view) or not view.winid or not vim.api.nvim_win_is_valid(view.winid) then return false end
	if view.session_bound and view.config and view.config.layout == "tab"
		and vim.api.nvim_win_get_buf(view.winid) ~= view.bufnr then
		local ok, details = pcall(require, "opencode.ui.chat.execute_details")
		if ok then details = cs.module(view, details) end
		local showing_details = ok and details.is_open() and vim.tbl_contains(details.get_winids(), view.winid)
		if not showing_details then
			-- Detach an ordinary file without replacing it; close can recover a surviving mirror.
			instances.for_view(view).close()
			if not cs.valid(view) or not cs.is_chat_buffer_displayed(view) then return false end
		end
	end
	if view.config and view.config.layout == "tab" then remember_return_window() end
	local input = require("opencode.ui.input")
	local owner = input.owner_view()
	if owner and owner ~= view then require("opencode.ui.input").close_for_view(owner) end
	cs.activate(view)
	vim.api.nvim_set_current_win(view.winid)
	require("opencode.actions").activate_chat_view(view)
	instances.for_view(view).schedule_render({ force = view.transcript_dirty })
	return true
end

function M.bind_session(view, session, opts)
	view = view or cs.current()
	if not cs.valid(view) then return false end
	if not view.session_bound then
		return require("opencode.actions").set_active_session(session and session.id, session and (session.title or session.name), opts)
	end
	local previous = cs.session(view).id
	require("opencode.actions").observe_session(previous, false)
	instances.for_view(view).session_changed(session or {}, opts)
	if view.workspace_id then require("opencode.ui.chat.workspace").session_changed(view, session or {}) end
	if cs.current() == view then
		require("opencode.actions").activate_chat_view(view)
	end
	return true
end

function M.open()
	local app = require("opencode.state")
	local config = (app.get_config() or {}).chat or {}
	if config.layout == "tab" then
		remember_return_window()
		local last = cs.workspace.last_view
		if last and M.focus_view(last) then return end
		for _, view in ipairs(cs.all()) do
			if view.config and view.config.layout == "tab" and M.focus_view(view) then return end
		end
		require("opencode.actions").refresh_session_scope()
		local view = cs.state
		local session = app.get_session()
		local retained = last or view
		-- q keeps the session; x and a directory scope change remove its membership.
		if not session.id and retained.session_bound and app.is_runtime_session(retained.session_id) then
			session = cs.session(retained)
		end
		view.session_id, view.session_name = session.id, session.name
		view.session_bound = true
		instances.for_view(view).create()
		instances.for_view(view).open()
		M.focus_view(view)
		require("opencode.ui.chat.workspace").ensure(view)
		return
	end
	return instances.for_view(cs.current()).open()
end

function M.focus()
	M.open()
	local view = cs.current()
	if view.config and view.config.layout == "tab" then return M.focus_view(view) end
	return instances.for_view(view).focus()
end

function M.create_split(parent, session, direction)
	local previous
	if parent and parent.suspended then
		local workspace = require("opencode.ui.chat.workspace")
		previous = workspace.current()
		workspace.select(parent.workspace_id)
	end
	if not cs.valid(parent) or not parent.visible or not parent.winid or not vim.api.nvim_win_is_valid(parent.winid) then return end
	local view = cs.new()
	view.workspace_id = parent.workspace_id
	view.config = vim.deepcopy(parent.config)
	view.session_id, view.session_name = session.id, session.title or session.name
	local chat = instances.for_view(view)
	chat.create()
	creating_split = true
	local ok, err = pcall(function()
		require("opencode.context").preserve_source(function()
			vim.api.nvim_win_call(parent.winid, function()
				vim.cmd(direction == "vertical" and "rightbelow vsplit" or "rightbelow split")
				chat.attach_window(vim.api.nvim_get_current_win())
			end)
		end)
	end)
	creating_split = false
	if not ok then
		chat.close()
		chat.dispose()
		cs.remove(view)
		vim.notify("Could not split OpenCode: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	M.focus_view(view)
	if previous then require("opencode.ui.chat.workspace").select(previous.id) end
	return view
end

function M.create_layout(session)
	return require("opencode.ui.chat.workspace").create(session)
end

function M.after_close()
	if cs.workspace.switching then return end
	local workspace = package.loaded["opencode.ui.chat.workspace"]
	if workspace then workspace.after_close() end
	local view = cs.current()
	if view.visible and view.winid and vim.api.nvim_win_is_valid(view.winid) then
		require("opencode.actions").activate_chat_view(view)
	else
		require("opencode.actions").set_active_session(nil, nil, { reason = "pane_focus", preserve_cache = true })
	end
	local has_chat = false
	for _, other in ipairs(cs.all()) do
		if other.visible and other.tabpage == cs.workspace.tabpage then has_chat = true; break end
	end
	-- The last view remains a reopening hint, even after its windows are gone.
	if not has_chat and (not workspace or #workspace.list() == 0) then cs.workspace.tabpage = nil end
end

function M.close_view(view, opts)
	if not cs.valid(view) then return end
	require("opencode.actions").observe_session(cs.session(view).id, false)
	if view.suspended then
		view.suspended = nil
		view.workspace_id = nil
		instances.for_view(view).dispose()
		cs.remove(view)
		M.after_close()
		return
	end
	if opts and opts.all_windows then
		local windows = cs.windows(view)
		if view.winid and not vim.tbl_contains(windows, view.winid) then windows[#windows + 1] = view.winid end
		for _, win in ipairs(windows) do
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_call(win, function() instances.for_view(view).close() end)
			end
		end
	else
		instances.for_view(view).close()
	end
	if view.config and view.config.layout == "tab" then M.after_close() end
end

function M.close() return M.close_view(cs.current()) end

function M.toggle()
	local config = (require("opencode.state").get_config() or {}).chat or {}
	if config.layout ~= "tab" then return instances.for_view(cs.current()).toggle() end
	if vim.api.nvim_get_current_tabpage() ~= cs.workspace.tabpage then return M.open() end
	require("opencode.ui.input").close_for_view(cs.current())
	local target = cs.workspace.return_winid
	if target and vim.api.nvim_win_is_valid(target) and vim.api.nvim_win_get_tabpage(target) ~= cs.workspace.tabpage then
		vim.api.nvim_set_current_win(target)
		return
	end
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		if tab ~= cs.workspace.tabpage then vim.api.nvim_set_current_tabpage(tab); return end
	end
	vim.cmd("tabnew")
	cs.workspace.return_winid = vim.api.nvim_get_current_win()
end

local focus_group = vim.api.nvim_create_augroup("OpenCodeChatViewFocus", { clear = true })
vim.api.nvim_create_autocmd({ "WinEnter", "TabEnter", "BufWinEnter" }, {
	group = focus_group,
	callback = function()
		if creating_split or cs.workspace.switching then return end
		local win = vim.api.nvim_get_current_win()
		local view = cs.for_window(win)
		if not view or not view.session_bound then return end
		local function focus()
			local input = require("opencode.ui.input")
			local owner = input.owner_view()
			if owner and (owner ~= view or view.winid ~= win) then input.close_for_view(owner) end
			if view.winid ~= win or not view.visible then instances.for_view(view).attach_window(win) end
			cs.activate(view)
			require("opencode.actions").activate_chat_view(view)
		end
		if view.winid ~= win or not view.visible then
			-- :new and :tabnew briefly inherit the old buffer before replacing it.
			vim.schedule(function()
				if cs.valid(view) and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win
					and vim.api.nvim_win_get_buf(win) == view.bufnr then focus() end
			end)
			return
		end
		focus()
	end,
})

return M
