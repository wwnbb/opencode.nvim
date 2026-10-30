local cs = require("opencode.ui.chat.state")
local instances = cs.factory("init", function(view)
-- opencode.nvim - Chat buffer UI module
-- Main chat interface with configurable layouts
-- This module mirrors the TUI's session/index.tsx rendering approach

local M = {}

local NuiLine = require("nui.line")
local input = require("opencode.ui.input")
local chat_help = cs.module(view, require("opencode.ui.chat.help"))
local chat_float_focus = cs.module(view, require("opencode.ui.chat.float_focus"))
local window = cs.module(view, require("opencode.ui.chat.window"))
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

local render = cs.module(view, require("opencode.ui.chat.render"))
local chat_highlights = require("opencode.ui.chat.highlights")
local ui_highlights = require("opencode.ui.highlights")
ui_highlights.register("opencode.ui.chat.padding", function()
	vim.api.nvim_set_hl(0, "OpenCodeChatPadding", { default = true })
end)
local render_state = cs.module(view, require("opencode.ui.chat.render_state"))
local render_context = cs.module(view, require("opencode.ui.chat.render_context"))
local render_coordinator = require("opencode.ui.chat.render_coordinator")
local widget_index = cs.module(view, require("opencode.ui.chat.widget_index"))
local message_renderer = cs.module(view, require("opencode.ui.chat.message_renderer"))
local edit_previews = cs.module(view, require("opencode.ui.chat.edit_previews"))
local chat_cursor = cs.module(view, require("opencode.ui.chat.cursor"))
local chat_tasks = cs.module(view, require("opencode.ui.chat.tasks"))
local chat_interactions = cs.module(view, require("opencode.ui.chat.interactions"))
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
local subscription_epoch = 0
local winbar_refresh_scheduled = false
local opening = false
local configure_buffer_keymaps

local function unsubscribe()
	-- Invalidate before off(): a failed unsubscribe may already have removed its callback.
	chat_event_handlers_setup = false
	subscription_epoch = subscription_epoch + 1
	for _, item in ipairs(subscriptions) do item.bus.off(item.event, item.callback) end
	subscriptions = {}
end

-- Scheduling follows the transcript buffer in any window. Cursor/detail helpers
-- still follow the owned chat window through cs.is_chat_buffer_displayed(view).
local function chat_surface_is_visible()
	if not cs.valid(view) or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return false end
	for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		if vim.api.nvim_win_get_buf(winid) == state.bufnr then return true end
	end
	return false
end

-- Config and colorscheme changes are global, so they also drop shared memo pools.
local function invalidate_cached_render_state()
	render_state.clear_render_cache()
	render_state.clear_code_cache()
	require("opencode.util.memo").clear_all()
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

local function schedule_resize_refresh(_, windows)
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
M.stop_spinner_animation_timer = stop_spinner_animation_timer

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

-- Unbound views switch through the session_change event, bound panes through
-- session_changed (which ignores same-session rebinds); both reset the surface
-- here. Navigation keeps the stack it prepared; preserve_cache keeps render caches.
local NAVIGATION_REASONS = { child_navigation = true, family_navigation = true }

local function apply_session_switch(changed_session, opts)
	local preserve_cache = opts.preserve_cache
	if not preserve_cache or changed_session then
		stop_spinner_animation_timer()
		chat_tasks.stop_task_animation_timer()
	end
	reset_chat_surface({
		reset_expansions = not preserve_cache or (changed_session and opts.reason ~= "child_navigation"),
		preserve_render_cache = preserve_cache == true,
		force_full_render = not preserve_cache or changed_session,
	})
	if not NAVIGATION_REASONS[opts.reason] and (not preserve_cache or changed_session) then
		state.session_stack = {}
	end
	if changed_session and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_call(state.winid, function()
			vim.fn.winrestview({ topline = 1, leftcol = 0, skipcol = 0 })
		end)
	end
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

	-- Also finish a partially completed disposal before rebuilding these handlers.
	unsubscribe()
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
	-- The extra hop lets same-tick session_change handlers reset the surface first.
	subscribe("chat_render", function(data)
		if not cs.valid(view) then return end
		local epoch = subscription_epoch
		vim.schedule(function()
			if epoch == subscription_epoch then M.schedule_render(data) end
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
		local changed_session = data and data.previous_id ~= data.id
		local opts = { preserve_cache = data and data.preserve_cache, reason = data and data.reason }
		vim.schedule(function()
			apply_session_switch(changed_session, opts)
		end)
	end)
	chat_event_handlers_setup = true
	chat_event_handlers_events = events
	chat_event_handlers_generation = listener_generation
	end

	M.do_render()

	return state.bufnr
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

local function request_focus_for_pending_widgets()
	local qstate = get_relevant_question()
	-- A question that cannot take focus (one being confirmed) leaves it to the widgets below.
	if qstate and widget_support.request_focus("question", qstate.request_id, qstate.status) then
		return true
	end
	local current_session = cs.session(view)
	local in_child_session_view = #state.session_stack > 0
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
	-- Cache keys carry width, revisions and syntax generation; a reopen reuses them.
	reset_chat_surface({ preserve_render_cache = true })
	stop_spinner_animation_timer()
	chat_tasks.stop_task_animation_timer()
	require("opencode.ui.chat").retire_view(view, { dispose = view ~= cs.state })
	vim.schedule(function()
		if state.config and state.config.layout == "tab" then
			require("opencode.ui.chat").after_close()
		end
	end)
end

function M.dispose()
	-- Retire a pending throttled render; it would otherwise observe a disposed view.
	render_schedule_token = render_schedule_token + 1
	pending_render_data = nil
	state.render_scheduled = false
	local ok, err = xpcall(function()
		stop_spinner_animation_timer()
		chat_tasks.stop_task_animation_timer()
		unsubscribe()
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
	end, debug.traceback)
	if not ok then
		-- Callers retain ownership on failure, so their view must still receive events.
		local restored, restore_error = xpcall(M.create, debug.traceback)
		if not restored then err = err .. "\nCould not restore chat after disposal: " .. restore_error end
		error(err, 0)
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
	reset_chat_surface({ preserve_render_cache = true })

	window.show(state.config, {
		on_closed = handle_chat_window_closed,
		attach = M.attach_window,
		update_winbar = M.update_winbar,
		close = M.close,
	})

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
	window.setup_options(winid)
	window.watch_closed(winid, handle_chat_window_closed)
	M.update_winbar()
	M.do_render()
end

function M.session_changed(session, opts)
	opts = opts or {}
	local previous = cs.session(view).id
	input.close_for_view(view)
	state.session_id, state.session_name, state.session_bound = session.id, session.title or session.name, true
	state.generation = (state.generation or 0) + 1
	if previous ~= session.id then apply_session_switch(true, opts) end
	M.schedule_render({ session_id = session.id, force = true })
end

-- A user may have replaced the transcript with an ordinary file. Leave the file
-- in its window and close the view there (a surviving mirror takes it over).
---@return boolean detached
function M.detach_replaced_window()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid)
		or vim.api.nvim_win_get_buf(state.winid) == state.bufnr then return false end
	vim.wo[state.winid].winbar = ""
	handle_chat_window_closed(state.winid)
	return true
end

function M.close()
	local current = vim.api.nvim_get_current_win()
	if view.session_bound and state.config.layout == "tab"
		and cs.for_window(current) == view and vim.api.nvim_win_get_buf(current) == state.bufnr then
		state.winid, state.tabpage, state.visible = current, vim.api.nvim_win_get_tabpage(current), true
	end
	if not state.visible then
		chat_session_tabs.close_float_window()
		reset_chat_surface({ preserve_render_cache = true })
		return
	end

	chat_float_focus.clear()
	chat_session_tabs.close_float_window()

	input.close_for_view(view)
	local details = package.loaded["opencode.ui.chat.execute_details"]
	if details then cs.module(view, details).close(false) end
	if M.detach_replaced_window() then return end

	local closed_winid = state.winid
	local delegated, result = window.close_native()
	if delegated then return result end

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
	if get_config().layout == "tab" then
		local chat = require("opencode.ui.chat")
		-- Register or restore the whole workspace before mounting its composer.
		if not chat.focus_view(view) then chat.open() end
		if cs.current() ~= view then return chat.focus_input(context_snapshot, context_error) end
	else
		M.focus()
	end
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
	stop_spinner_animation_timer()
	return chat_messages.clear()
end

---@param session_id string|nil
function M.clear_session_view(session_id)
	return chat_messages.clear_session_view(session_id)
end

-- ─── Line tracking ────────────────────────────────────────────────────────────

-- Every frame ends the same way: a pending widget focus or a restored widget
-- cursor wins over auto-scroll, then the screen is redrawn.
local function finish_frame(widget_cursor, should_scroll)
	if (apply_widget_focus_cursor and apply_widget_focus_cursor()) or restore_widget_cursor_context(widget_cursor) then
		redraw()
		return
	end
	if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		chat_cursor.scroll_to_bottom()
	end
	redraw()
end

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
		finish_frame(widget_cursor, should_scroll)
		return true
	end

	local content = part.text or ""
	local content_lines = render.render_content(content, {
		highlight_code = render_state.code_highlighter(render_state.render_cache_key(effective_session_id, message_id, part_id)),
		streaming = true,
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

	-- Same-width glyph swap: the applied highlight frame still describes the buffer.
	local applied = state.last_render_highlight_signature
	local tick = vim.api.nvim_buf_get_changedtick(state.bufnr)
	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_text(state.bufnr, footer_line, 0, footer_line, current_frame_bytes, { next_frame })
	vim.bo[state.bufnr].modifiable = false
	if applied and applied.tick == tick and #next_frame == current_frame_bytes then
		applied.tick = vim.api.nvim_buf_get_changedtick(state.bufnr)
	end
end

local RENDER_THROTTLE_MS = 16
local RENDER_THROTTLE_MAX_MS = 200
local RENDER_COST_SAMPLES = 3

-- Median of the recent render costs: one slow frame (a cold full render) does
-- not throttle the next ones, two in a row do. With two samples the lower wins.
local function render_cost()
	local samples = vim.list_slice(state.render_durations or {})
	if #samples == 0 then return 0 end
	table.sort(samples)
	return samples[math.ceil(#samples / 2)]
end

local function record_render_cost(duration)
	state.last_render_duration = duration
	local samples = state.render_durations or {}
	samples[#samples + 1] = duration
	if #samples > RENDER_COST_SAMPLES then table.remove(samples, 1) end
	state.render_durations = samples
end

-- Measured from the end of the previous render, so a slow frame cannot be
-- followed immediately by another one.
local function render_interval()
	return math.min(RENDER_THROTTLE_MAX_MS, math.max(RENDER_THROTTLE_MS, 2 * render_cost()))
end

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
	M.do_render()
end

---@param opts? table { force?: boolean }
function M.schedule_render(opts)
	if not cs.valid(view) then return end
	pending_render_data = render_coordinator.merge_requests(pending_render_data, opts)
	-- A user's own action shows its result now; a throttled frame folds into it.
	if pending_render_data.immediate then
		render_schedule_token = render_schedule_token + 1
		state.render_scheduled = false
		apply_scheduled_render()
		return
	end
	if state.render_scheduled then
		return
	end

	local elapsed = vim.uv.now() - (state.last_render_time or 0)
	local interval = render_interval()

	if elapsed >= interval then
		apply_scheduled_render()
	else
		state.render_scheduled = true
		render_schedule_token = render_schedule_token + 1
		local token = render_schedule_token
		vim.defer_fn(function()
			if token ~= render_schedule_token or not cs.valid(view) then return end
			state.render_scheduled = false
			apply_scheduled_render()
		end, interval - elapsed)
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
	local render_started = vim.uv.hrtime()
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
		local frame = render_state.highlight_frame(content_highlights, nui_lines)

		-- Half-open [range_start, range_end); callers clear the range first.
		local function apply_range_highlights(range_start, range_end)
			local range = { min_line = range_start, max_line = range_end }
			chat_highlights.apply_nui_line_highlights(nui_lines, state.bufnr, chat_hl_ns, 0, range)
			for _, line_map in ipairs(frame.maps) do
				for _, pos in pairs(line_map) do
					if pos.highlights then
						chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, pos.highlights, pos.start_line, range)
					end
				end
			end
			chat_highlights.apply_extmark_highlights(state.bufnr, chat_hl_ns, content_highlights, 0, range)
		end

		local function record_applied_highlights(previous)
			frame.bufnr = previous and previous.bufnr or state.bufnr
			frame.tick = previous and previous.tick or vim.api.nvim_buf_get_changedtick(state.bufnr)
			state.last_render_highlight_signature = frame
			state.render_highlights_dirty_start = nil
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

			local clear_start = render_state.extend_highlight_range(frame, requested_start)
			clear_chat_highlights(state.bufnr, clear_start, -1)
			apply_range_highlights(clear_start, vim.api.nvim_buf_line_count(state.bufnr))
			record_applied_highlights()
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

		local function finish_changed_render()
			finish_frame(widget_cursor, should_scroll)
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

		local start, old_end, new_end = render_state.diff_lines(old_lines, new_lines)
		local previous = state.last_render_highlight_signature

		if start == old_end and start == new_end then
			if previous and render_state.same_frame_highlights(previous, frame, 0, 0) then
				record_applied_highlights(previous)
			else
				apply_render_highlights(state.render_highlights_dirty_start or 0)
			end
			if apply_widget_focus_cursor() then
				redraw()
			end
			mark_render_applied()
			return
		end

		-- The unchanged tail keeps its extmarks when the previous frame still
		-- describes the buffer and its tail highlights are identical.
		local delta = new_end - old_end
		local range_start, range_end
		if previous and previous.bufnr == state.bufnr
			and previous.tick == vim.api.nvim_buf_get_changedtick(state.bufnr)
			and #previous.nui_lines == #old_lines and state.render_highlights_dirty_start == nil then
			range_start, range_end = start, new_end
			local settled = false
			while not settled do
				local first, last = range_start, range_end
				range_start, range_end = render_state.extend_highlight_range(frame, range_start, range_end)
				local old_last
				range_start, old_last = render_state.extend_highlight_range(previous, range_start, range_end - delta)
				range_end = old_last + delta
				settled = first == range_start and last == range_end
			end
			if not render_state.same_frame_highlights(previous, frame, range_end - delta, range_end, true) then
				range_start = nil
			end
		end

		vim.bo[state.bufnr].modifiable = true
		-- Clear replaced marks first: set_lines would collapse them into the tail.
		local clear_end = range_start and range_end - delta or old_end
		local clear_from = range_start or start
		if clear_end > clear_from then
			vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, clear_from, clear_end)
		end
		vim.api.nvim_buf_set_lines(state.bufnr, start, old_end, false, vim.list_slice(new_lines, start + 1, new_end))
		if range_start then
			apply_range_highlights(range_start, range_end)
			record_applied_highlights()
		else
			apply_render_highlights(start)
		end
		vim.bo[state.bufnr].modifiable = false

		finish_changed_render()
	end, function(err)
		return err
	end)

	if not ok then
		reset_chat_surface()
		require("opencode.util.memo").clear_all()
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
	-- uv.now() is cached for the loop iteration (and drives spinner frames), so
	-- do not refresh it here; add the measured cost to approximate the end time.
	record_render_cost((vim.uv.hrtime() - render_started) / 1e6)
	state.last_render_time = vim.uv.now() + state.last_render_duration
end

-- ─── Cross-domain key routers ─────────────────────────────────────────────────

function M.sync_widget_selection_from_cursor()
	return chat_interactions.sync_widget_selection_from_cursor()
end

function M.handle_widget_message()
	return chat_interactions.handle_widget_message()
end

return M

end)

-- The module-level facade, multi-pane operations and view focus tracking.
return require("opencode.ui.chat.views")(instances)
