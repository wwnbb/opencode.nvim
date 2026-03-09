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

-- ─── Shared state & sub-modules ──────────────────────────────────────────────

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns

local render = require("opencode.ui.chat.render")
local chat_tasks = require("opencode.ui.chat.tasks")
local chat_questions = require("opencode.ui.chat.questions")
local chat_permissions = require("opencode.ui.chat.permissions")
local chat_edits = require("opencode.ui.chat.edits")
local chat_nav = require("opencode.ui.chat.nav")

local question_widget = require("opencode.ui.question_widget")
local question_state = require("opencode.question.state")
local permission_widget = require("opencode.ui.permission_widget")
local permission_state = require("opencode.permission.state")
local edit_widget = require("opencode.ui.edit_widget")
local edit_state = require("opencode.edit.state")

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
	keymaps = {
		close = "q",
		focus_input = "i",
		scroll_up = "<C-u>",
		scroll_down = "<C-d>",
		goto_top = "gg",
		goto_bottom = "G",
		abort = "<C-c>",
	},
}

local function get_config()
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}
	return vim.tbl_deep_extend("force", defaults, full_config.chat or {})
end

local function calculate_dimensions(cfg)
	local ui = vim.api.nvim_list_uis()[1]
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

local function setup_float_focus_autocmds()
	clear_float_focus_autocmds()

	state.focus_augroup = vim.api.nvim_create_augroup(
		"OpenCodeFloatFocus_" .. tostring(state.bufnr or 0),
		{ clear = true }
	)

	vim.api.nvim_create_autocmd({ "WinEnter", "TabEnter" }, {
		group = state.focus_augroup,
		callback = function()
			vim.schedule(function()
				if not state.visible then
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

				M.close()
			end)
		end,
	})
end

-- ─── Buffer setup ────────────────────────────────────────────────────────────

local function setup_buffer(bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode"
	vim.bo[bufnr].modifiable = false

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
		local opencode = require("opencode")
		opencode.abort()
	end, vim.tbl_extend("force", opts, { desc = "Stop current generation" }))

	vim.keymap.set("n", "a", function()
		M.toggle_auto_scroll()
	end, vim.tbl_extend("force", opts, { desc = "Toggle auto-scroll" }))

	vim.keymap.set("n", "?", function()
		M.show_help()
	end, opts)

	vim.keymap.set("n", "<C-p>", function()
		local palette = require("opencode.ui.palette")
		palette.show()
	end, { buffer = bufnr, noremap = true, silent = true, desc = "Open command palette" })

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
			chat_edits.sync_selected_file_from_cursor()
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

-- ─── Window lifecycle ─────────────────────────────────────────────────────────

function M.toggle_auto_scroll()
	state.auto_scroll = not state.auto_scroll
	vim.notify(string.format("Auto-scroll %s", state.auto_scroll and "enabled" or "disabled"), vim.log.levels.INFO)
end

function M.show_help()
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "NormalFloat", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBorder", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputInfo", { link = "Comment", default = true })

	local lines = {
		"Chat Buffer Keymaps",
		"",
		"q          Close chat",
		"i          Focus input",
		"a          Toggle auto-scroll",
		"<C-c>      Stop generation",
		"<C-p>      Command palette",
		"<C-u>      Scroll up",
		"<C-d>      Scroll down",
		"gg         Go to top",
		"G          Go to bottom",
		"?          Show this help",
		"",
		"Input Mode",
		"<C-g>      Send message",
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
		["Question Tool"] = true,
		["Permissions"] = true,
		["Edit Review"] = true,
	}
	for i, line in ipairs(lines) do
		if section_headers[line] then
			vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, 0, { end_col = #line, hl_group = "OpenCodeInputBorder" })
		elseif line == "Press any key to close" then
			vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, 0, { end_col = #line, hl_group = "OpenCodeInputInfo" })
		elseif line ~= "" then
			local key_end = line:find("  ")
			if key_end then
				vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, 0, { end_col = key_end - 1, hl_group = "Normal" })
				vim.api.nvim_buf_set_extmark(popup.bufnr, ns, i - 1, key_end - 1,
					{ end_col = #line, hl_group = "OpenCodeInputInfo" })
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
	state.bufnr = create_buffer()
	state.messages = {}
	state.stream_blocks = {}

	local events = require("opencode.events")

	events.on("chat_render", function(data)
		vim.schedule(function()
			M.schedule_render()
		end)
	end)

	events.on("message_part_updated", function(data)
		vim.schedule(function()
			local part = data and data.part
			if not part or part.type ~= "text" or not part.messageID then
				return
			end
			if not state.visible or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
				return
			end
			if not M.update_stream_text_block(part.messageID) then
				M.schedule_render()
			end
		end)
	end)

	events.on("status_change", function(data)
		vim.schedule(function()
			local new_status = data and data.status
			if new_status == "streaming" or new_status == "thinking" then
				local has_pending_question = false
				for _, msg in ipairs(state.messages) do
					if (msg.type == "question" or msg.type == "permission") and msg.status == "pending" then
						has_pending_question = true
						break
					end
				end

				if has_pending_question then
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
		local is_navigating = state.navigating
		vim.schedule(function()
			if spinner.is_active() then
				spinner.stop()
			end
			stop_spinner_animation_timer()
			chat_tasks.stop_task_animation_timer()
			state.pending_questions = {}
			state.pending_permissions = {}
			state.pending_edits = {}
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
			if not is_navigating then
				local new_messages = {}
				for _, msg in ipairs(state.messages) do
					if msg.type ~= "question" and msg.type ~= "permission" then
						table.insert(new_messages, msg)
					end
				end
				state.messages = new_messages
			end
			if not is_navigating then
				state.session_stack = {}
			end
		end)
	end)

	M.do_render()

	return state.bufnr
end

function M.open()
	if state.visible then
		return
	end

	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		M.create()
	end

	local cfg = state.config
	local dims = calculate_dimensions(cfg)

	if cfg.layout == "float" then
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
			},
			position = {
				relative = "editor",
				row = dims.row,
				col = dims.col,
			},
			size = { width = dims.width, height = dims.height },
			bufnr = state.bufnr,
			win_options = {
				fillchars = "eob: ",
			},
		})

		popup:mount()
		state.layout = popup
		state.winid = popup.winid
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
						state.visible = false
						state.winid = nil
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
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)

		if cfg.layout == "vertical" then
			vim.api.nvim_win_set_width(state.winid, cfg.width)
		else
			vim.api.nvim_win_set_height(state.winid, cfg.height)
		end

		vim.wo[state.winid].winfixwidth = cfg.layout == "vertical"
		vim.wo[state.winid].winfixheight = cfg.layout == "horizontal"
		vim.wo[state.winid].fillchars = "eob: "
	end

	state.visible = true
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
	if line_count > 0 then
		vim.api.nvim_win_set_cursor(state.winid or 0, { line_count, 0 })
	end

	chat_questions.process_pending_questions()
	chat_permissions.process_pending_permissions()
	chat_edits.process_pending_edits()
end

function M.close()
	if not state.visible then
		return
	end

	clear_float_focus_autocmds()

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
	state.layout = nil
	state.float_dims = nil
	stop_spinner_animation_timer()
	chat_tasks.stop_task_animation_timer()
end

function M.toggle()
	if state.visible then
		M.close()
	else
		M.open()
	end
end

function M.is_visible()
	return state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid)
end

function M.get_winid()
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		return state.winid
	end
	return nil
end

function M.get_float_dims()
	if not state.visible or not state.float_dims then
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
	if not state.visible then
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
		close_on_send = false,
		on_send = function(text)
			local opencode = require("opencode")
			local slash_ok, slash = pcall(require, "opencode.slash")
			if slash_ok and type(slash.parse) == "function" and type(slash.execute) == "function" then
				local parsed = slash.parse(text)
				if parsed then
					slash.execute(parsed)
					return
				end
			end
			opencode.send(text)
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
		id = opts.id or tostring(os.time()) .. "_" .. #state.messages,
		tool_calls = opts.tool_calls,
	}

	table.insert(state.messages, message)
	M.render_message(message)
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
	local id_short = message.id and message.id:sub(1, 6) or "??????"
	local header_text = string.format(
		"%s [%s] %s%s",
		role_display,
		id_short,
		string.rep(" ", 50 - #role_display - #time_str - #id_short - 3),
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
	state.messages = {}
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.pending_edits = {}
	state.tasks = {}
	state.expanded_tasks = {}
	state.task_child_cache = {}
	state.tools = {}
	state.expanded_tools = {}
	state.stream_blocks = {}
	state.spinner_footer_line = nil
	state.last_render_time = 0
	state.render_scheduled = false

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
		qs.clear_all()
	end
	local ok2, ps = pcall(require, "opencode.permission.state")
	if ok2 then
		ps.clear_all()
	end
	local ok3, es = pcall(require, "opencode.edit.state")
	if ok3 then
		es.clear_all()
	end
end

function M.get_messages()
	return vim.deepcopy(state.messages)
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
	if delta == 0 then
		return
	end

	render.shift_line_map(state.questions, old_end, delta)
	render.shift_line_map(state.permissions, old_end, delta)
	render.shift_line_map(state.edits, old_end, delta)
	render.shift_line_map(state.tasks, old_end, delta)
	render.shift_line_map(state.tools, old_end, delta)

	for message_id, pos in pairs(state.stream_blocks) do
		if message_id ~= skip_stream_message_id and pos.start_line and pos.end_line and pos.start_line > old_end then
			pos.start_line = pos.start_line + delta
			pos.end_line = pos.end_line + delta
		end
	end

	if state.focus_question_line and (state.focus_question_line - 1) > old_end then
		state.focus_question_line = state.focus_question_line + delta
	end
	if state.focus_permission_line and (state.focus_permission_line - 1) > old_end then
		state.focus_permission_line = state.focus_permission_line + delta
	end
	if state.focus_edit_line and (state.focus_edit_line - 1) > old_end then
		state.focus_edit_line = state.focus_edit_line + delta
	end
end

function M.update_stream_text_block(message_id)
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

	local sync = require("opencode.sync")
	local content = sync.get_message_text(message_id)
	local content_lines = render.render_content(content, { stream_plain = true })
	if #content_lines == 0 then
		local empty = NuiLine()
		empty:append("")
		content_lines = { empty }
	end
	local replacement = render.extract_lines(content_lines)

	local should_scroll = false
	if state.auto_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local cursor = vim.api.nvim_win_get_cursor(state.winid)
		local win_height = vim.api.nvim_win_get_height(state.winid)
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		should_scroll = cursor[1] >= buf_lines - win_height - 1
	end

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

	if should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
	end

	vim.cmd("redraw")
	return true
end

-- ─── Main render ─────────────────────────────────────────────────────────────

---Build full buffer content using NuiLine components.
---@return string[] raw_lines, NuiLine[] nui_lines
function M.render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return {}, {}
	end

	local sync = require("opencode.sync")
	local app_state = require("opencode.state")
	local current_session = app_state.get_session()
	local in_child_session_view = #state.session_stack > 0

	local nui_lines = {}
	local raw_lines = {}
	local last_block_kind = nil -- "tool" | "non_tool"

	local function push_line(text, nui_line)
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

	---@param owner_session_id string|nil
	---@param widget_status string|nil
	---@return boolean
	local function should_render_session_widget(owner_session_id, widget_status)
		local owns_widget = owner_session_id == current_session.id
		if owns_widget then
			return true
		end
		if in_child_session_view then
			return false
		end
		return (widget_status or "pending") == "pending"
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

	local rendered_perm_ids = {}
	local rendered_edit_ids = {}
	local next_stream_blocks = {}
	state.spinner_footer_line = nil

	local function render_single_permission(pstate)
		local perm_id = pstate.permission_id
		local pstatus = pstate.status or "pending"
		local p_lines, p_highlights

		if pstatus == "approved" then
			p_lines, p_highlights = permission_widget.get_approved_lines(perm_id, pstate)
		elseif pstatus == "rejected" then
			p_lines, p_highlights = permission_widget.get_rejected_lines(perm_id, pstate)
		else
			local first_option_offset
			p_lines, p_highlights, _, first_option_offset = permission_widget.get_lines_for_permission(perm_id, pstate)
			if state.focus_permission == perm_id then
				state.focus_permission_line = #raw_lines + first_option_offset + 1
			end
		end

		if p_lines then
			local perm_start = #raw_lines
			for _, line_text in ipairs(p_lines) do
				add_raw_line(line_text)
			end
			state.permissions[perm_id] = {
				start_line = perm_start,
				end_line = perm_start + #p_lines - 1,
				status = pstatus,
			}
			add_raw_line("")
		end
	end

	local function render_single_edit(estate)
		local eid = estate.permission_id
		local estatus = estate.status or "pending"
		local e_lines, e_highlights

		if estatus == "sent" then
			e_lines, e_highlights = edit_widget.get_resolved_lines(eid, estate)
		else
			local first_file_offset
			e_lines, e_highlights, _, first_file_offset = edit_widget.get_lines_for_edit(eid, estate)
			if state.focus_edit == eid then
				state.focus_edit_line = #raw_lines + first_file_offset + 1
			end
		end

		if e_lines then
			local edit_start = #raw_lines
			for _, line_text in ipairs(e_lines) do
				add_raw_line(line_text)
			end
			state.edits[eid] = {
				start_line = edit_start,
				end_line = edit_start + #e_lines - 1,
				status = estatus,
			}
			add_raw_line("")
		end
	end

	local function render_permissions(message_id)
		local perms = permission_state.get_permissions_for_message(message_id)
		for _, pstate in ipairs(perms) do
			rendered_perm_ids[pstate.permission_id] = true
			if should_render_session_widget(pstate.session_id, pstate.status) then
				render_single_permission(pstate)
			end
		end
	end

	local function render_edits_for_msg(message_id)
		local edits = edit_state.get_edits_for_message(message_id)
		for _, estate in ipairs(edits) do
			rendered_edit_ids[estate.permission_id] = true
			if should_render_session_widget(estate.session_id, estate.status) then
				render_single_edit(estate)
			end
		end
	end

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

	-- Session header
	local session_name = current_session.name or "New session"
	local header_line = "# " .. session_name
	local header = NuiLine()
	header:append(NuiText(header_line, "Comment"))
	add_line(header)
	add_raw_line("")

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
		local content = sync.get_message_text(message.id)
		local reasoning = sync.get_message_reasoning(message.id)
		local tool_parts = sync.get_message_tools(message.id)
		local incomplete_assistant = message.role == "assistant" and not (message.time and message.time.completed)
		local render_as_plain_stream = app_state.get_status() == "streaming" and incomplete_assistant

		local has_content = content and content ~= ""
		local has_reasoning = reasoning and reasoning ~= ""
		local has_tools = #tool_parts > 0
		local is_last_assistant = (msg_idx == last_assistant_idx)
		local force_processing_render = spinner_active and is_last_assistant and incomplete_assistant
		local should_render = message.role ~= "assistant" or has_content or has_reasoning or has_tools or force_processing_render

		if should_render then
			if message.role == "user" then
				local msg_lines = render.render_user_message(content, message.agent)
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
				if has_reasoning and thinking.is_enabled() then
					local reasoning_lines = render.render_reasoning(reasoning)
					for _, nl in ipairs(reasoning_lines) do
						add_line(nl)
					end
				end

				if has_content then
					local content_start = #raw_lines
					local content_lines = render.render_content(content, { stream_plain = render_as_plain_stream })
					for _, nl in ipairs(content_lines) do
						add_line(nl)
					end
					if incomplete_assistant and #content_lines > 0 then
						next_stream_blocks[message.id] = {
							start_line = content_start,
							end_line = #raw_lines - 1,
						}
					end
				end

				if has_tools then
					for _, tool_part in ipairs(tool_parts) do
						if tool_part.tool == "task" then
							local is_expanded = state.expanded_tasks[tool_part.id] or false
							local cached = state.task_child_cache[tool_part.id]
							local result = chat_tasks.render_task_tool(tool_part, is_expanded, cached)
							local base_line = #raw_lines
							local hl_by_line = {}
							for _, hl in ipairs(result.highlights) do
								hl_by_line[hl.line] = hl
							end
							for idx, tl in ipairs(result.lines) do
								local nl = NuiLine()
								local line_hl = hl_by_line[idx - 1]
								if line_hl then
									nl:append(NuiText(tl, line_hl.hl_group))
								else
									nl:append(tl)
								end
								add_line(nl, "tool")
							end
							state.tasks[tool_part.id] = {
								start_line = base_line,
								end_line = base_line + #result.lines - 1,
								tool_part = tool_part,
							}
						else
							local is_expanded = state.expanded_tools[tool_part.id] or false
							local result = render.render_tool_line(tool_part, is_expanded)
							local base_line = #raw_lines
							local hl_by_line = {}
							for _, hl in ipairs(result.highlights) do
								hl_by_line[hl.line] = hl
							end
							for idx, tl in ipairs(result.lines) do
								local nl = NuiLine()
								local line_hl = hl_by_line[idx - 1]
								if line_hl then
									nl:append(NuiText(tl, line_hl.hl_group))
								else
									nl:append(tl)
								end
								add_line(nl, "tool")
							end
							state.tools[tool_part.id] = {
								start_line = base_line,
								end_line = base_line + #result.lines - 1,
								tool_part = tool_part,
							}
						end
					end
				end

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

				render_permissions(message.id)
				render_edits_for_msg(message.id)
			end
		end
	end

	-- Local messages (questions, etc.)
	for _, message in ipairs(state.messages) do
		if message.id and current_session.id then
			local sync_msg = sync.get_message(current_session.id, message.id)
			if sync_msg then
				goto continue_local_message
			end
		end

		if message.type == "question" then
			local qstate = question_state.get_question(message.request_id)
			local q_start_line = #raw_lines
			local q_lines, q_highlights
			local status = (qstate and qstate.status) or message.status or "pending"

			if status == "answered" then
				q_lines, q_highlights = question_widget.get_answered_lines(
					message.request_id,
					{ questions = message.questions },
					message.answers
				)
			elseif status == "rejected" then
				q_lines, q_highlights = question_widget.get_rejected_lines(message.request_id, {
					questions = message.questions,
				})
			elseif qstate then
				local first_option_offset
				q_lines, q_highlights, _, first_option_offset = question_widget.get_lines_for_question(
					message.request_id,
					{ questions = message.questions },
					qstate,
					status
				)
				if state.focus_question == message.request_id then
					state.focus_question_line = q_start_line + first_option_offset + 1
				end
			else
				goto continue_local_message
			end

			for _, line_text in ipairs(q_lines) do
				add_raw_line(line_text)
			end

			state.questions[message.request_id] = {
				start_line = q_start_line,
				end_line = q_start_line + #q_lines - 1,
				status = status,
			}

			add_raw_line("")
			::continue_local_message::
		end

		if message.type == "permission" or message.role == "user" then
			goto continue_local_message
		end

		local has_content = message.content and message.content ~= ""
		if has_content then
			local content_lines = render.render_content(message.content)
			for _, nl in ipairs(content_lines) do
				add_line(nl)
			end
			add_raw_line("")
		end
		::continue_local_message::
	end

	-- Orphan permissions from other sessions:
	-- parent view shows cross-session widgets only while pending;
	-- child view shows current-session widgets only.
	local session_msg_ids = {}
	for _, message in ipairs(messages) do
		session_msg_ids[message.id] = true
	end

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
		if
			not_already_rendered
			and not_inline
			and should_render_session_widget(estate.session_id, estate.status)
		then
			render_single_edit(estate)
		end
	end

	if spinner_active and not spinner_footer_rendered then
		local app_agent = app_state.get_agent() or {}
		local app_model = app_state.get_model() or {}
		local fallback_agent = app_agent.name or app_agent.id or "assistant"
		local fallback_message = {
			role = "assistant",
			agent = app_agent.id or app_agent.name or "assistant",
			mode = fallback_agent,
			modelID = app_model.id,
			providerID = app_model.provider,
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
		add_raw_line(" No active session")
		add_raw_line(" Press 'i' to focus input")
		add_raw_line(" Press '<C-p>' for command palette")
		add_raw_line(" Press '?' for help")
		add_raw_line("")
	end

	state.stream_blocks = next_stream_blocks
	return raw_lines, nui_lines
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

function M.do_render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local should_scroll = false
	if state.auto_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local cursor = vim.api.nvim_win_get_cursor(state.winid)
		local win_height = vim.api.nvim_win_get_height(state.winid)
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		should_scroll = cursor[1] >= buf_lines - win_height - 1
	end

	local new_lines, nui_lines = M.render()
	if #new_lines == 0 or #nui_lines == 0 then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
		vim.bo[state.bufnr].modifiable = false
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

	buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, first_diff, -1)
	for i, nui_line in ipairs(nui_lines) do
		local line_idx = i - 1
		if line_idx >= first_diff and line_idx < buf_line_count then
			nui_line:highlight(state.bufnr, chat_hl_ns, i)
		end
	end

	vim.bo[state.bufnr].modifiable = false

	if
		state.focus_question
		and state.focus_question_line
		and state.winid
		and vim.api.nvim_win_is_valid(state.winid)
	then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		local target = math.min(state.focus_question_line, buf_lines)
		vim.api.nvim_win_set_cursor(state.winid, { target, 0 })
		state.focus_question = nil
		state.focus_question_line = nil
	elseif
		state.focus_permission
		and state.focus_permission_line
		and state.winid
		and vim.api.nvim_win_is_valid(state.winid)
	then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		local target = math.min(state.focus_permission_line, buf_lines)
		vim.api.nvim_win_set_cursor(state.winid, { target, 0 })
		state.focus_permission = nil
		state.focus_permission_line = nil
	elseif state.focus_edit and state.focus_edit_line and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		local target = math.min(state.focus_edit_line, buf_lines)
		vim.api.nvim_win_set_cursor(state.winid, { target, 0 })
		state.focus_edit = nil
		state.focus_edit_line = nil
	elseif should_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
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

---Move cursor first, then sync widget selection to cursor.
---@param direction "up" | "down"
function M.handle_question_navigation(direction)
	local key = direction == "up" and "k" or "j"
	vim.cmd("normal! " .. key)

	chat_questions.sync_selected_option_from_cursor()
	chat_permissions.sync_selected_option_from_cursor()
	chat_edits.sync_selected_file_from_cursor()
end

---Route 1-9 to whichever widget is under cursor.
---@param number number
function M.handle_question_number_select(number)
	local request_id = chat_questions.get_question_at_cursor()
	if request_id then
		question_state.select_option(request_id, number)
		chat_questions.rerender_question(request_id)
		return
	end

	local perm_id = chat_permissions.get_permission_at_cursor()
	if perm_id and number >= 1 and number <= 3 then
		permission_state.select_option(perm_id, number)
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
				chat_questions.rerender_question(request_id)
			end
			return
		end

		if total_count > 1 then
			question_state.set_confirming(request_id)
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
			chat_questions.rerender_question(request_id)
			return
		end

		local client = require("opencode.client")
		local current_session = require("opencode.state").get_session()
		client.reject_question(current_session.id, request_id, function(err, success)
			vim.schedule(function()
				if err then
					vim.notify("Failed to cancel question: " .. tostring(err), vim.log.levels.ERROR)
					return
				end
				question_state.mark_rejected(request_id)
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
M.add_question_message       = chat_questions.add_question_message
M.update_question_status     = chat_questions.update_question_status
M.get_question_at_cursor     = chat_questions.get_question_at_cursor
M.rerender_question          = chat_questions.rerender_question
M.submit_question_answers    = chat_questions.submit_question_answers
M.clear_questions            = chat_questions.clear_questions
M.debug_questions            = chat_questions.debug_questions
M.get_pending_question_count = chat_questions.get_pending_question_count
M.has_pending_questions      = chat_questions.has_pending_questions

-- Permissions
M.add_permission_message     = chat_permissions.add_permission_message
M.update_permission_status   = chat_permissions.update_permission_status
M.get_permission_at_cursor   = chat_permissions.get_permission_at_cursor
M.rerender_permission        = chat_permissions.rerender_permission
M.handle_permission_confirm  = chat_permissions.handle_permission_confirm
M.handle_permission_reject   = chat_permissions.handle_permission_reject

-- Edits
M.add_edit_message           = chat_edits.add_edit_message
M.get_edit_at_cursor         = chat_edits.get_edit_at_cursor
M.rerender_edit              = chat_edits.rerender_edit
M.finalize_edit              = chat_edits.finalize_edit
M.handle_edit_accept_file    = chat_edits.handle_edit_accept_file
M.handle_edit_reject_file    = chat_edits.handle_edit_reject_file
M.handle_edit_accept_all     = chat_edits.handle_edit_accept_all
M.handle_edit_reject_all     = chat_edits.handle_edit_reject_all
M.handle_edit_resolve_file   = chat_edits.handle_edit_resolve_file
M.handle_edit_resolve_all    = chat_edits.handle_edit_resolve_all
M.handle_edit_toggle_diff    = chat_edits.handle_edit_toggle_diff
M.handle_edit_diff_tab       = chat_edits.handle_edit_diff_tab
M.handle_edit_diff_split     = chat_edits.handle_edit_diff_split
M.open_inline_diff_split     = chat_edits.open_inline_diff_split

-- Tasks / tools
M.get_task_at_cursor         = chat_tasks.get_task_at_cursor
M.get_tool_at_cursor         = chat_tasks.get_tool_at_cursor
M.rerender_task              = chat_tasks.rerender_task
M.handle_task_toggle         = chat_tasks.handle_task_toggle
M.rerender_tool              = chat_tasks.rerender_tool
M.handle_tool_toggle         = chat_tasks.handle_tool_toggle

-- Session navigation
M.is_navigating              = chat_nav.is_navigating
M.enter_child_session        = chat_nav.enter_child_session
M.leave_child_session        = chat_nav.leave_child_session

return M
