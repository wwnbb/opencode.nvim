-- opencode.nvim - Chat buffer UI module
-- Main chat interface with configurable layouts
-- This module mirrors the TUI's session/index.tsx rendering approach

local M = {}

local Popup = require("nui.popup")
local NuiLine = require("nui.line")
local input = require("opencode.ui.input")
local chat_help = require("opencode.ui.chat.help")
local chat_float_focus = require("opencode.ui.chat.float_focus")
local chat_messages = require("opencode.ui.chat.messages")
local chat_keymaps = require("opencode.ui.chat.keymaps")
local chat_session_tabs = require("opencode.ui.chat.session_tabs")
local spinner = require("opencode.ui.spinner")
local locale = require("opencode.util.locale")
local session_util = require("opencode.util.session")
local event_util = require("opencode.events.util")
local actions = require("opencode.actions")

-- ─── Shared state & sub-modules ──────────────────────────────────────────────

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns
local FLOAT_CHAT_TOP_PADDING = 2

local render = require("opencode.ui.chat.render")
local render_state = require("opencode.ui.chat.render_state")
local render_context = require("opencode.ui.chat.render_context")
local widget_index = require("opencode.ui.chat.widget_index")
local message_renderer = require("opencode.ui.chat.message_renderer")
local chat_cursor = require("opencode.ui.chat.cursor")
local chat_tasks = require("opencode.ui.chat.tasks")
local chat_todos = require("opencode.ui.chat.todos")
local chat_questions = require("opencode.ui.chat.questions")
local chat_permissions = require("opencode.ui.chat.permissions")
local chat_edits = require("opencode.ui.chat.edits")
local chat_interactions = require("opencode.ui.chat.interactions")
local chat_nav = require("opencode.ui.chat.nav")
local widget_support = require("opencode.ui.chat.widget_support")
local perf = require("opencode.perf")

chat_messages.set_schedule_render(function(opts)
	M.schedule_render(opts)
end)

local question_state = require("opencode.question.state")
local permission_state = require("opencode.permission.state")
local edit_state = require("opencode.edit.state")
local apply_widget_focus_cursor

-- ─── Configuration ────────────────────────────────────────────────────────────

local defaults = {
	layout = "vertical",
	position = "right",
	width = 80,
	height = 20,
	max_rendered_messages = 60,
	max_user_message_lines = 120,
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

local function is_processing_status(status)
	local status_type = type(status) == "table" and status.type or status
	return status_type == "busy"
		or status_type == "streaming"
		or status_type == "thinking"
		or status_type == "retry"
end

local reset_chat_surface = render_state.reset_chat_surface
local stream_block_key = render_state.stream_block_key
local render_highlight_signature = render_state.render_highlight_signature
local highlight_clear_start = render_state.highlight_clear_start
local clear_chat_highlights = render_state.clear_chat_highlights

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

function M.go_to_session_tab(index)
	return chat_session_tabs.go_to_session_tab(index)
end

function M.cycle_session(direction)
	return chat_session_tabs.cycle_session(direction)
end

-- ─── Float focus autocmds ─────────────────────────────────────────────────────

-- ─── Cursor preservation ──────────────────────────────────────────────────────

local function create_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
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
			if not state.visible or not spinner.is_active() or type(state.spinner_footer_line) ~= "number" then
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
	if spinner.is_active() and type(state.spinner_footer_line) == "number" then
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
	chat_help.show(state.config)
end

function M.create()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end

	state.config = get_config()
	chat_session_tabs.setup_refresh_autocmds()
	state.bufnr = create_buffer()
	state.local_notices = {}
	reset_chat_surface()

	local events = require("opencode.events")

	events.on("chat_render", function(data)
		vim.schedule(function()
			M.schedule_render({
				force = type(data) == "table" and data.force == true,
			})
		end)
	end)

	events.on("chat_stream_part_updated", function(data)
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
			if not state.visible or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
				return
			end
			local current_session = require("opencode.state").get_session()
			if
				session_id
				and current_session.id
				and session_id ~= current_session.id
				and not event_util.permission_session_is_relevant(current_session.id, session_id)
			then
				return
			end
			if
				not M.update_stream_part_block(session_id or current_session.id, message_id, part_id, {
					delta = data and data.delta,
					field = data and data.field,
				})
			then
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
				child_session_id = data.child_session_id,
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
					end
					stop_spinner_animation_timer()
					return
				end

				if not spinner.is_active() then
					spinner.start()
				end
				if state.visible then
					start_spinner_animation_timer()
					chat_tasks.start_task_animation_timer()
				end
			else
				if spinner.is_active() then
					spinner.stop()
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
			local force_full_render = not preserve_cache or changed_session
			reset_chat_surface({
				reset_expansions = not preserve_cache or (changed_session and reason ~= "child_navigation"),
				preserve_render_cache = preserve_cache == true,
				force_full_render = force_full_render,
			})
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

		local popup_winid = popup.winid
		if popup_winid and vim.api.nvim_win_is_valid(popup_winid) then
			vim.api.nvim_create_autocmd("WinClosed", {
				pattern = tostring(popup_winid),
				once = true,
			callback = function()
				if state.winid == popup_winid then
					chat_float_focus.clear()
					chat_todos.close_window()
					chat_session_tabs.close_float_window()
						state.visible = false
						state.winid = nil
						state.tabpage = nil
						state.layout = nil
						state.float_dims = nil
						reset_chat_surface()
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
	state.force_full_render = true
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
		chat_session_tabs.close_float_window()
		reset_chat_surface()
		return
	end

	reset_chat_surface()
	chat_float_focus.clear()
	chat_todos.close_window()
	chat_session_tabs.close_float_window()

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
	return chat_messages.add_message(role, content, opts)
end

function M.render_message(message)
	return chat_messages.render_message(message)
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

function M.update_stream_part_block(session_id, message_id, part_id, opts)
	opts = opts or {}
	if part_id == nil then
		part_id = message_id
		message_id = session_id
		session_id = nil
	end
	if not message_id then
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
	local current_session = require("opencode.state").get_session()
	local effective_session_id = session_id or part.sessionID or current_session.id
	if part.sessionID and effective_session_id and part.sessionID ~= effective_session_id then
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

	local done_stream = perf.start("chat.stream.update_part_block")
	local widget_cursor = capture_widget_cursor_context()
	local should_scroll = should_auto_scroll(widget_cursor)
	local chat_width = render.get_chat_text_width()

	local function finish_stream_update()
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

	local function try_plain_text_append()
		local delta = opts.delta
		if part.type ~= "text" or opts.field ~= "text" or type(delta) ~= "string" or delta == "" then
			return false
		end
		if delta:find("\r", 1, true) or delta:find("\0", 1, true) then
			return false
		end
		if delta:find("\n", 1, true) then
			return false
		end
		if block.chat_width ~= chat_width then
			return false
		end
		if type(block.text_length) ~= "number" then
			return false
		end

		local content = part.text or ""
		if #content ~= block.text_length + #delta then
			return false
		end

		local last_line = vim.api.nvim_buf_get_lines(state.bufnr, block.end_line, block.end_line + 1, false)[1]
		if type(last_line) ~= "string" then
			return false
		end

		local done_set_text = perf.start("chat.stream.plain_text_append.set_text")
		vim.bo[state.bufnr].modifiable = true
		local ok = pcall(
			vim.api.nvim_buf_set_text,
			state.bufnr,
			block.end_line,
			#last_line,
			block.end_line,
			#last_line,
			{ delta }
		)
		vim.bo[state.bufnr].modifiable = false
		done_set_text({ ok = ok, delta_bytes = #delta, line = block.end_line })
		if not ok then
			return false
		end

		block.text_length = #content
		block.chat_width = chat_width
		local result = finish_stream_update()
		done_stream({
			path = "plain_text_append",
			result = result,
			part_id = part_id,
			message_id = message_id,
			delta_bytes = #delta,
			text_bytes = #content,
		})
		return result
	end

	if try_plain_text_append() then
		return true
	end

	local done_stream_render = perf.start("chat.stream.render_replacement")
	local content = part.text or ""
	local content_lines
	if part.type == "reasoning" then
		content_lines = render.render_reasoning(content)
	else
		content_lines = render.render_content(content, { stream_plain = true })
	end
	if #content_lines == 0 then
		local empty = NuiLine()
		empty:append("")
		content_lines = { empty }
	end
	local replacement = render.extract_lines(content_lines)
	done_stream_render({
		part_id = part_id,
		message_id = message_id,
		type = part.type,
		text_bytes = #content,
		lines = #replacement,
	})

	local old_end = block.end_line
	local old_count = old_end - block.start_line + 1
	local new_count = #replacement
	local delta = new_count - old_count

	local done_stream_apply = perf.start("chat.stream.apply_replacement")
	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, block.start_line, old_end + 1, false, replacement)

	local clear_end = math.max(old_end + 1, block.start_line + new_count)
	clear_chat_highlights(state.bufnr, block.start_line, clear_end)
	render.apply_highlights(content_lines, state.bufnr, chat_hl_ns, block.start_line)
	vim.bo[state.bufnr].modifiable = false
	done_stream_apply({
		part_id = part_id,
		message_id = message_id,
		old_lines = old_count,
		new_lines = new_count,
		delta = delta,
	})

	block.end_line = block.start_line + new_count - 1
	block.text_length = #content
	block.chat_width = chat_width
	shift_tracked_lines(old_end, delta, block_key)

	local result = finish_stream_update()
	done_stream({
		path = "replacement",
		result = result,
		part_id = part_id,
		message_id = message_id,
		type = part.type,
		text_bytes = #content,
		old_lines = old_count,
		new_lines = new_count,
		delta = delta,
	})
	return result
end

-- ─── Main render ─────────────────────────────────────────────────────────────

---Build full buffer content using NuiLine components.
---@return string[] raw_lines, NuiLine[] nui_lines, table[] content_highlights
function M.render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return {}, {}, {}
	end

	local done_render_total = perf.start("chat.render.total")
	local app_state = require("opencode.state")
	local current_session = app_state.get_session()
	local ctx = render_context.new({
		current_session = current_session,
		in_child_session_view = #state.session_stack > 0,
		chat_config = state.config or get_config(),
	})

	-- render() fully rebuilds these maps each frame; stale ranges can
	-- otherwise make cursor-driven widget selection target removed widgets.
	ctx:reset_tracking()

	local index = widget_index.new({
		current_session = current_session,
		in_child_session_view = ctx.in_child_session_view,
	})
	local stats = message_renderer.render(ctx, index)
	local stream_block_count = ctx:commit_stream_blocks()

	done_render_total({
		session_id = current_session.id,
		messages = #(stats.all_messages or {}),
		rendered_messages = #(stats.rendered_messages or {}),
		skipped_messages = stats.skipped_messages or 0,
		lines = #ctx.raw_lines,
		highlights = #ctx.content_highlights,
		stream_blocks = stream_block_count,
	})
	return ctx.raw_lines, ctx.nui_lines, ctx.content_highlights
end

-- ─── Render engine ────────────────────────────────────────────────────────────

function M.update_spinner_only()
	local done = perf.start("chat.update_spinner_only")
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		done({ skipped = true, reason = "invalid_buffer" })
		return
	end
	if not state.visible then
		done({ skipped = true, reason = "hidden" })
		return
	end
	if not spinner.is_active() then
		done({ skipped = true, reason = "inactive" })
		return
	end

	local footer_line = state.spinner_footer_line
	if type(footer_line) ~= "number" then
		done({ skipped = true, reason = "missing_footer" })
		return
	end

	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	if footer_line < 0 or footer_line >= buf_lines then
		done({ skipped = true, reason = "footer_out_of_range", footer_line = footer_line, buf_lines = buf_lines })
		return
	end

	local current_line = vim.api.nvim_buf_get_lines(state.bufnr, footer_line, footer_line + 1, false)[1] or ""
	if current_line == "" then
		done({ skipped = true, reason = "empty_line", footer_line = footer_line })
		return
	end

	local second_char = vim.fn.strcharpart(current_line, 1, 1)
	if second_char ~= " " then
		done({ skipped = true, reason = "unexpected_line", footer_line = footer_line })
		return
	end

	local next_frame = spinner.get_frame()
	if next_frame == "" then
		done({ skipped = true, reason = "empty_frame" })
		return
	end

	local current_frame = vim.fn.strcharpart(current_line, 0, 1)
	if current_frame == next_frame then
		done({ skipped = true, reason = "same_frame" })
		return
	end

	local current_frame_bytes = #current_frame
	if current_frame_bytes <= 0 then
		done({ skipped = true, reason = "invalid_frame" })
		return
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_text(state.bufnr, footer_line, 0, footer_line, current_frame_bytes, { next_frame })
	vim.bo[state.bufnr].modifiable = false
	done({ footer_line = footer_line, buf_lines = buf_lines })
end

local RENDER_THROTTLE_MS = 16

---@param opts? table { force?: boolean }
function M.schedule_render(opts)
	local done = perf.start("chat.schedule_render")
	opts = opts or {}
	if opts.force then
		state.force_full_render = true
	end
	if state.render_scheduled then
		done({ skipped = true, reason = "already_scheduled", force = opts.force == true })
		return
	end

	local now = vim.uv.now()
	local elapsed = now - state.last_render_time

	if elapsed >= RENDER_THROTTLE_MS then
		state.last_render_time = now
		done({ path = "immediate", elapsed_since_last_ms = elapsed, force = opts.force == true })
		M.do_render()
	else
		state.render_scheduled = true
		local delay = RENDER_THROTTLE_MS - elapsed
		vim.defer_fn(function()
			state.render_scheduled = false
			state.last_render_time = vim.uv.now()
			M.do_render()
		end, delay)
		done({ path = "deferred", delay_ms = delay, elapsed_since_last_ms = elapsed, force = opts.force == true })
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
	local done_total = perf.start("chat.do_render.total")
	local render_generation = (state.render_generation or 0) + 1
	state.render_generation = render_generation
	state.render_in_progress = true
	local function mark_render_applied()
		if state.render_generation == render_generation then
			state.applied_render_generation = render_generation
		end
		state.render_in_progress = false
	end

	chat_tasks.clear_animation_extmarks(state.bufnr)
	local force_full_render = state.force_full_render == true
	state.force_full_render = false
	local done_winbar = perf.start("chat.do_render.update_winbar")
	M.update_winbar()
	done_winbar({ force_full_render = force_full_render })

	local done_cursor_capture = perf.start("chat.do_render.capture_cursor")
	local widget_cursor = capture_widget_cursor_context()
	local should_scroll = should_auto_scroll(widget_cursor)
	done_cursor_capture({ should_scroll = should_scroll })

	local done_render_call = perf.start("chat.do_render.render_call")
	local new_lines, nui_lines, content_highlights = M.render()
	done_render_call({
		lines = #new_lines,
		nui_lines = #nui_lines,
		highlights = #content_highlights,
	})
	local done_todos = perf.start("chat.do_render.todos_update")
	chat_todos.update_window()
	done_todos({ lines = #new_lines })
	local done_animation_timers = perf.start("chat.do_render.resume_animation_timers")
	resume_render_animation_timers()
	done_animation_timers()
	local highlight_signature = nil
	local function current_highlight_signature()
		if highlight_signature == nil then
			local done_highlight_signature = perf.start("chat.do_render.highlight_signature")
			highlight_signature = render_highlight_signature(content_highlights)
			done_highlight_signature({ highlights = #content_highlights })
		end
		return highlight_signature
	end

	local function apply_render_highlights(changed_start)
		local done_apply = perf.start("chat.do_render.apply_render_highlights")
		if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
			done_apply({ skipped = true, reason = "invalid_buffer" })
			return
		end

		local requested_start = tonumber(changed_start) or 0
		local dirty_start = tonumber(state.render_highlights_dirty_start)
		if dirty_start then
			requested_start = math.min(requested_start, dirty_start)
		end

		local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)
		local done_clear = perf.start("chat.do_render.apply_render_highlights.clear")
		local clear_start = highlight_clear_start(requested_start, content_highlights)
		clear_chat_highlights(state.bufnr, clear_start, -1)
		done_clear({ clear_start = clear_start, buf_line_count = buf_line_count })

		local done_nui_highlights = perf.start("chat.do_render.apply_render_highlights.nui_lines")
		for i = clear_start + 1, #nui_lines do
			local nui_line = nui_lines[i]
			if i <= buf_line_count then
				nui_line:highlight(state.bufnr, chat_hl_ns, i)
			end
		end
		done_nui_highlights({ clear_start = clear_start, lines = #nui_lines })

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

		local done_widget_extmarks = perf.start("chat.do_render.apply_render_highlights.widget_extmarks")
		apply_widget_extmarks(state.questions)
		apply_widget_extmarks(state.permissions)
		apply_widget_extmarks(state.edits)
		apply_widget_extmarks(state.tasks)
		apply_widget_extmarks(state.tools)
		done_widget_extmarks()
		local done_content_extmarks = perf.start("chat.do_render.apply_render_highlights.content_extmarks")
		render.apply_extmark_highlights(state.bufnr, chat_hl_ns, content_highlights, 0, {
			min_line = clear_start,
			max_line = buf_line_count,
		})
		done_content_extmarks({ highlights = #content_highlights, clear_start = clear_start })
		state.last_render_highlight_signature = current_highlight_signature()
		state.render_highlights_dirty_start = nil
		done_apply({
			changed_start = changed_start,
			requested_start = requested_start,
			clear_start = clear_start,
			lines = #nui_lines,
			content_highlights = #content_highlights,
		})
	end

	if #new_lines == 0 or #nui_lines == 0 then
		local done_empty_apply = perf.start("chat.do_render.empty_set_lines")
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
		clear_chat_highlights(state.bufnr, 0, -1)
		vim.bo[state.bufnr].modifiable = false
		done_empty_apply({ lines = #new_lines })
		state.last_render_highlight_signature = nil
		state.render_highlights_dirty_start = nil
		if apply_widget_focus_cursor() then
			vim.cmd("redraw")
		end
		mark_render_applied()
		done_total({ path = "empty", lines = #new_lines, force_full_render = force_full_render })
		return
	end

	local done_get_old_lines = perf.start("chat.do_render.get_old_lines")
	local old_lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)
	done_get_old_lines({ old_lines = #old_lines, buf_line_count = buf_line_count })

	if force_full_render then
		local done_full_set_lines = perf.start("chat.do_render.full_set_lines")
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
		apply_render_highlights(0)
		vim.bo[state.bufnr].modifiable = false
		done_full_set_lines({ lines = #new_lines })

		if apply_widget_focus_cursor() then
			local done_redraw = perf.start("chat.do_render.redraw")
			vim.cmd("redraw")
			done_redraw({ path = "force_focus" })
			mark_render_applied()
			done_total({ path = "force_focus", lines = #new_lines, force_full_render = true })
			return
		end

		if restore_widget_cursor_context(widget_cursor) then
			local done_redraw = perf.start("chat.do_render.redraw")
			vim.cmd("redraw")
			done_redraw({ path = "force_restore_cursor" })
			mark_render_applied()
			done_total({ path = "force_restore_cursor", lines = #new_lines, force_full_render = true })
			return
		end

		if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
			local done_scroll = perf.start("chat.do_render.scroll")
			local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
			vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
			done_scroll({ buf_lines = buf_lines, path = "force" })
		end

		local done_redraw = perf.start("chat.do_render.redraw")
		vim.cmd("redraw")
		done_redraw({ path = "force" })
		mark_render_applied()
		done_total({ path = "force", lines = #new_lines, force_full_render = true })
		return
	end

	local done_diff_scan = perf.start("chat.do_render.diff_scan")
	local first_diff = nil
	local min_len = math.min(#old_lines, #new_lines)
	for i = 1, min_len do
		if old_lines[i] ~= new_lines[i] then
			first_diff = i - 1
			break
		end
	end
	done_diff_scan({ old_lines = #old_lines, new_lines = #new_lines, first_diff = first_diff, min_len = min_len })

	if first_diff == nil then
		if #old_lines == #new_lines then
			if state.last_render_highlight_signature ~= current_highlight_signature() then
				apply_render_highlights(state.render_highlights_dirty_start or 0)
			end
			if apply_widget_focus_cursor() then
				local done_redraw = perf.start("chat.do_render.redraw")
				vim.cmd("redraw")
				done_redraw({ path = "no_line_diff_focus" })
			end
			mark_render_applied()
			done_total({ path = "no_line_diff", lines = #new_lines, force_full_render = false })
			return
		end
		first_diff = min_len
	end

	first_diff = math.min(first_diff, buf_line_count - 1)
	if first_diff < 0 then
		first_diff = 0
	end

	local done_build_replacement = perf.start("chat.do_render.build_replacement")
	local replacement = {}
	for i = first_diff + 1, #new_lines do
		table.insert(replacement, new_lines[i])
	end
	done_build_replacement({
		first_diff = first_diff,
		replacement_lines = #replacement,
		new_lines = #new_lines,
	})

	local done_set_lines = perf.start("chat.do_render.set_lines")
	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, first_diff, -1, false, replacement)
	done_set_lines({ first_diff = first_diff, replacement_lines = #replacement })

	apply_render_highlights(first_diff)
	vim.bo[state.bufnr].modifiable = false

	if apply_widget_focus_cursor() then
		local done_redraw = perf.start("chat.do_render.redraw")
		vim.cmd("redraw")
		done_redraw({ path = "focus" })
		mark_render_applied()
		done_total({
			path = "focus",
			lines = #new_lines,
			first_diff = first_diff,
			replacement_lines = #replacement,
			force_full_render = false,
		})
		return
	end

	if restore_widget_cursor_context(widget_cursor) then
		local done_redraw = perf.start("chat.do_render.redraw")
		vim.cmd("redraw")
		done_redraw({ path = "restore_cursor" })
		mark_render_applied()
		done_total({
			path = "restore_cursor",
			lines = #new_lines,
			first_diff = first_diff,
			replacement_lines = #replacement,
			force_full_render = false,
		})
		return
	end

	if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local done_scroll = perf.start("chat.do_render.scroll")
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
		done_scroll({ buf_lines = buf_lines })
	end

	local done_redraw = perf.start("chat.do_render.redraw")
	vim.cmd("redraw")
	done_redraw({ path = "normal" })
	mark_render_applied()
	done_total({
		path = "normal",
		lines = #new_lines,
		first_diff = first_diff,
		replacement_lines = #replacement,
		force_full_render = false,
	})
end

-- ─── Cross-domain key routers ─────────────────────────────────────────────────

function M.sync_widget_selection_from_cursor()
	return chat_interactions.sync_widget_selection_from_cursor()
end

function M.handle_question_navigation(direction)
	return chat_interactions.handle_question_navigation(direction)
end

function M.handle_question_number_select(number)
	return chat_interactions.handle_question_number_select(number)
end

function M.handle_question_confirm()
	return chat_interactions.handle_question_confirm()
end

function M.handle_question_cancel()
	return chat_interactions.handle_question_cancel()
end

function M.handle_question_next_tab()
	return chat_interactions.handle_question_next_tab()
end

function M.handle_question_prev_tab()
	return chat_interactions.handle_question_prev_tab()
end

function M.handle_question_custom_input()
	return chat_interactions.handle_question_custom_input()
end

function M.handle_widget_message()
	return chat_interactions.handle_widget_message()
end

function M.handle_question_toggle()
	return chat_interactions.handle_question_toggle()
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
