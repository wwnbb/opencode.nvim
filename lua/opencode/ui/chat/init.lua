-- opencode.nvim - Chat buffer UI module
-- Main chat interface with configurable layouts
-- This module mirrors the TUI's session/index.tsx rendering approach

local M = {}

local Popup = require("nui.popup")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local input = require("opencode.ui.input")
local chat_help = require("opencode.ui.chat.help")
local chat_float_focus = require("opencode.ui.chat.float_focus")
local chat_messages = require("opencode.ui.chat.messages")
local chat_keymaps = require("opencode.ui.chat.keymaps")
local chat_session_tabs = require("opencode.ui.chat.session_tabs")
local thinking = require("opencode.ui.thinking")
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
local chat_cursor = require("opencode.ui.chat.cursor")
local panel = require("opencode.ui.panel")
local chat_tasks = require("opencode.ui.chat.tasks")
local chat_todos = require("opencode.ui.chat.todos")
local chat_questions = require("opencode.ui.chat.questions")
local chat_permissions = require("opencode.ui.chat.permissions")
local chat_edits = require("opencode.ui.chat.edits")
local chat_interactions = require("opencode.ui.chat.interactions")
local chat_nav = require("opencode.ui.chat.nav")
local widget_support = require("opencode.ui.chat.widget_support")

chat_messages.set_schedule_render(function(opts)
	M.schedule_render(opts)
end)

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

local function is_processing_status(status)
	local status_type = type(status) == "table" and status.type or status
	return status_type == "busy"
		or status_type == "streaming"
		or status_type == "thinking"
		or status_type == "retry"
end

local reset_chat_surface = render_state.reset_chat_surface
local render_cache_key = render_state.render_cache_key
local stream_block_key = render_state.stream_block_key
local render_cache_get = render_state.render_cache_get
local render_cache_put = render_state.render_cache_put
local render_highlight_signature = render_state.render_highlight_signature
local highlight_clear_start = render_state.highlight_clear_start

local capture_widget_cursor_context = chat_cursor.capture_widget_cursor_context
local restore_widget_cursor_context = chat_cursor.restore_widget_cursor_context
local should_auto_scroll = chat_cursor.should_auto_scroll

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
			if not M.update_stream_part_block(session_id or current_session.id, message_id, part_id) then
				M.schedule_render({ force = true })
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
			reset_chat_surface({
				reset_expansions = not preserve_cache or (changed_session and reason ~= "child_navigation"),
			})
			if not preserve_cache or (changed_session and reason ~= "child_navigation") then
				state.session_stack = {}
			end
			chat_todos.update_window()
			M.schedule_render({ force = true })
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

function M.update_stream_part_block(session_id, message_id, part_id)
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
	if block.session_id ~= effective_session_id or block.part_id ~= part_id or block.kind ~= part.type then
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
	shift_tracked_lines(old_end, delta, block_key)

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
	local metadata_provider_revision = sync.get_provider_revision()
	local metadata_agent_revision = sync.get_agent_revision()
	content_highlights._opencode_signature = render_cache_key(
		"metadata",
		metadata_provider_revision,
		metadata_agent_revision
	)

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

	local function cached_nui_line(key, build)
		local lines = cached_nui_lines(key, function()
			return { build() }
		end)
		return lines[1]
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
	local rendered_local_notice_ids = {}
	local next_stream_blocks = {}
	state.spinner_footer_line = nil
	local all_questions = question_state.get_all()
	local all_permissions = permission_state.get_all()
	local all_edits = edit_state.get_all()
	local questions_by_message = {}
	local permissions_by_message = {}
	local edits_by_message = {}
	local edits_by_session = {}
	for _, qstate in ipairs(all_questions) do
		if qstate.message_id then
			questions_by_message[qstate.message_id] = questions_by_message[qstate.message_id] or {}
			table.insert(questions_by_message[qstate.message_id], qstate)
		end
	end
	for _, pstate in ipairs(all_permissions) do
		if pstate.message_id then
			permissions_by_message[pstate.message_id] = permissions_by_message[pstate.message_id] or {}
			table.insert(permissions_by_message[pstate.message_id], pstate)
		end
	end
	for _, estate in ipairs(all_edits) do
		if estate.message_id then
			edits_by_message[estate.message_id] = edits_by_message[estate.message_id] or {}
			table.insert(edits_by_message[estate.message_id], estate)
		end
		if estate.session_id then
			edits_by_session[estate.session_id] = edits_by_session[estate.session_id] or {}
			table.insert(edits_by_session[estate.session_id], estate)
		end
	end
	local widget_order = {
		question = 1,
		permission = 2,
		edit = 3,
	}

	---@type fun(result: table, kind: string): number
	local add_render_result

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

	local function render_session_error_notice(notice)
		ensure_session_error_highlights()
		local result = { lines = {}, highlights = {} }
		render.add_panel_line(result, notice.content, "OpenCodeSessionError", {
			prefix_hl_group = "OpenCodeSessionErrorBorder",
		})
		local base_line = add_render_result(result, "non_tool")
		append_relative_highlights(result.highlights, base_line)
	end

	local function render_child_session_widgets_for_task(tool_part)
		local child_session_id = event_util.resolve_task_child_session_id(tool_part)
		if type(child_session_id) ~= "string" or child_session_id == "" then
			return
		end
		local widget_items = {}

		for _, qstate in ipairs(all_questions) do
			local qid = qstate.request_id
			if
				qstate.session_id == child_session_id
				and qid
				and not rendered_question_ids[qid]
				and should_render_session_widget(qstate.session_id, qstate.status)
			then
				table.insert(widget_items, {
					kind = "question",
					id = qid,
					timestamp = qstate.timestamp or 0,
					data = qstate,
				})
			end
		end

		for _, pstate in ipairs(all_permissions) do
			local pid = pstate.permission_id
			if
				pstate.session_id == child_session_id
				and pid
				and not rendered_perm_ids[pid]
				and should_render_session_widget(pstate.session_id, pstate.status)
			then
				table.insert(widget_items, {
					kind = "permission",
					id = pid,
					timestamp = pstate.timestamp or 0,
					data = pstate,
				})
			end
		end

		for _, estate in ipairs(edits_by_session[child_session_id] or {}) do
			local eid = estate.permission_id
			if
				eid
				and not rendered_edit_ids[eid]
				and should_render_session_widget(estate.session_id, estate.status)
			then
				table.insert(widget_items, {
					kind = "edit",
					id = eid,
					timestamp = estate.timestamp or 0,
					data = estate,
				})
			end
		end

		render_widget_items(widget_items)

		for _, notice in ipairs(state.local_notices) do
			if
				notice.kind == "session_error"
				and notice.child_session_id == child_session_id
				and not rendered_local_notice_ids[notice.id]
			then
				rendered_local_notice_ids[notice.id] = true
				render_session_error_notice(notice)
				add_raw_line("")
			end
		end
	end

	local function render_widgets_for_message(message_id)
		local widget_items = {}

		for _, qstate in ipairs(questions_by_message[message_id] or {}) do
			if not rendered_question_ids[qstate.request_id] then
				table.insert(widget_items, {
					kind = "question",
					id = qstate.request_id,
					timestamp = qstate.timestamp or 0,
					data = qstate,
				})
			end
		end

		local perms = permissions_by_message[message_id] or {}
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

		local edits = edits_by_message[message_id] or {}
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
		for _, qstate in ipairs(questions_by_message[message_id] or {}) do
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

		for _, qstate in ipairs(all_questions) do
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
		for _, estate in ipairs(edits_by_message[message_id] or {}) do
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

		for _, estate in ipairs(all_edits) do
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

		for _, qstate in ipairs(questions_by_message[message_id] or {}) do
			if qstate.call_id == call_id then
				table.insert(widget_items, {
					kind = "question",
					id = qstate.request_id,
					timestamp = qstate.timestamp or 0,
					data = qstate,
				})
			end
		end

		for _, qstate in ipairs(all_questions) do
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

		local perms = permissions_by_message[message_id] or {}
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

		for _, pstate in ipairs(all_permissions) do
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

		local edits = edits_by_message[message_id] or {}
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

		for _, estate in ipairs(all_edits) do
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
	add_render_result = function(result, kind)
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
				return chat_tasks.render_task_tool(tool_part, is_expanded)
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
	local user_created_by_id = {}
	for _, msg in ipairs(messages) do
		if msg.id and msg.role == "user" and msg.time and type(msg.time.created) == "number" then
			user_created_by_id[msg.id] = msg.time.created
		end
	end

	---@param message table
	---@return number|nil
	local function metadata_footer_duration(message)
		if not message or not message.time or type(message.time.completed) ~= "number" then
			return nil
		end
		local parent_created = message.parentID and user_created_by_id[message.parentID]
		if type(parent_created) ~= "number" then
			return nil
		end
		return message.time.completed - parent_created
	end

	---@param message table
	---@param spinner_frame string|nil
	---@return NuiLine
	local function render_metadata_footer_line(message, spinner_frame)
		local duration_ms = metadata_footer_duration(message)
		local cache_key = message
			and message.id
			and render_cache_key(
				"metadata_footer",
				current_session.id,
				message.id,
				sync.get_message_revision(message.id),
				metadata_provider_revision,
				metadata_agent_revision,
				duration_ms or "",
				spinner_frame or ""
			)
		if cache_key then
			return cached_nui_line(cache_key, function()
				return render.render_metadata_footer(message, messages, {
					spinner_frame = spinner_frame,
					duration_ms = duration_ms,
					duration_calculated = true,
				})
			end)
		end

		return render.render_metadata_footer(message, messages, {
			spinner_frame = spinner_frame,
			duration_ms = duration_ms,
			duration_calculated = true,
		})
	end

	local current_session_processing = false
	if current_session.id then
		current_session_processing = is_processing_status(app_state.get_session_status(current_session.id))
	else
		current_session_processing = is_processing_status(app_state.get_status())
	end
	local spinner_footer_rendered = false

	local last_assistant_idx = nil
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" then
			last_assistant_idx = i
			break
		end
	end
	local last_assistant = last_assistant_idx and messages[last_assistant_idx] or nil
	local last_message = messages[#messages]
	local last_assistant_completed = last_assistant and last_assistant.time and last_assistant.time.completed ~= nil
	local last_assistant_waiting_on_tools = last_assistant and last_assistant.finish == "tool-calls"
	local has_pending_response_gap = not last_message
		or last_message.role ~= "assistant"
		or not last_assistant_completed
		or last_assistant_waiting_on_tools
	local spinner_active = spinner.is_active() and current_session_processing and has_pending_response_gap

	for msg_idx, message in ipairs(messages) do
		local content = sync.get_message_text(message.id, message.role == "user" and { include_synthetic = false } or nil)
		local reasoning = sync.get_message_reasoning(message.id)
		local tool_parts = sync.get_message_tools(message.id)
		local parts = sync.get_parts(message.id)
		local incomplete_assistant = message.role == "assistant" and not (message.time and message.time.completed)
		local render_as_plain_stream = current_session_processing and incomplete_assistant

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
						local reasoning_start = #raw_lines
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
						if incomplete_assistant and #reasoning_lines > 0 and part.id then
							local block_key = stream_block_key(current_session.id, message.id, part.id, "reasoning")
							if block_key then
								next_stream_blocks[block_key] = {
									start_line = reasoning_start,
									end_line = #raw_lines - 1,
									session_id = current_session.id,
									message_id = message.id,
									part_id = part.id,
									kind = "reasoning",
								}
							end
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
						if incomplete_assistant and #content_lines > 0 and part.id then
							local block_key = stream_block_key(current_session.id, message.id, part.id, "text")
							if block_key then
								next_stream_blocks[block_key] = {
									start_line = content_start,
									end_line = #raw_lines - 1,
									session_id = current_session.id,
									message_id = message.id,
									part_id = part.id,
									kind = "text",
								}
							end
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
						if part.tool == "task" then
							render_child_session_widgets_for_task(part)
						end
					end
				end

				render_widgets_for_message(message.id)

				if force_processing_render or render.should_show_footer(message, is_last_assistant) then
					ensure_single_blank_separator()
					local footer_line_idx = #raw_lines
					local show_spinner = spinner_active and is_last_assistant and incomplete_assistant
					local spinner_frame = show_spinner and spinner.get_frame() or nil
					add_line(render_metadata_footer_line(message, spinner_frame))
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
		if message.id and rendered_local_notice_ids[message.id] then
			goto continue_local_message
		end
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
				render_session_error_notice(message)
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

		for _, qstate in ipairs(all_questions) do
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
		for _, pstate in ipairs(all_permissions) do
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
	for _, estate in ipairs(all_edits) do
		local not_already_rendered = not rendered_edit_ids[estate.permission_id]
		local not_inline = not (estate.message_id and session_msg_ids[estate.message_id])
		if not_already_rendered and not_inline and should_render_session_widget(estate.session_id, estate.status) then
			render_single_edit(estate)
		end
	end

	if spinner_active and not spinner_footer_rendered then
		local fallback_agent = "assistant"
		local fallback_model_id = nil
		local fallback_provider_id = nil
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
		add_line(render_metadata_footer_line(fallback_message, spinner.get_frame()))
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

---@param opts? table { force?: boolean }
function M.schedule_render(opts)
	opts = opts or {}
	if opts.force then
		state.force_full_render = true
	end
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
	local force_full_render = state.force_full_render == true
	state.force_full_render = false
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

	if force_full_render then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
		vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, 0, -1)
		apply_render_highlights(0)
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
