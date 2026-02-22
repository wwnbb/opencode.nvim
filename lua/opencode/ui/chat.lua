-- opencode.nvim - Chat buffer UI module
-- Main chat interface with configurable layouts
-- This module mirrors the TUI's session/index.tsx rendering approach

local M = {}

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local event = require("nui.utils.autocmd").event
local input = require("opencode.ui.input")
local markdown = require("opencode.ui.markdown")
local chat_components = require("opencode.ui.chat_components")
local tools = require("opencode.ui.tools")
local thinking = require("opencode.ui.thinking")
local spinner = require("opencode.ui.spinner")
local locale = require("opencode.util.locale")

-- State (UI state only - message data lives in sync module)
local state = {
	bufnr = nil,
	winid = nil,
	layout = nil,
	visible = false,
	messages = {}, -- Local user messages only (sent before server confirms)
	config = nil,
	questions = {}, -- Track question positions: { [request_id] = { start_line, end_line } }
	pending_questions = {}, -- Queue of questions received when chat wasn't visible
	focus_question = nil, -- request_id of question to focus cursor on after render
	permissions = {}, -- Track permission positions: { [permission_id] = { start_line, end_line } }
	pending_permissions = {}, -- Queue of permissions received when chat wasn't visible
	focus_permission = nil, -- permission_id to focus cursor on after render
	edits = {}, -- Track edit widget positions: { [permission_id] = { start_line, end_line } }
	pending_edits = {}, -- Queue of edits received when chat wasn't visible
	focus_edit = nil, -- permission_id to focus cursor on after render
	focus_edit_line = nil,
	tasks = {}, -- Track task positions: { [part_id] = { start_line, end_line, tool_part } }
	expanded_tasks = {}, -- Toggle set: { [part_id] = true }
	task_child_cache = {}, -- Rendered child content: { [part_id] = { lines, highlights } }
	tools = {}, -- Track tool positions: { [part_id] = { start_line, end_line, tool_part } }
	expanded_tools = {}, -- Toggle set: { [part_id] = true }
	session_stack = {}, -- Stack of { id, name } for parent session navigation
	navigating = false, -- Flag to prevent session_change handler from clearing stack
	last_render_time = 0,
	render_scheduled = false,
	auto_scroll = true, -- Auto-scroll to bottom on new content
}

local question_widget = require("opencode.ui.question_widget")
local question_state = require("opencode.question.state")
local permission_widget = require("opencode.ui.permission_widget")
local permission_state = require("opencode.permission.state")
local edit_widget = require("opencode.ui.edit_widget")
local edit_state = require("opencode.edit.state")

-- Namespace for all chat buffer highlights (enables incremental highlight updates)
local chat_hl_ns = vim.api.nvim_create_namespace("opencode_chat_hl")

-- Default configuration
local defaults = {
	layout = "vertical", -- "vertical" | "horizontal" | "float"
	position = "right", -- "left" | "right" | "top" | "bottom"
	width = 80,
	height = 20,
	float = {
		width = 0.8,
		height = 0.8,
		border = "rounded",
		title = " OpenCode ",
		title_pos = "center",
	},
	input = {
		height = 5,
		border = "single",
		prompt = "> ",
	},
	keymaps = {
		close = "q",
		focus_input = "i",
		scroll_up = "<C-u>",
		scroll_down = "<C-d>",
		goto_top = "gg",
		goto_bottom = "G",
		abort = "<C-c>", -- Stop current generation
	},
}

-- Merge with user config
local function get_config()
	local config = require("opencode.config")
	local user_config = config.defaults or {}
	return vim.tbl_deep_extend("force", defaults, user_config.chat or {})
end

-- Calculate dimensions based on layout and config
local function calculate_dimensions(cfg)
	local ui = vim.api.nvim_list_uis()[1]
	local width, height, row, col

	if cfg.layout == "float" then
		width = math.floor(ui.width * cfg.float.width)
		height = math.floor(ui.height * cfg.float.height)
		row = math.floor((ui.height - height) / 2)
		col = math.floor((ui.width - width) / 2)
	elseif cfg.layout == "vertical" then
		width = cfg.width
		height = ui.height
		row = 0
		col = cfg.position == "right" and (ui.width - width) or 0
	else -- horizontal
		width = ui.width
		height = cfg.height
		row = cfg.position == "bottom" and (ui.height - height) or 0
		col = 0
	end

	return { width = width, height = height, row = row, col = col }
end

-- Setup buffer options
local function setup_buffer(bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode"
	vim.bo[bufnr].modifiable = false

	-- Set buffer-local keymaps
	local cfg = state.config
	local opts = { buffer = bufnr, noremap = true, silent = true }

	-- Close chat
	vim.keymap.set("n", cfg.keymaps.close, function()
		M.close()
	end, opts)

	-- Focus input
	vim.keymap.set("n", cfg.keymaps.focus_input, function()
		M.focus_input()
	end, opts)

	-- Scroll up
	vim.keymap.set("n", cfg.keymaps.scroll_up, "<C-u>", opts)

	-- Scroll down
	vim.keymap.set("n", cfg.keymaps.scroll_down, "<C-d>", opts)

	-- Go to top/bottom
	vim.keymap.set("n", cfg.keymaps.goto_top, "gg", opts)
	vim.keymap.set("n", cfg.keymaps.goto_bottom, "G", opts)

	-- Abort/stop current generation
	vim.keymap.set("n", cfg.keymaps.abort, function()
		local opencode = require("opencode")
		opencode.abort()
	end, vim.tbl_extend("force", opts, { desc = "Stop current generation" }))

	-- Toggle auto-scroll
	vim.keymap.set("n", "a", function()
		M.toggle_auto_scroll()
	end, vim.tbl_extend("force", opts, { desc = "Toggle auto-scroll" }))

	-- Help
	vim.keymap.set("n", "?", function()
		M.show_help()
	end, opts)

	-- Command palette
	vim.keymap.set("n", "<C-p>", function()
		local palette = require("opencode.ui.palette")
		palette.show()
	end, { buffer = bufnr, noremap = true, silent = true, desc = "Open command palette" })

	-- Question navigation (only active when on question lines)
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

	-- Number keys for quick selection (1-9)
	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			M.handle_question_number_select(i)
		end, opts)
	end

	-- Custom input key
	vim.keymap.set("n", "c", function()
		M.handle_question_custom_input()
	end, opts)

	-- Toggle multi-select (Space)
	vim.keymap.set("n", "<Space>", function()
		M.handle_question_toggle()
	end, opts)

	-- ==================== Edit widget keybindings ====================

	-- Accept selected file
	vim.keymap.set("n", "<C-a>", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_accept_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-a>", true, false, true), "n", false)
		end
	end, opts)

	-- Reject selected file
	vim.keymap.set("n", "<C-x>", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_reject_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x>", true, false, true), "n", false)
		end
	end, opts)

	-- Resolve selected file manually
	vim.keymap.set("n", "<C-m>", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_resolve_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-m>", true, false, true), "n", false)
		end
	end, opts)

	-- Toggle inline diff (fugitive-style =)
	vim.keymap.set("n", "=", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_toggle_diff()
		else
			vim.api.nvim_feedkeys("=", "n", false)
		end
	end, opts)

	-- Accept ALL pending files
	vim.keymap.set("n", "A", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_accept_all()
		else
			vim.api.nvim_feedkeys("A", "n", false)
		end
	end, opts)

	-- Reject ALL pending files
	vim.keymap.set("n", "X", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_reject_all()
		else
			vim.api.nvim_feedkeys("X", "n", false)
		end
	end, opts)

	-- Resolve ALL pending files manually
	vim.keymap.set("n", "M", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_resolve_all()
		else
			vim.api.nvim_feedkeys("M", "n", false)
		end
	end, opts)

	-- Diff in new tab (dt)
	vim.keymap.set("n", "dt", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_diff_tab()
		end
	end, vim.tbl_extend("force", opts, { nowait = true }))

	-- Diff vsplit (dv)
	vim.keymap.set("n", "dv", function()
		local eid = M.get_edit_at_cursor()
		if eid then
			M.handle_edit_diff_split()
		end
	end, vim.tbl_extend("force", opts, { nowait = true }))

	-- Go to subagent output (gd) — drill into child session
	vim.keymap.set("n", "gd", function()
		local task_part_id, task_info = M.get_task_at_cursor()
		if task_part_id then
			M.enter_child_session(task_part_id)
		end
	end, vim.tbl_extend("force", opts, { nowait = true }))

	-- Go back to parent session (Backspace)
	vim.keymap.set("n", "<BS>", function()
		if #state.session_stack > 0 then
			M.leave_child_session()
		end
	end, opts)

	-- Toggle tool output display (per-tool, in-place)
	vim.keymap.set("n", "O", function()
		local tool_part_id = M.get_tool_at_cursor()
		if tool_part_id then
			M.handle_tool_toggle(tool_part_id)
			return
		end
		local task_part_id = M.get_task_at_cursor()
		if task_part_id then
			M.handle_task_toggle(task_part_id)
			return
		end
	end, vim.tbl_extend("force", opts, { desc = "Toggle tool output" }))
end

-- Create chat buffer
local function create_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	setup_buffer(bufnr)
	return bufnr
end

-- Toggle auto-scroll
function M.toggle_auto_scroll()
	state.auto_scroll = not state.auto_scroll
	vim.notify(string.format("Auto-scroll %s", state.auto_scroll and "enabled" or "disabled"), vim.log.levels.INFO)
end

-- Show help popup (styled to match input popup)
function M.show_help()
	-- Ensure highlight groups exist
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
		"O          Toggle tool output (per-tool)",
		"<CR>       Toggle details",
		"gd         Enter subagent output",
		"<BS>       Go back to parent",
		"gD         View diff",
		"",
		"Question Tool",
		"1-9        Select option by number",
		"↑/↓ j/k    Navigate options",
		"Space      Toggle multi-select",
		"c          Custom input",
		"<CR>       Confirm selection",
		"<Esc>      Cancel question",
		"<Tab>      Next question tab",
		"<S-Tab>    Previous question tab",
		"",
		"Permissions",
		"1-3        Select option by number",
		"↑/↓ j/k    Navigate options",
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

	-- Position relative to the chat window
	local chat_winid = vim.api.nvim_get_current_win()
	local chat_pos = vim.api.nvim_win_get_position(chat_winid)
	local chat_win_width = vim.api.nvim_win_get_width(chat_winid)
	local chat_win_height = vim.api.nvim_win_get_height(chat_winid)

	local row = chat_pos[1] + math.floor((chat_win_height - height) / 2)
	local col = chat_pos[2] + math.floor((chat_win_width - width) / 2)

	local popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = { "", "", "", "", "", "", "", "┃" },
		},
		position = { row = row, col = col },
		size = { width = width - 1, height = height },
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg,FloatBorder:OpenCodeInputBorder",
		},
	})

	popup:mount()
	vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
	vim.bo[popup.bufnr].modifiable = false

	-- Apply highlights: section headers get agent color, keybind lines get hint style
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
			-- Highlight the key portion (up to first space after key)
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

	-- Close on various keys
	local close_keys = { "q", "<Esc>", "<CR>", "<Space>" }
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, function()
			popup:unmount()
		end, { buffer = popup.bufnr, noremap = true, silent = true })
	end

	-- Close on any alphanumeric key
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

-- Create chat window
function M.create()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end

	state.config = get_config()
	state.bufnr = create_buffer()
	state.messages = {}

	-- Subscribe to chat_render events from events.lua
	-- This is how the sync store notifies us to re-render
	local events = require("opencode.events")
	events.on("chat_render", function(data)
		vim.schedule(function()
			M.schedule_render()
		end)
	end)

	-- Subscribe to status changes to manage loading spinner
	events.on("status_change", function(data)
		vim.schedule(function()
			local new_status = data and data.status
			if new_status == "streaming" or new_status == "thinking" then
				-- Don't start spinner if there's a pending question awaiting user input
				local has_pending_question = false
				for _, msg in ipairs(state.messages) do
					if (msg.type == "question" or msg.type == "permission") and msg.status == "pending" then
						has_pending_question = true
						break
					end
				end

				if has_pending_question then
					-- Don't start spinner while user needs to answer a question
					return
				end

				-- Start spinner if not already active (picks new random animation)
				if not spinner.is_active() then
					spinner.start()
					M.schedule_render()
				end
			else
				-- Stop spinner for idle, paused, or error states
				if spinner.is_active() then
					spinner.stop()
					M.schedule_render()
				end
			end
		end)
	end)

	-- Advance spinner frame on each server event (event-driven animation)
	events.on("chat_render", function()
		if spinner.is_active() then
			spinner.tick()
			M.update_spinner_only()
		end
	end)

	-- Reset spinner on session change (pick new random animation)
	-- Also clear any pending questions from the old session
	events.on("session_change", function(data)
		-- Capture navigating flag NOW (before vim.schedule defers)
		local is_navigating = state.navigating
		vim.schedule(function()
			if spinner.is_active() then
				spinner.stop()
			end
			-- Clear pending questions, permissions, and edits from the old session
			state.pending_questions = {}
			state.pending_permissions = {}
			state.pending_edits = {}
			-- Clear position tracking
			state.questions = {}
			state.permissions = {}
			state.edits = {}
			state.tasks = {}
			state.expanded_tasks = {}
			state.task_child_cache = {}
			state.tools = {}
			state.expanded_tools = {}
			-- Remove question/permission messages from state.messages (they belong to old session)
			-- But preserve them when navigating into/out of child sessions
			if not is_navigating then
				local new_messages = {}
				for _, msg in ipairs(state.messages) do
					if msg.type ~= "question" and msg.type ~= "permission" then
						table.insert(new_messages, msg)
					end
				end
				state.messages = new_messages
			end
			-- Clear navigation stack unless we're drilling into a child session
			if not is_navigating then
				state.session_stack = {}
			end
		end)
	end)

	-- Render initial content
	M.do_render()

	return state.bufnr
end

-- Process any pending questions that were queued while chat was not visible
-- This is a forward declaration; the actual implementation uses M.add_question_message
local function process_pending_questions()
	if #state.pending_questions == 0 then
		return
	end

	local logger = require("opencode.logger")
	logger.debug("Processing pending questions", { count = #state.pending_questions })

	-- Copy and clear the pending queue to avoid re-processing
	local pending = state.pending_questions
	state.pending_questions = {}

	for _, pq in ipairs(pending) do
		-- Check if the question is still active (not already answered/rejected)
		local qstate = question_state.get_question(pq.request_id)
		if qstate and qstate.status == "pending" then
			-- Re-call add_question_message now that chat is visible
			-- The function will now proceed since state.visible is true
			M.add_question_message(pq.request_id, pq.questions, pq.status)
			logger.debug("Displayed pending question", { request_id = pq.request_id:sub(1, 10) })
		else
			logger.debug("Skipping stale pending question", {
				request_id = pq.request_id:sub(1, 10),
				reason = qstate and qstate.status or "not found",
			})
		end
	end
end

-- Process any pending permissions that were queued while chat was not visible
local function process_pending_permissions()
	if #state.pending_permissions == 0 then
		return
	end

	local logger = require("opencode.logger")
	logger.debug("Processing pending permissions", { count = #state.pending_permissions })

	local pending = state.pending_permissions
	state.pending_permissions = {}

	for _, pp in ipairs(pending) do
		local pstate = permission_state.get_permission(pp.permission_id)
		if pstate and pstate.status == "pending" then
			M.add_permission_message(pp.permission_id, pstate, pp.status)
			logger.debug("Displayed pending permission", { permission_id = pp.permission_id })
		else
			logger.debug("Skipping stale pending permission", {
				permission_id = pp.permission_id,
				reason = pstate and pstate.status or "not found",
			})
		end
	end
end

-- Process any pending edits that were queued while chat was not visible
local function process_pending_edits()
	if #state.pending_edits == 0 then
		return
	end

	local logger = require("opencode.logger")
	logger.debug("Processing pending edits", { count = #state.pending_edits })

	local pending = state.pending_edits
	state.pending_edits = {}

	for _, pe in ipairs(pending) do
		local estate = edit_state.get_edit(pe.permission_id)
		if estate and estate.status == "pending" then
			M.add_edit_message(pe.permission_id, estate, pe.status)
			logger.debug("Displayed pending edit", { permission_id = pe.permission_id })
		else
			logger.debug("Skipping stale pending edit", {
				permission_id = pe.permission_id,
				reason = estate and estate.status or "not found",
			})
		end
	end
end

-- Open chat window
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
		-- Float layout
		local popup = Popup({
			enter = true,
			focusable = true,
			border = {
				style = cfg.float.border,
				text = {
					top = cfg.float.title,
					top_align = cfg.float.title_pos,
				},
			},
			position = { row = dims.row, col = dims.col },
			size = { width = dims.width, height = dims.height },
			bufnr = state.bufnr,
			win_options = {
				fillchars = "eob: ",
			},
		})

		popup:mount()
		state.layout = popup
		state.winid = popup.winid

		-- Handle unmount
		popup:on(event.BufLeave, function()
			state.visible = false
			state.winid = nil
		end)
	else
		-- Split layout
		local split_cmd = "split"
		local split_opts = {}

		if cfg.layout == "vertical" then
			split_cmd = cfg.position == "right" and "botright vsplit" or "topleft vsplit"
			split_opts.width = cfg.width
		else
			split_cmd = cfg.position == "bottom" and "botright split" or "topleft split"
			split_opts.height = cfg.height
		end

		-- Create split window
		vim.cmd(split_cmd)
		state.winid = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)

		-- Set window dimensions
		if cfg.layout == "vertical" then
			vim.api.nvim_win_set_width(state.winid, cfg.width)
		else
			vim.api.nvim_win_set_height(state.winid, cfg.height)
		end

		-- Mark as scratch buffer
		vim.wo[state.winid].winfixwidth = cfg.layout == "vertical"
		vim.wo[state.winid].winfixheight = cfg.layout == "horizontal"

		-- Hide end-of-buffer markers
		vim.wo[state.winid].fillchars = "eob: "
	end

	state.visible = true

	-- Process any questions/permissions/edits that were queued while chat was not visible
	process_pending_questions()
	process_pending_permissions()
	process_pending_edits()

	-- Move cursor to end
	local line_count = vim.api.nvim_buf_line_count(state.bufnr)
	if line_count > 0 then
		vim.api.nvim_win_set_cursor(state.winid or 0, { line_count, 0 })
	end
end

-- Close chat window
function M.close()
	if not state.visible then
		return
	end

	if state.config.layout == "float" and state.layout then
		state.layout:unmount()
	else
		-- Close split window
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			vim.api.nvim_win_close(state.winid, true)
		end
	end

	state.visible = false
	state.winid = nil
	state.layout = nil
end

-- Toggle chat window
function M.toggle()
	if state.visible then
		M.close()
	else
		M.open()
	end
end

-- Check if chat is visible
function M.is_visible()
	return state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid)
end

-- Get window ID
function M.get_winid()
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		return state.winid
	end
	return nil
end

-- Get buffer number (creates if needed)
function M.get_bufnr()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		M.create()
	end
	return state.bufnr
end

-- Add a message to the chat
---@param role string "user" | "assistant" | "system"
---@param content string Message content
---@param opts? table Additional options (timestamp, etc.)
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

-- Render a single message
function M.render_message(message)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local lines = {}
	local highlights = {}

	-- Skip rendering empty assistant messages (no content and no reasoning)
	if
		message.role == "assistant"
		and (not message.content or message.content == "")
		and (not message.reasoning or message.reasoning == "")
	then
		return
	end

	-- Message header with ID for debugging
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

	-- Separator line
	table.insert(lines, string.rep("─", 60))

	-- Render reasoning/thinking content if available
	if message.reasoning and message.reasoning ~= "" and thinking.is_enabled() then
		local reasoning_lines = thinking.format_reasoning(message.reasoning)
		local reasoning_start = #lines

		for _, line in ipairs(reasoning_lines) do
			table.insert(lines, line)
		end

		-- Apply thinking highlights after content is inserted
		vim.schedule(function()
			if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
				thinking.apply_highlights(state.bufnr, line_count + reasoning_start, #reasoning_lines)
			end
		end)
	end

	-- Message content with markdown rendering
	local use_markdown = markdown.has_markdown(message.content)
	if use_markdown then
		local md_lines, md_highlights = markdown.render_to_lines(markdown.parse(message.content))
		for _, line in ipairs(md_lines) do
			table.insert(lines, line)
		end
		for _, hl in ipairs(md_highlights) do
			hl.line = hl.line + 2 -- Offset for header + separator
			table.insert(highlights, hl)
		end
	else
		-- Plain text
		local content_lines = vim.split(message.content, "\n", { plain = true })
		for _, line in ipairs(content_lines) do
			table.insert(lines, line)
		end
	end

	-- Check for and render tool calls
	local has_tools, tool_list = tools.has_tool_calls(message.content)
	if has_tools then
		local content_offset = #lines
		local tool_lines, tool_highlights, tool_indices = tools.render_tool_calls(tool_list, content_offset)

		for _, line in ipairs(tool_lines) do
			table.insert(lines, line)
		end
		for _, hl in ipairs(tool_highlights) do
			table.insert(highlights, hl)
		end

		-- Store tool indices for this message (for keymap navigation)
		message._tool_indices = tool_indices
		message._tools = tool_list
	end

	-- Empty line after message
	table.insert(lines, "")

	-- Append to buffer
	vim.bo[state.bufnr].modifiable = true
	local line_count = vim.api.nvim_buf_line_count(state.bufnr)
	vim.api.nvim_buf_set_lines(state.bufnr, line_count, line_count, false, lines)

	-- Apply highlights
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

	-- Auto-scroll if at bottom
	if state.auto_scroll and state.visible and state.winid then
		local cursor = vim.api.nvim_win_get_cursor(state.winid)
		local win_height = vim.api.nvim_win_get_height(state.winid)
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)

		-- Only scroll if user is already at bottom
		if cursor[1] >= buf_lines - win_height - 1 then
			vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
		end
	end
end

-- Clear all messages (UI only - session handling is done in opencode.clear())
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
	state.last_render_time = 0
	state.render_scheduled = false

	-- Stop spinner if active
	if spinner.is_active() then
		spinner.stop()
	end

	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
		vim.bo[state.bufnr].modifiable = false
	end

	-- Clear question, permission, and edit state as well
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

-- Get all messages
function M.get_messages()
	return vim.deepcopy(state.messages)
end

-- Load messages from server into chat (used when switching sessions)
-- messages: array of server message objects { id, role, parts, time, ... }
function M.load_messages(messages)
	if not messages or #messages == 0 then
		return
	end

	local sync = require("opencode.sync")

	for _, msg in ipairs(messages) do
		-- Convert server message format to local format
		local role = msg.role or "assistant"
		local content = ""

		-- Get text content from parts
		if msg.parts then
			local texts = {}
			for _, part in ipairs(msg.parts) do
				if part.type == "text" and part.text then
					table.insert(texts, part.text)
				end
			end
			content = table.concat(texts, "\n")
		else
			-- Fallback: try to get from sync store
			content = sync.get_message_text(msg.id)
		end

		-- Add message to local state
		M.add_message(role, content, {
			id = msg.id,
			timestamp = msg.time and msg.time.created or os.time(),
		})
	end
end

-- Tool icons matching TUI style
local TOOL_ICONS = {
	bash = "$",
	glob = "✱",
	read = "→",
	grep = "✱",
	list = "→",
	write = "←",
	edit = "←",
	webfetch = "%",
	websearch = "◈",
	codesearch = "◇",
	task = "◉",
	todowrite = "⚙",
	todoread = "⊙",
	question = "→",
	apply_patch = "%",
}

-- Get tool icon
local function get_tool_icon(tool_name)
	return TOOL_ICONS[tool_name] or "⚙"
end

-- Format tool display line (like TUI's InlineTool)
local function format_tool_line(tool_part)
	local tool_name = tool_part.tool or "unknown"
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	local icon = get_tool_icon(tool_name)
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = tool_part.state and tool_part.state.metadata or {}

	-- Format based on tool type (matching TUI patterns)
	if tool_name == "glob" then
		local pattern = input.pattern or ""
		local count = metadata.count or 0
		if tool_status == "completed" then
			return string.format('%s Glob "%s" (%d matches)', icon, pattern, count)
		end
		return string.format("~ Finding files...")
	elseif tool_name == "grep" then
		local pattern = input.pattern or ""
		local matches = metadata.matches or 0
		if tool_status == "completed" then
			return string.format('%s Grep "%s" (%d matches)', icon, pattern, matches)
		end
		return string.format("~ Searching content...")
	elseif tool_name == "read" then
		local filepath = input.filePath or input.file_path or ""
		-- Shorten path if too long
		if #filepath > 40 then
			filepath = "..." .. filepath:sub(-37)
		end
		if tool_status == "completed" then
			return string.format("%s Read %s", icon, filepath)
		end
		return string.format("~ Reading file...")
	elseif tool_name == "write" then
		local filepath = input.filePath or input.file_path or ""
		if #filepath > 40 then
			filepath = "..." .. filepath:sub(-37)
		end
		if tool_status == "completed" then
			return string.format("%s Wrote %s", icon, filepath)
		end
		return string.format("~ Preparing write...")
	elseif tool_name == "edit" then
		local filepath = input.filePath or input.file_path or ""
		if #filepath > 40 then
			filepath = "..." .. filepath:sub(-37)
		end
		if tool_status == "completed" then
			return string.format("%s Edit %s", icon, filepath)
		end
		return string.format("~ Preparing edit...")
	elseif tool_name == "bash" then
		local cmd = input.command or ""
		local desc = input.description or "Shell"
		if tool_status == "completed" then
			return string.format("# %s", desc)
		end
		return string.format("~ Writing command...")
	elseif tool_name == "todoread" or tool_name == "todowrite" then
		if tool_status == "completed" then
			return string.format("%s %s", icon, tool_name)
		end
		return string.format("~ Updating todos...")
	elseif tool_name == "task" then
		-- Task tools are rendered via render_task_tool; this is a fallback
		local subagent = input.subagent_type or "unknown"
		local desc = input.description or ""
		if tool_status == "completed" then
			return string.format('%s %s Task "%s"', icon, subagent:sub(1, 1):upper() .. subagent:sub(2), desc)
		end
		return string.format("~ Delegating...")
	else
		if tool_status == "completed" then
			return string.format("%s %s", icon, tool_name)
		end
		return string.format("~ %s...", tool_name)
	end
end

-- Build renderable content from a child session's messages
-- Reads from the sync store (must be populated before calling)
-- Returns { lines = {string...}, highlights = {{line, col_start, col_end, hl_group}...} }
local function build_child_session_content(session_id)
	local sync = require("opencode.sync")
	local messages = sync.get_messages(session_id)
	local result_lines = {}
	local result_highlights = {}

	local function add_line(text, hl_group)
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

	for _, message in ipairs(messages) do
		if message.role == "user" then
			local text = sync.get_message_text(message.id)
			if text and text ~= "" then
				local text_lines = vim.split(text, "\n", { plain = true })
				for i, line in ipairs(text_lines) do
					if i == 1 then
						add_line("  >> " .. line, "Special")
					else
						add_line("     " .. line, "Special")
					end
				end
			end
		elseif message.role == "assistant" then
			-- Tool calls
			local tool_parts = sync.get_message_tools(message.id)
			for _, tp in ipairs(tool_parts) do
				local tool_line = format_tool_line(tp)
				add_line("  " .. tool_line, "Comment")
			end
			-- Text content
			local text = sync.get_message_text(message.id)
			if text and text ~= "" then
				local text_lines = vim.split(text, "\n", { plain = true })
				for _, line in ipairs(text_lines) do
					add_line("  " .. line, nil)
				end
			end
		end
	end

	return { lines = result_lines, highlights = result_highlights }
end

-- Render a task tool part as multi-line display showing subagent activity
-- Returns { lines = {string...}, highlights = {{line, col_start, col_end, hl_group}...} }
local function render_task_tool(tool_part, expanded, child_content)
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = tool_part.state and tool_part.state.metadata or {}
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	local subagent = input.subagent_type or "unknown"
	local desc = input.description or ""
	local summary = metadata.summary or {}
	local agent_label = subagent:sub(1, 1):upper() .. subagent:sub(2)

	local result_lines = {}
	local result_highlights = {}

	local function add_line(text, hl_group)
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

	if tool_status == "completed" then
		local count = #summary
		local icon = expanded and "▾" or "▸"
		local header
		if count > 0 then
			header = string.format('%s %s Task — "%s" (%d toolcalls)', icon, agent_label, desc, count)
		else
			header = string.format('%s %s Task — "%s"', icon, agent_label, desc)
		end
		add_line(header, "Normal")

		if expanded and child_content then
			for _, cl in ipairs(child_content.lines) do
				table.insert(result_lines, cl)
			end
			for _, hl in ipairs(child_content.highlights) do
				table.insert(result_highlights, {
					line = hl.line + 1, -- offset by 1 for the header line
					col_start = hl.col_start,
					col_end = hl.col_end,
					hl_group = hl.hl_group,
				})
			end
		elseif expanded then
			-- Loading state
			add_line("  (loading...)", "Comment")
		end
	elseif #summary == 0 then
		-- No summary yet — pending
		add_line("~ Delegating...", "Comment")
	else
		-- Running: show header + sub-tool lines
		local count = #summary
		local header = string.format('◉ %s Task — "%s"', agent_label, desc)
		add_line(header, "Special")

		for i, entry in ipairs(summary) do
			local entry_tool = entry.tool or "unknown"
			local entry_state = entry.state or {}
			local entry_status = entry_state.status or "pending"
			local entry_title = entry_state.title or entry_tool
			-- Shorten long titles
			if #entry_title > 50 then
				entry_title = entry_title:sub(1, 47) .. "..."
			end

			local is_last = (i == count)
			local connector = is_last and "└" or "├"
			local line
			if entry_status == "completed" then
				line = string.format("  %s ◎ %s", connector, entry_title)
				add_line(line, "Comment")
			else
				-- running or pending
				local count_str = string.format("(%d toolcalls)", count)
				if is_last then
					line = string.format("  %s ~ %s...", connector, entry_title)
					-- Add the count at the end of the last line
					line = line .. string.rep(" ", math.max(1, 40 - #line)) .. count_str
				else
					line = string.format("  %s ~ %s...", connector, entry_title)
				end
				add_line(line, "Normal")
			end
		end
	end

	return { lines = result_lines, highlights = result_highlights }
end

-- Fallback colors for agents (matches TUI's color palette)
local AGENT_FALLBACK_COLORS = {
	"DiagnosticInfo", -- blue
	"DiagnosticWarn", -- orange
	"DiagnosticHint", -- green
	"DiagnosticUnderline", -- cyan
	"Special", -- purple
	"Title", -- yellow
}

---Get highlight group for an agent (mirrors TUI's local.agent.color)
---@param agent_name string
---@return string hl_group
local function get_agent_hl(agent_name)
	local sync = require("opencode.sync")
	local agents = sync.get_agents()
	-- Find agent by name
	for i, agent in ipairs(agents) do
		if agent.name == agent_name then
			-- If agent has a color, we'd need to create a highlight group
			-- For simplicity, use fallback colors based on index
			return AGENT_FALLBACK_COLORS[((i - 1) % #AGENT_FALLBACK_COLORS) + 1]
		end
	end
	-- Agent not found, use first fallback color
	return AGENT_FALLBACK_COLORS[1]
end

---Calculate duration for an assistant message
---Duration = assistant.time.completed - parent_user.time.created
---@param message table Assistant message
---@param messages table[] All messages in session
---@return number|nil duration_ms Duration in milliseconds, or nil if not complete
local function calculate_duration(message, messages)
	-- Check if message is complete
	if not message.time or not message.time.completed then
		return nil
	end
	-- Find parent user message
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

---Check if assistant message should show metadata footer
---Show when: message has time.completed AND response is no longer being streamed
---@param message table
---@param is_streaming boolean Whether this message is still being streamed
---@return boolean
local function should_show_footer(message, is_streaming)
	if not message.time then
		return false
	end
	if not message.time.completed then
		return false
	end
	-- Don't show footer while the response is still being processed;
	-- it should only appear at the end when the request is fully complete (or cancelled)
	if is_streaming then
		return false
	end
	return true
end

---Render metadata footer for assistant message
---Format: ▣ Agent · modelID · duration
---@param message table Assistant message
---@param messages table[] All messages in session
---@return string line
---@return table[] highlights
local function render_metadata_footer(message, messages)
	local highlights = {}
	local parts = {}
	-- ▣ symbol with agent color
	local agent_name = message.agent or "unknown"
	local agent_hl = get_agent_hl(agent_name)
	table.insert(parts, "▣")
	-- Agent name (titlecase)
	table.insert(parts, " ")
	table.insert(parts, locale.titlecase(agent_name))
	-- Model ID
	local model_id = message.modelID or ""
	if model_id ~= "" then
		table.insert(parts, " · ")
		table.insert(parts, model_id)
	end
	-- Duration
	local duration_ms = calculate_duration(message, messages)
	if duration_ms then
		table.insert(parts, " · ")
		table.insert(parts, locale.duration(duration_ms))
	end
	local line = table.concat(parts)
	-- Calculate highlight positions
	-- ▣ symbol: position 0-2 (UTF-8: ▣ is 3 bytes)
	table.insert(highlights, {
		col_start = 0,
		col_end = 3,
		hl_group = agent_hl,
	})
	return line, highlights
end

--==============================================================================
-- NuiLine-based rendering helpers (component approach)
--==============================================================================

---Wrap a string to fit within max_width, breaking at word boundaries
---@param text string
---@param max_width number
---@return string[]
local function wrap_text(text, max_width)
	if max_width <= 0 then
		return { text }
	end
	if vim.fn.strdisplaywidth(text) <= max_width then
		return { text }
	end

	local result = {}
	local remaining = text
	while vim.fn.strdisplaywidth(remaining) > max_width do
		-- Walk character by character using vim's char index to handle multibyte
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

---Render a user message using NuiLine
---@param content string|nil
---@return NuiLine[]
local function render_user_message(content)
	local lines = {}
	local content_lines = vim.split(content or "", "\n", { plain = true })

	-- Get available width for content (window width minus "│ " prefix)
	local win_width = 80
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		win_width = vim.api.nvim_win_get_width(state.winid)
	end
	local max_content_width = win_width - 2

	-- Top border line
	local top_line = NuiLine()
	top_line:append(NuiText("│", "Special"))
	table.insert(lines, top_line)

	-- Content lines, wrapped to fit within border
	for _, text in ipairs(content_lines) do
		local wrapped = wrap_text(text, max_content_width)
		for _, wline in ipairs(wrapped) do
			local line = NuiLine()
			line:append(NuiText("│ ", "Special"))
			line:append(wline)
			table.insert(lines, line)
		end
	end

	-- Bottom border
	local bottom_line = NuiLine()
	bottom_line:append(NuiText("│", "Special"))
	table.insert(lines, bottom_line)

	-- Empty separator
	table.insert(lines, NuiLine())

	return lines
end

---Render reasoning using NuiLine
---@param reasoning string|nil
---@return NuiLine[]
local function render_reasoning(reasoning)
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

---Render a tool line as { lines = string[], highlights = [] }
---@param tool_part table
---@param is_expanded boolean
---@return table { lines: string[], highlights: table[] }
local function render_tool_line(tool_part, is_expanded)
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

	-- Build header: fold_icon status_symbol tool_name [- description]
	local fold_icon = is_expanded and "▾" or "▸"
	local header = fold_icon .. " " .. status_symbol .. " " .. tool_name
	if tool_part.input and tool_part.input.description then
		header = header .. " - " .. tool_part.input.description
	end
	add_hl_line(header, status_hl)

	-- Show full tool input/output when expanded
	if is_expanded then
		local tool_state_data = tool_part.state or {}
		local tool_input = tool_state_data.input
		local tool_output = tool_state_data.output
		local tool_error = tool_state_data.error

		-- Show input
		if tool_input then
			local input_str = type(tool_input) == "string" and tool_input or vim.json.encode(tool_input)
			add_hl_line("  Input: ", "Special")
			for _, iline in ipairs(vim.split(input_str, "\n", { plain = true })) do
				add_hl_line("    " .. iline, "Comment")
			end
		end

		-- Show output
		if tool_output then
			local output_str = type(tool_output) == "string" and tool_output or vim.inspect(tool_output)
			add_hl_line("  Output: ", "Special")
			for _, oline in ipairs(vim.split(output_str, "\n", { plain = true })) do
				add_hl_line("    " .. oline, "Comment")
			end
		end

		-- Show error
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

---Render content (markdown or plain) using NuiLine
---@param content string|nil
---@return NuiLine[]
local function render_content(content)
	local lines = {}
	if not content or content == "" then
		return lines
	end

	local use_markdown = markdown.has_markdown(content)

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

---Extract raw content from NuiLine array
---@param nui_lines NuiLine[]
---@return string[]
local function extract_lines(nui_lines)
	local lines = {}
	for _, nui_line in ipairs(nui_lines) do
		table.insert(lines, nui_line:content())
	end
	return lines
end

---Apply highlights from NuiLine array to buffer
---@param nui_lines NuiLine[]
---@param bufnr number
---@param ns_id number
---@param start_line number 0-indexed
local function apply_highlights(nui_lines, bufnr, ns_id, start_line)
	for i, nui_line in ipairs(nui_lines) do
		nui_line:highlight(bufnr, ns_id, start_line + i - 1)
	end
end

-- Render full buffer using NuiLine components
---@return string[] raw_lines, NuiLine[] nui_lines
function M.render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return {}, {}
	end

	local sync = require("opencode.sync")
	local app_state = require("opencode.state")
	local current_session = app_state.get_session()

	local nui_lines = {} -- NuiLine[] for building content
	local raw_lines = {} -- string[] for backward compat

	-- Helper to add a NuiLine and its raw content
	local function add_line(nui_line)
		table.insert(nui_lines, nui_line)
		table.insert(raw_lines, nui_line:content())
	end

	-- Helper to add raw line (for content without highlights)
	local function add_raw_line(text)
		local line = NuiLine()
		line:append(text)
		table.insert(nui_lines, line)
		table.insert(raw_lines, text)
	end

	-- Track which permissions/edits were rendered inline (to find orphans later)
	local rendered_perm_ids = {}
	local rendered_edit_ids = {}

	-- Helper: render a single permission state entry
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
			p_lines, p_highlights, _, first_option_offset =
				permission_widget.get_lines_for_permission(perm_id, pstate)
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

	-- Helper: render a single edit state entry
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

	-- Helper: render permissions for a message (inline)
	local function render_permissions(message_id)
		local perms = permission_state.get_permissions_for_message(message_id)
		for _, pstate in ipairs(perms) do
			rendered_perm_ids[pstate.permission_id] = true
			render_single_permission(pstate)
		end
	end

	-- Helper: render edits for a message (inline)
	local function render_edits(message_id)
		local edits = edit_state.get_edits_for_message(message_id)
		for _, estate in ipairs(edits) do
			rendered_edit_ids[estate.permission_id] = true
			render_single_edit(estate)
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
	local session_time = os.date("%Y-%m-%dT%H:%M:%SZ")
	local header_line = "# " .. session_name .. " - " .. session_time
	local header = NuiLine()
	header:append(NuiText(header_line, "Comment"))
	add_line(header)
	add_raw_line("")

	-- Get messages from sync store
	local messages = current_session.id and sync.get_messages(current_session.id) or {}

	-- Find the last assistant message index (for footer display logic)
	local last_assistant_idx = nil
	for i = #messages, 1, -1 do
		if messages[i].role == "assistant" then
			last_assistant_idx = i
			break
		end
	end

	-- Render all messages
	for msg_idx, message in ipairs(messages) do
		local content = sync.get_message_text(message.id)
		local reasoning = sync.get_message_reasoning(message.id)
		local tool_parts = sync.get_message_tools(message.id)

		local has_content = content and content ~= ""
		local has_reasoning = reasoning and reasoning ~= ""
		local has_tools = #tool_parts > 0
		local should_render = message.role ~= "assistant" or has_content or has_reasoning or has_tools

		if should_render then
			if message.role == "user" then
				-- User message using NuiLine helpers
				local msg_lines = render_user_message(content)
				for _, nl in ipairs(msg_lines) do
					add_line(nl)
				end

				-- Session retry status
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
				-- Reasoning
				if has_reasoning and thinking.is_enabled() then
					local reasoning_lines = render_reasoning(reasoning)
					for _, nl in ipairs(reasoning_lines) do
						add_line(nl)
					end
				end

				-- Tool calls
				if has_tools then
					for _, tool_part in ipairs(tool_parts) do
						if tool_part.tool == "task" then
							local is_expanded = state.expanded_tasks[tool_part.id] or false
							local cached = state.task_child_cache[tool_part.id]
							local result = render_task_tool(tool_part, is_expanded, cached)
							local base_line = #raw_lines
							for _, tl in ipairs(result.lines) do
								add_raw_line(tl)
							end
							state.tasks[tool_part.id] = {
								start_line = base_line,
								end_line = base_line + #result.lines - 1,
								tool_part = tool_part,
							}
						else
							local is_expanded = state.expanded_tools[tool_part.id] or false
							local result = render_tool_line(tool_part, is_expanded)
							local base_line = #raw_lines
							-- Build highlight lookup by line index
							local hl_by_line = {}
							for _, hl in ipairs(result.highlights) do
								hl_by_line[hl.line] = hl
							end
							for idx, tl in ipairs(result.lines) do
								table.insert(raw_lines, tl)
								local nl = NuiLine()
								local line_hl = hl_by_line[idx - 1]
								if line_hl then
									nl:append(NuiText(tl, line_hl.hl_group))
								else
									nl:append(tl)
								end
								table.insert(nui_lines, nl)
							end
							state.tools[tool_part.id] = {
								start_line = base_line,
								end_line = base_line + #result.lines - 1,
								tool_part = tool_part,
							}
						end
					end
				end

				-- Content
				if has_content then
					local content_lines = render_content(content)
					for _, nl in ipairs(content_lines) do
						add_line(nl)
					end
				end

				-- Footer (show for all completed assistant messages)
				local is_streaming = (msg_idx == last_assistant_idx and app_state.get_status() == "streaming")
				if should_show_footer(message, is_streaming) then
					local footer_line, _ = render_metadata_footer(message, messages)
					add_raw_line(footer_line)
					add_raw_line("")
				end

				-- Permissions and edits
				render_permissions(message.id)
				render_edits(message.id)
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
			-- Skip - rendered inline
			goto continue_local_message
		end

		local has_content = message.content and message.content ~= ""

		if has_content then
			local content_lines = render_content(message.content)
			for _, nl in ipairs(content_lines) do
				add_line(nl)
			end
			add_raw_line("")
		end
		::continue_local_message::
	end

	-- Build set of current session message IDs to identify orphans
	local session_msg_ids = {}
	for _, message in ipairs(messages) do
		session_msg_ids[message.id] = true
	end

	-- Render orphan permissions (from subagent/child sessions)
	-- Skip any whose message_id belongs to the current session (already rendered inline)
	local all_perms = permission_state.get_all()
	for _, pstate in ipairs(all_perms) do
		if not rendered_perm_ids[pstate.permission_id]
			and not (pstate.message_id and session_msg_ids[pstate.message_id]) then
			render_single_permission(pstate)
		end
	end

	-- Render orphan edits: pending edits with no message_id (or a message_id that
	-- belongs to a different session). Scoped to the current session so edits from
	-- a parent session don't bleed into a child-session view and vice versa.
	-- Resolved orphans (status == "sent") are intentionally omitted: they have no
	-- parent message to anchor to so showing them persistently below new messages
	-- would be misleading. Inline edits (message_id matches) always show their
	-- Approved/Rejected state regardless of status via the render_edits() path above.
	local session_edits = edit_state.get_all_for_session(current_session.id)
	for _, estate in ipairs(session_edits) do
		if not rendered_edit_ids[estate.permission_id]
			and not (estate.message_id and session_msg_ids[estate.message_id])
			and estate.status == "pending" then
			render_single_edit(estate)
		end
	end

	-- Empty state message
	if #raw_lines == 0 then
		add_raw_line(" No active session")
		add_raw_line(" Press 'i' to focus input")
		add_raw_line(" Press '<C-p>' for command palette")
		add_raw_line(" Press '?' for help")
		add_raw_line("")
	end

	-- Loading indicator
	if spinner.is_active() then
		local loading_text = spinner.get_loading_text("∴ Thinkin")
		local loading_line = NuiLine()
		loading_line:append(NuiText(loading_text, "Comment"))
		add_line(loading_line)
	end

	return raw_lines, nui_lines
end

-- Focus the chat window
function M.focus()
	if not state.visible then
		M.open()
	end

	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_set_current_win(state.winid)
	end
end

-- Focus input area
function M.focus_input()
	if not state.visible then
		M.open()
	end

	input.show({
		on_send = function(text)
			-- Send message via main module
			local opencode = require("opencode")
			opencode.send(text)
		end,
		on_cancel = function()
			-- Return focus to chat
			M.focus()
		end,
	})
end

-- Update configuration
function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", get_config(), opts or {})
end

-- Add a tool call message
---@param tool_name string Tool name
---@param args table Tool arguments
---@param opts? table Additional options
function M.add_tool_call(tool_name, args, opts)
	opts = opts or {}

	local tool_call = {
		name = tool_name,
		args = vim.json.encode(args),
		status = opts.status or "pending",
		result = opts.result,
		timestamp = os.time(),
	}

	-- Format as tool-call block
	local content = string.format("```tool-call\n%s\n```", vim.json.encode(tool_call))

	return M.add_message("system", content, { tool_calls = { tool_call } })
end

-- Update tool call status
---@param message_id string Message ID containing the tool call
---@param tool_index number Index of the tool call in the message
---@param status string New status (pending, running, success, error)
---@param result? table Optional result data
function M.update_tool_call(message_id, tool_index, status, result)
	-- Tool calls are now stored in sync store as tool parts
	-- Just trigger a re-render
	M.schedule_render()
	return true
end

-- Legacy function - tool activity is now read from sync store's tool parts
-- Kept for backwards compatibility
---@param message_id string Message ID
---@param tool_name string Tool name
---@param status string Status (pending, running, completed, error)
---@param input? table Optional input data
function M.update_tool_activity(message_id, tool_name, status, input)
	-- Tool state is already in sync store, just re-render
	M.schedule_render()
end

-- Clear tool activity for a message
-- Now a no-op since we use the sync store
function M.clear_tool_activity(message_id)
	-- No longer needed - sync store manages state
end

-- Update only the spinner line in-place using nvim_buf_set_text
-- This avoids a full buffer rebuild just to animate the spinner, preventing cursor blink
function M.update_spinner_only()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end
	if not spinner.is_active() then
		return
	end

	local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
	if buf_lines < 1 then
		return
	end

	-- The spinner text is always the last line of the buffer (added at end of render())
	local spinner_line = buf_lines - 1 -- 0-indexed
	local current_line = vim.api.nvim_buf_get_lines(state.bufnr, spinner_line, spinner_line + 1, false)[1] or ""

	local loading_text = spinner.get_loading_text("∴ Thinkin")

	-- Skip if text hasn't changed
	if current_line == loading_text then
		return
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_text(state.bufnr, spinner_line, 0, spinner_line, #current_line, { loading_text })
	vim.bo[state.bufnr].modifiable = false

	-- Update spinner highlight
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, spinner_line, spinner_line + 1)
	vim.api.nvim_buf_set_extmark(
		state.bufnr,
		chat_hl_ns,
		spinner_line,
		0,
		{ end_col = #loading_text, hl_group = "Comment" }
	)
end

-- Throttled render (like TUI's throttled updates)
-- Prevents excessive re-renders during streaming
local RENDER_THROTTLE_MS = 50

-- Schedule a render with throttling
function M.schedule_render()
	if state.render_scheduled then
		return
	end

	local now = vim.uv.now()
	local elapsed = now - state.last_render_time

	if elapsed >= RENDER_THROTTLE_MS then
		-- Enough time has passed, render immediately
		state.last_render_time = now
		M.do_render()
	else
		-- Schedule render after throttle period
		state.render_scheduled = true
		vim.defer_fn(function()
			state.render_scheduled = false
			state.last_render_time = vim.uv.now()
			M.do_render()
		end, RENDER_THROTTLE_MS - elapsed)
	end
end

-- Actually perform the render (incremental: only updates changed lines)
function M.do_render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	-- Check if user is at bottom BEFORE re-rendering (to preserve scroll position)
	local should_scroll = false
	if state.auto_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local cursor = vim.api.nvim_win_get_cursor(state.winid)
		local win_height = vim.api.nvim_win_get_height(state.winid)
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		-- Only auto-scroll if user is already near the bottom
		should_scroll = cursor[1] >= buf_lines - win_height - 1
	end

	-- Build new content using NuiLine-based render
	local new_lines, nui_lines = M.render()
	if #new_lines == 0 or #nui_lines == 0 then
		-- Still set empty state to ensure buffer is properly initialized
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, new_lines)
		vim.bo[state.bufnr].modifiable = false
		return
	end

	-- Get current buffer content for diffing
	local old_lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)

	-- Find first line that differs between old and new content
	local first_diff = nil
	local min_len = math.min(#old_lines, #new_lines)
	for i = 1, min_len do
		if old_lines[i] ~= new_lines[i] then
			first_diff = i - 1 -- 0-indexed
			break
		end
	end

	if first_diff == nil then
		if #old_lines == #new_lines then
			-- Nothing changed at all, skip buffer update
			return
		end
		-- Lines were appended or removed at the end
		first_diff = min_len -- 0-indexed
	end

	-- Ensure we don't try to highlight beyond buffer bounds
	first_diff = math.min(first_diff, buf_line_count - 1)
	if first_diff < 0 then
		first_diff = 0
	end

	-- Extract replacement lines (from first_diff to end of new content)
	local replacement = {}
	for i = first_diff + 1, #new_lines do
		table.insert(replacement, new_lines[i])
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, first_diff, -1, false, replacement)

	-- Clear and apply highlights using NuiLine
	buf_line_count = vim.api.nvim_buf_line_count(state.bufnr)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, first_diff, -1)
	for i, nui_line in ipairs(nui_lines) do
		local line_idx = i - 1 -- 0-indexed line index
		if line_idx >= first_diff and line_idx < buf_line_count then
			nui_line:highlight(state.bufnr, chat_hl_ns, i)
		end
	end

	vim.bo[state.bufnr].modifiable = false

	-- Position cursor on first option of a newly added question or permission
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
		-- Auto-scroll to bottom only if user was already at bottom
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
	end

	vim.cmd("redraw")
end

-- Legacy function - now just triggers a render since sync store has the data
-- Kept for backwards compatibility
---@param message_id string Message ID from server
---@param content string Current content (ignored - read from sync store)
function M.update_assistant_message(message_id, content)
	-- Data is already in sync store, just re-render
	M.schedule_render()
end

-- Legacy function - now just triggers a render since sync store has the data
-- Kept for backwards compatibility
---@param message_id string Message ID
---@param reasoning_text string Current reasoning content (ignored - read from sync store)
function M.update_reasoning(message_id, reasoning_text)
	if not thinking.is_enabled() then
		return
	end

	-- Store in thinking module for any additional processing
	thinking.store_reasoning(message_id, reasoning_text)

	-- Throttle UI updates
	if not thinking.should_update() then
		return
	end

	-- Data is already in sync store, just re-render
	M.schedule_render()
end

-- Clear streaming state (called when message is complete)
-- Now a no-op since we use the sync store
function M.clear_streaming_state()
	-- No longer needed - sync store manages state
end

-- Add a question message to the chat
---@param request_id string
---@param questions table
---@param status "pending" | "answered" | "rejected"
function M.add_question_message(request_id, questions, status)
	local logger = require("opencode.logger")

	logger.debug("add_question_message called", {
		request_id = request_id:sub(1, 10),
		has_bufnr = state.bufnr ~= nil,
		bufnr_valid = state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr),
		visible = state.visible,
	})

	-- If chat buffer isn't ready or visible, queue the question for later
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not state.visible then
		-- Queue the question to display when chat becomes visible
		table.insert(state.pending_questions, {
			request_id = request_id,
			questions = questions,
			status = status,
			timestamp = os.time(),
		})

		logger.debug("Question queued (chat not visible)", {
			request_id = request_id:sub(1, 10),
			pending_count = #state.pending_questions,
		})
		return
	end

	local qstate = question_state.get_question(request_id)
	if not qstate then
		logger.warn("Question state not found", { request_id = request_id:sub(1, 10) })
		return
	end

	-- Check if this question is already in state.messages to avoid duplicates
	local already_exists = false
	for _, msg in ipairs(state.messages) do
		if msg.type == "question" and msg.request_id == request_id then
			already_exists = true
			-- Update status if changed
			msg.status = status
			break
		end
	end

	-- Store question data in a special message entry (if not already present)
	if not already_exists then
		table.insert(state.messages, {
			role = "system",
			type = "question",
			request_id = request_id,
			questions = questions,
			status = status,
			timestamp = os.time(),
			id = "question_" .. request_id,
			source_session_id = qstate.session_id,
		})

		logger.debug("Question added to state.messages", {
			request_id = request_id:sub(1, 10),
			status = status,
		})
	else
		logger.debug("Question already in state.messages, updated status", {
			request_id = request_id:sub(1, 10),
			status = status,
		})
	end

	-- Focus cursor on the first option when the question renders
	if status == "pending" then
		state.focus_question = request_id
	end

	-- Trigger a render to display the question
	-- The render() function will now include questions from state.messages
	M.schedule_render()

	logger.debug("Question render scheduled", {
		request_id = request_id:sub(1, 10),
	})
end

-- Update question status and re-render
---@param request_id string
---@param status "answered" | "rejected"
---@param answers? table
function M.update_question_status(request_id, status, answers)
	local logger = require("opencode.logger")

	-- Find and update the message entry
	local found = false
	for _, msg in ipairs(state.messages) do
		if msg.type == "question" and msg.request_id == request_id then
			msg.status = status
			msg.answers = answers
			found = true
			break
		end
	end

	if not found then
		logger.debug("update_question_status: question not found in state.messages", {
			request_id = request_id:sub(1, 10),
		})
		return
	end

	logger.debug("update_question_status: triggering re-render", {
		request_id = request_id:sub(1, 10),
		status = status,
	})

	-- Trigger a re-render to update the question display
	M.schedule_render()
end

-- Get question at cursor position
---@return string|nil request_id
---@return table|nil question_state
function M.get_question_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1 -- 0-based

	for request_id, pos in pairs(state.questions) do
		if
			cursor_line >= pos.start_line
			and cursor_line <= pos.end_line
			and (pos.status == "pending" or pos.status == "confirming")
		then
			return request_id, question_state.get_question(request_id)
		end
	end

	return nil, nil
end

-- Handle question navigation (j/k or arrows)
---@param direction "up" | "down"
function M.handle_question_navigation(direction)
	local request_id, qstate = M.get_question_at_cursor()

	if request_id then
		question_state.move_selection(request_id, direction)
		M.rerender_question(request_id)
		return
	end

	-- Check permissions
	local perm_id, pstate = M.get_permission_at_cursor()
	if perm_id then
		permission_state.move_selection(perm_id, direction)
		M.rerender_permission(perm_id)
		return
	end

	-- Check edits
	local eid = M.get_edit_at_cursor()
	if eid then
		edit_state.move_selection(eid, direction)
		M.rerender_edit(eid)
		return
	end

	-- Not on a question, permission, or edit, use default navigation
	local key = direction == "up" and "k" or "j"
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
end

-- Handle number key selection (1-9)
---@param number number
function M.handle_question_number_select(number)
	local request_id, qstate = M.get_question_at_cursor()

	if request_id then
		question_state.select_option(request_id, number)
		M.rerender_question(request_id)
		return
	end

	-- Check permissions (only 1-3 valid)
	local perm_id, pstate = M.get_permission_at_cursor()
	if perm_id and number >= 1 and number <= 3 then
		permission_state.select_option(perm_id, number)
		M.rerender_permission(perm_id)
		return
	end

	-- Check edits (jump to file N)
	local eid = M.get_edit_at_cursor()
	if eid then
		local estate = edit_state.get_edit(eid)
		if estate and number >= 1 and number <= #estate.files then
			edit_state.move_selection_to(eid, number)
			M.rerender_edit(eid)
		end
		return
	end

	-- Not on a question, permission, or edit, pass through
	vim.api.nvim_feedkeys(tostring(number), "n", false)
end

-- Handle question confirmation (Enter) with double-Enter flow
-- 1st Enter on an answered question: confirms/locks the answer (stays on current tab)
-- 2nd Enter: advances to next unanswered question, or shows confirmation view if all answered
function M.handle_question_confirm()
	-- Check tasks first (expand/collapse completed subagent output)
	local task_part_id, task_info = M.get_task_at_cursor()
	if task_part_id then
		M.handle_task_toggle(task_part_id)
		return
	end

	local request_id, qstate = M.get_question_at_cursor()

	if request_id then
		-- If already in confirming state, handle the confirmation choice (Yes/No)
		if qstate.status == "confirming" then
			local current_selection = question_state.get_current_selection(request_id)
			local choice = current_selection and current_selection[1] or 1

			if choice == 1 then
				-- Submit answers
				M.submit_question_answers(request_id)
			else
				-- Cancel confirmation, return to last tab before confirm
				question_state.cancel_confirmation(request_id)
				M.rerender_question(request_id)
			end
			return
		end

		local current_tab = qstate.current_tab
		local total_count = #qstate.questions
		local current_selection = qstate.selections[current_tab]
		local is_current_answered = current_selection and current_selection.is_answered

		-- Case 1: Current question is NOT answered → warn user
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

		-- Case 2: Current question IS answered but NOT ready to advance → 1st Enter (confirm answer)
		if not question_state.is_ready_to_advance(request_id) then
			question_state.mark_ready_to_advance(request_id)
			-- Stay on current tab, just rerender (visual feedback could be added later)
			M.rerender_question(request_id)
			return
		end

		-- Case 3: Current question IS answered AND ready to advance → 2nd Enter
		local all_answered, unanswered_indices = question_state.are_all_answered(request_id)

		if not all_answered then
			-- Advance to the first unanswered question
			if #unanswered_indices > 0 then
				question_state.set_tab(request_id, unanswered_indices[1])
				M.rerender_question(request_id)
			end
			return
		end

		-- All questions are answered
		if total_count > 1 then
			-- Multi-question block: show confirmation view
			question_state.set_confirming(request_id)
			M.rerender_question(request_id)
		else
			-- Single question: submit immediately
			M.submit_question_answers(request_id)
		end
		return
	end

	-- Check permissions
	local perm_id, pstate = M.get_permission_at_cursor()
	if perm_id and pstate then
		M.handle_permission_confirm(perm_id, pstate)
		return
	end

	-- Check edits (Enter = open selected file)
	local eid = M.get_edit_at_cursor()
	if eid then
		local file = edit_state.get_selected_file(eid)
		if file and file.filepath and file.filepath ~= "" then
			vim.cmd("edit " .. vim.fn.fnameescape(file.filepath))
		end
		return
	end

	-- Not on a question, permission, or edit, use default Enter
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "n", false)
end

-- Submit question answers to server
---@param request_id string
function M.submit_question_answers(request_id)
	local answers = question_state.get_answers(request_id)

	-- Submit to server
	local client = require("opencode.client")
	local current_session = require("opencode.state").get_session()

	client.reply_to_question(current_session.id, request_id, answers, function(err, success)
		vim.schedule(function()
			if err then
				vim.notify("Failed to submit answer: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end

			-- Mark as answered locally
			question_state.mark_answered(request_id, answers)
			M.update_question_status(request_id, "answered", answers)
		end)
	end)
end

-- Handle question cancel (Esc)
function M.handle_question_cancel()
	local request_id, qstate = M.get_question_at_cursor()

	if request_id then
		-- If in confirming state, just cancel confirmation and return to pending
		if qstate.status == "confirming" then
			question_state.cancel_confirmation(request_id)
			M.rerender_question(request_id)
			return
		end

		-- Otherwise, reject the entire question on server
		local client = require("opencode.client")
		local current_session = require("opencode.state").get_session()

		client.reject_question(current_session.id, request_id, function(err, success)
			vim.schedule(function()
				if err then
					vim.notify("Failed to cancel question: " .. tostring(err), vim.log.levels.ERROR)
					return
				end

				-- Mark as rejected locally
				question_state.mark_rejected(request_id)
				M.update_question_status(request_id, "rejected")
			end)
		end)
		return
	end

	-- Check permissions
	local perm_id, pstate = M.get_permission_at_cursor()
	if perm_id then
		M.handle_permission_reject(perm_id)
		return
	end

	-- Check edits (Esc = reject all pending files)
	local eid = M.get_edit_at_cursor()
	if eid then
		M.handle_edit_reject_all()
		return
	end

	-- Not on a question, permission, or edit, use default Esc
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
end

-- Handle next tab (Tab)
function M.handle_question_next_tab()
	local request_id, qstate = M.get_question_at_cursor()

	if not request_id then
		-- Not on a question, pass through
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Tab>", true, false, true), "n", false)
		return
	end

	-- Ignore tab switching in confirming state
	if qstate.status == "confirming" then
		return
	end

	local next_tab = qstate.current_tab + 1
	if next_tab > #qstate.questions then
		next_tab = 1
	end

	question_state.set_tab(request_id, next_tab)
	M.rerender_question(request_id)
end

-- Handle previous tab (Shift+Tab)
function M.handle_question_prev_tab()
	local request_id, qstate = M.get_question_at_cursor()

	if not request_id then
		-- Not on a question, pass through
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<S-Tab>", true, false, true), "n", false)
		return
	end

	-- Ignore tab switching in confirming state
	if qstate.status == "confirming" then
		return
	end

	local prev_tab = qstate.current_tab - 1
	if prev_tab < 1 then
		prev_tab = #qstate.questions
	end

	question_state.set_tab(request_id, prev_tab)
	M.rerender_question(request_id)
end

-- Handle custom input (c key)
function M.handle_question_custom_input()
	local request_id, qstate = M.get_question_at_cursor()

	if not request_id then
		-- Not on a question, pass through 'c' key
		vim.api.nvim_feedkeys("c", "n", false)
		return
	end

	-- Ignore custom input in confirming state
	if qstate.status == "confirming" then
		return
	end

	local current_tab = qstate.current_tab
	local question = qstate.questions[current_tab]

	-- Check if custom input is allowed
	if not question.allow_custom and not question.allowCustom then
		vim.notify("Custom input not allowed for this question", vim.log.levels.WARN)
		return
	end

	-- Show input prompt
	local input = require("opencode.ui.input")
	input.show({
		on_send = function(text)
			if text and text ~= "" then
				-- Store custom input
				question_state.set_custom_input(request_id, current_tab, text)

				-- Clear any other selections for single-select questions
				if question.type ~= "multi" then
					question_state.update_selection(request_id, current_tab, {})
				end

				-- Re-render to show the custom input
				M.rerender_question(request_id)

				-- Return focus to chat
				M.focus()
			end
		end,
		on_cancel = function()
			-- Return focus to chat
			M.focus()
		end,
	})
end

-- Handle multi-select toggle (Space key)
function M.handle_question_toggle()
	local request_id, qstate = M.get_question_at_cursor()

	if not request_id then
		-- Not on a question, use default Space behavior
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Space>", true, false, true), "n", false)
		return
	end

	-- Ignore toggle in confirming state
	if qstate.status == "confirming" then
		return
	end

	local current_tab = qstate.current_tab
	local question = qstate.questions[current_tab]

	-- Only works for multi-select questions
	if question.type ~= "multi" then
		vim.notify("Use 1-9 to select an option (Space is for multi-select only)", vim.log.levels.INFO)
		return
	end

	-- Get current selection
	local current_selection = question_state.get_current_selection(request_id)
	local current_idx = current_selection and current_selection[1] or 1

	-- Toggle current option
	question_state.toggle_multi_select(request_id, current_idx)

	-- Re-render
	M.rerender_question(request_id)
end

-- Re-render a question in place
---@param request_id string
function M.rerender_question(request_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.questions[request_id]
	if not pos then
		return
	end

	local qstate = question_state.get_question(request_id)
	if not qstate then
		return
	end

	-- Find the message entry to get questions data
	local questions = nil
	for _, msg in ipairs(state.messages) do
		if msg.type == "question" and msg.request_id == request_id then
			questions = msg.questions
			break
		end
	end

	if not questions then
		return
	end

	-- Get new lines
	local lines, highlights, _ =
		question_widget.get_lines_for_question(request_id, { questions = questions }, qstate, qstate.status)

	-- Replace lines
	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, lines)

	-- Apply highlights
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + #lines)
	for _, hl in ipairs(highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(
			state.bufnr,
			chat_hl_ns,
			pos.start_line + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	-- Update position tracking
	state.questions[request_id].end_line = pos.start_line + #lines - 1
	state.questions[request_id].status = qstate.status
end

-- Clear all question tracking (e.g., on session change)
function M.clear_questions()
	state.questions = {}
end

-- Debug function to log question state
function M.debug_questions()
	local logger = require("opencode.logger")
	local all_questions = question_state.get_all_active()

	logger.info("Active questions", {
		count = question_state.get_question_count(),
		active = #all_questions,
		tracked = vim.tbl_count(state.questions),
	})

	for request_id, pos in pairs(state.questions) do
		local qstate = question_state.get_question(request_id)
		if qstate then
			logger.debug("Question details", {
				request_id = request_id:sub(1, 10),
				status = qstate.status,
				current_tab = qstate.current_tab,
				question_count = #qstate.questions,
				selections = qstate.selections,
				start_line = pos.start_line,
				end_line = pos.end_line,
			})
		end
	end

	vim.notify(string.format("Debug: %d active questions logged", #all_questions), vim.log.levels.INFO)
end

-- Check if there are pending questions waiting to be displayed
---@return number Number of pending questions
function M.get_pending_question_count()
	return #state.pending_questions
end

-- Check if there are any pending questions
---@return boolean
function M.has_pending_questions()
	return #state.pending_questions > 0
end

-- ==================== Permission handling ====================

-- Add a permission message to the chat (triggers render for inline display)
---@param permission_id string
---@param perm_data table Permission state data (unused, kept for API compatibility)
---@param status "pending" | "approved" | "rejected"
function M.add_permission_message(permission_id, perm_data, status)
	local logger = require("opencode.logger")

	logger.debug("add_permission_message called", {
		permission_id = permission_id,
		visible = state.visible,
	})

	-- If chat buffer isn't ready or visible, queue for later
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not state.visible then
		table.insert(state.pending_permissions, {
			permission_id = permission_id,
			perm_data = perm_data,
			status = status,
			timestamp = os.time(),
		})

		logger.debug("Permission queued (chat not visible)", {
			permission_id = permission_id,
			pending_count = #state.pending_permissions,
		})
		return
	end

	local pstate = permission_state.get_permission(permission_id)
	if not pstate then
		logger.warn("Permission state not found", { permission_id = permission_id })
		return
	end

	-- Focus cursor on the first option when the permission renders
	if status == "pending" then
		state.focus_permission = permission_id
	end

	-- Permissions are now rendered inline after their triggering message
	-- No need to add to state.messages anymore
	M.schedule_render()
end

-- Update permission status and re-render
---@param permission_id string
---@param status "approved" | "rejected"
function M.update_permission_status(permission_id, status)
	local logger = require("opencode.logger")

	-- Permission state is already updated in permission_state module
	-- Just trigger a re-render
	logger.debug("update_permission_status: triggering re-render", {
		permission_id = permission_id,
		status = status,
	})

	M.schedule_render()
end

-- Get permission at cursor position
---@return string|nil permission_id
---@return table|nil perm_state
function M.get_permission_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1 -- 0-based

	for perm_id, pos in pairs(state.permissions) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line and pos.status == "pending" then
			return perm_id, permission_state.get_permission(perm_id)
		end
	end

	return nil, nil
end

-- Handle permission confirmation (Enter)
function M.handle_permission_confirm(perm_id, pstate)
	local selected = pstate.selected_option or 1
	local reply
	if selected == 1 then
		reply = "once"
	elseif selected == 2 then
		reply = "always"
	else
		reply = "reject"
	end

	local client = require("opencode.client")
	client.respond_permission(perm_id, reply, {}, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to respond to permission: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end

			if reply == "reject" then
				permission_state.mark_rejected(perm_id)
				M.update_permission_status(perm_id, "rejected")
			else
				permission_state.mark_approved(perm_id, reply)
				M.update_permission_status(perm_id, "approved")
			end
		end)
	end)
end

-- Handle permission rejection (Esc)
function M.handle_permission_reject(perm_id)
	local client = require("opencode.client")
	client.respond_permission(perm_id, "reject", {}, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to reject permission: " .. tostring(err), vim.log.levels.ERROR)
				return
			end

			permission_state.mark_rejected(perm_id)
			M.update_permission_status(perm_id, "rejected")
		end)
	end)
end

-- Re-render a permission in place
---@param perm_id string
function M.rerender_permission(perm_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.permissions[perm_id]
	if not pos then
		return
	end

	local pstate = permission_state.get_permission(perm_id)
	if not pstate then
		return
	end

	local p_lines, p_highlights = permission_widget.get_lines_for_permission(perm_id, pstate)

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, p_lines)

	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + #p_lines)
	for _, hl in ipairs(p_highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(
			state.bufnr,
			chat_hl_ns,
			pos.start_line + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	state.permissions[perm_id].end_line = pos.start_line + #p_lines - 1
end

-- ==================== Edit widget handling ====================

-- Add an edit message to the chat (triggers render for inline display)
---@param permission_id string
---@param edit_data table Edit state data
---@param status "pending" | "sent"
function M.add_edit_message(permission_id, edit_data, status)
	local logger = require("opencode.logger")

	logger.debug("add_edit_message called", {
		permission_id = permission_id,
		visible = state.visible,
	})

	-- If chat buffer isn't ready or visible, queue for later
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) or not state.visible then
		table.insert(state.pending_edits, {
			permission_id = permission_id,
			edit_data = edit_data,
			status = status,
			timestamp = os.time(),
		})

		logger.debug("Edit queued (chat not visible)", {
			permission_id = permission_id,
			pending_count = #state.pending_edits,
		})
		return
	end

	local estate = edit_state.get_edit(permission_id)
	if not estate then
		logger.warn("Edit state not found", { permission_id = permission_id })
		return
	end

	-- Focus cursor on the first file line when the edit renders
	if status == "pending" then
		state.focus_edit = permission_id
	end

	-- Edits are rendered inline after their triggering message
	M.schedule_render()
end

-- Get edit at cursor position
---@return string|nil permission_id
function M.get_edit_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1 -- 0-based

	for eid, pos in pairs(state.edits) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line and pos.status == "pending" then
			return eid
		end
	end

	return nil
end

-- Handle accept selected file
function M.handle_edit_accept_file()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	local file = estate.files[estate.selected_file]
	if not file or file.status ~= "pending" then
		return
	end

	local ok, err = edit_state.accept_file(eid, estate.selected_file)
	if not ok then
		vim.notify("Failed to accept file: " .. (err or "unknown"), vim.log.levels.ERROR)
		return
	end

	-- Check if all resolved -> finalize
	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

-- Handle reject selected file
function M.handle_edit_reject_file()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	local file = estate.files[estate.selected_file]
	if not file or file.status ~= "pending" then
		return
	end

	local ok, err = edit_state.reject_file(eid, estate.selected_file)
	if not ok then
		vim.notify("Failed to reject file: " .. (err or "unknown"), vim.log.levels.ERROR)
		return
	end

	-- Check if all resolved -> finalize
	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

-- Handle accept all pending files
function M.handle_edit_accept_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	edit_state.accept_all(eid)

	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

-- Handle reject all pending files
function M.handle_edit_reject_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	edit_state.reject_all(eid)

	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

-- Handle resolve selected file manually
function M.handle_edit_resolve_file()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	local file = estate.files[estate.selected_file]
	if not file or file.status ~= "pending" then
		return
	end

	local ok, err = edit_state.resolve_file(eid, estate.selected_file)
	if not ok then
		vim.notify("Failed to resolve file: " .. (err or "unknown"), vim.log.levels.ERROR)
		return
	end

	-- Check if all resolved -> finalize
	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

-- Handle resolve all pending files manually
function M.handle_edit_resolve_all()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	edit_state.resolve_all(eid)

	if edit_state.are_all_resolved(eid) then
		M.finalize_edit(eid)
	else
		M.rerender_edit(eid)
	end
end

-- Handle toggle inline diff (= key, fugitive-style)
function M.handle_edit_toggle_diff()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	edit_state.toggle_inline_diff(eid, estate.selected_file)
	M.rerender_edit(eid)
end

-- Handle diff in new tab (dt key)
function M.handle_edit_diff_tab()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	local file = estate.files[estate.selected_file]
	if not file then
		return
	end

	-- Use native_diff to show a single file in a new tab
	-- Pass nil permission_id so it doesn't auto-reply to server
	local native_diff = require("opencode.ui.native_diff")
	native_diff.show(nil, {
		{
			filePath = file.filepath,
			relativePath = file.relative_path,
			before = file.before,
			after = file.after,
			type = file.file_type,
		},
	}, {})
end

-- Handle diff vsplit near chat (dv key)
function M.handle_edit_diff_split()
	local eid = M.get_edit_at_cursor()
	if not eid then
		return
	end

	local estate = edit_state.get_edit(eid)
	if not estate then
		return
	end

	local file = estate.files[estate.selected_file]
	if not file then
		return
	end

	M.open_inline_diff_split(file)
end

-- Open a vertical diff split near chat for a single file
---@param file table File entry from edit state
function M.open_inline_diff_split(file)
	local filepath = file.filepath
	local after_content = file.after or ""

	-- Open the actual file in a leftabove vsplit
	vim.cmd("leftabove vsplit " .. vim.fn.fnameescape(filepath))
	local actual_win = vim.api.nvim_get_current_win()
	local actual_buf = vim.api.nvim_get_current_buf()

	-- Create a scratch buffer for proposed content
	vim.cmd("vsplit")
	local proposed_win = vim.api.nvim_get_current_win()
	local proposed_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(proposed_win, proposed_buf)

	-- Set proposed content
	local proposed_lines = vim.split(after_content, "\n", { plain = true })
	vim.api.nvim_buf_set_lines(proposed_buf, 0, -1, false, proposed_lines)

	-- Configure proposed buffer
	vim.bo[proposed_buf].buftype = "nofile"
	vim.bo[proposed_buf].bufhidden = "wipe"
	vim.bo[proposed_buf].swapfile = false
	vim.bo[proposed_buf].modifiable = false

	-- Set filetype for syntax highlighting
	local ft = vim.filetype.match({ filename = filepath })
	if ft and ft ~= "" then
		vim.bo[proposed_buf].filetype = ft
	end

	local relative = file.relative_path or vim.fn.fnamemodify(filepath, ":t")
	pcall(vim.api.nvim_buf_set_name, proposed_buf, "[proposed] " .. relative)

	-- Enable diff on both windows
	vim.api.nvim_win_call(proposed_win, function()
		vim.cmd("diffthis")
	end)
	vim.api.nvim_win_call(actual_win, function()
		vim.cmd("diffthis")
	end)

	-- Focus the actual file window
	vim.api.nvim_set_current_win(actual_win)

	-- Set q to close both diff windows
	for _, buf in ipairs({ actual_buf, proposed_buf }) do
		if vim.api.nvim_buf_is_valid(buf) then
			vim.keymap.set("n", "q", function()
				-- Close proposed buffer/window
				if vim.api.nvim_buf_is_valid(proposed_buf) then
					vim.api.nvim_buf_delete(proposed_buf, { force = true })
				end
				-- Turn off diff in actual window
				if vim.api.nvim_win_is_valid(actual_win) then
					vim.api.nvim_win_call(actual_win, function()
						vim.cmd("diffoff")
					end)
				end
			end, { buffer = buf, noremap = true, silent = true })
		end
	end
end

-- Finalize an edit: send reply to server after all files resolved
---@param permission_id string
function M.finalize_edit(permission_id)
	local estate = edit_state.get_edit(permission_id)
	if not estate then
		return
	end

	-- Send "reject" if all files were rejected, otherwise "once"
	local resolution = edit_state.get_resolution(permission_id)
	local reply = (resolution == "all_rejected") and "reject" or "once"
	local client = require("opencode.client")
	client.respond_permission(permission_id, reply, {}, function(err)
		vim.schedule(function()
			if err then
				vim.notify("Failed to send edit reply: " .. vim.inspect(err), vim.log.levels.ERROR)
				return
			end

			edit_state.mark_sent(permission_id)
			M.schedule_render()
		end)
	end)
end

-- Re-render an edit widget in place
---@param edit_id string permission_id
function M.rerender_edit(edit_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.edits[edit_id]
	if not pos then
		return
	end

	local estate = edit_state.get_edit(edit_id)
	if not estate then
		return
	end

	local e_lines, e_highlights
	if estate.status == "sent" then
		e_lines, e_highlights = edit_widget.get_resolved_lines(edit_id, estate)
	else
		e_lines, e_highlights = edit_widget.get_lines_for_edit(edit_id, estate)
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, e_lines)

	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + #e_lines)
	for _, hl in ipairs(e_highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		pcall(
			vim.api.nvim_buf_set_extmark,
			state.bufnr,
			chat_hl_ns,
			pos.start_line + hl.line,
			hl.col_start,
			{ end_col = end_col, hl_group = hl.hl_group }
		)
	end

	vim.bo[state.bufnr].modifiable = false

	state.edits[edit_id].end_line = pos.start_line + #e_lines - 1
end

-- Get task at cursor position (completed or running)
---@return string|nil part_id
---@return table|nil task_info
function M.get_task_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1 -- 0-based

	for part_id, pos in pairs(state.tasks) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line then
			local tool_status = pos.tool_part.state and pos.tool_part.state.status or "pending"
			if tool_status == "completed" or tool_status == "running" then
				return part_id, pos
			end
		end
	end

	return nil, nil
end

-- Get regular tool at cursor position
---@return string|nil part_id
---@return table|nil tool_info
function M.get_tool_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1 -- 0-based

	for part_id, pos in pairs(state.tools) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line then
			return part_id, pos
		end
	end

	return nil, nil
end

-- Re-render a task widget in place (expand/collapse)
---@param part_id string
function M.rerender_task(part_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	local is_expanded = state.expanded_tasks[part_id] or false
	local cached = state.task_child_cache[part_id]
	local result = render_task_tool(pos.tool_part, is_expanded, cached)

	local old_line_count = pos.end_line - pos.start_line + 1
	local new_line_count = #result.lines
	local delta = new_line_count - old_line_count

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, result.lines)

	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + new_line_count)
	for _, hl in ipairs(result.highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		pcall(vim.api.nvim_buf_set_extmark, state.bufnr, chat_hl_ns, pos.start_line + hl.line, hl.col_start, {
			end_col = end_col,
			hl_group = hl.hl_group,
		})
	end

	vim.bo[state.bufnr].modifiable = false

	-- Update this task's end_line
	state.tasks[part_id].end_line = pos.start_line + new_line_count - 1

	-- Shift all widgets positioned after this task by the delta
	if delta ~= 0 then
		for id, qpos in pairs(state.questions) do
			if qpos.start_line > pos.start_line then
				state.questions[id].start_line = qpos.start_line + delta
				state.questions[id].end_line = qpos.end_line + delta
			end
		end
		for id, ppos in pairs(state.permissions) do
			if ppos.start_line > pos.start_line then
				state.permissions[id].start_line = ppos.start_line + delta
				state.permissions[id].end_line = ppos.end_line + delta
			end
		end
		for id, epos in pairs(state.edits) do
			if epos.start_line > pos.start_line then
				state.edits[id].start_line = epos.start_line + delta
				state.edits[id].end_line = epos.end_line + delta
			end
		end
		for id, tpos in pairs(state.tasks) do
			if id ~= part_id and tpos.start_line > pos.start_line then
				state.tasks[id].start_line = tpos.start_line + delta
				state.tasks[id].end_line = tpos.end_line + delta
			end
		end
		for id, tlpos in pairs(state.tools) do
			if tlpos.start_line > pos.start_line then
				state.tools[id].start_line = tlpos.start_line + delta
				state.tools[id].end_line = tlpos.end_line + delta
			end
		end
	end
end

-- Handle task toggle (expand/collapse child session content)
---@param part_id string
function M.handle_task_toggle(part_id)
	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	-- Toggle expanded state
	if state.expanded_tasks[part_id] then
		-- Collapse
		state.expanded_tasks[part_id] = nil
		M.rerender_task(part_id)
		return
	end

	-- Expand
	state.expanded_tasks[part_id] = true

	-- Check if we already have cached content
	if state.task_child_cache[part_id] then
		M.rerender_task(part_id)
		return
	end

	-- Get child session ID from metadata
	local metadata = pos.tool_part.state and pos.tool_part.state.metadata or {}
	local child_session_id = metadata.sessionId
	if not child_session_id then
		-- No child session, just show empty expanded state
		M.rerender_task(part_id)
		return
	end

	-- Show loading state immediately
	M.rerender_task(part_id)

	-- Fetch child session messages
	local client = require("opencode.client")
	local sync = require("opencode.sync")

	client.get_messages(child_session_id, {}, function(err, response)
		vim.schedule(function()
			if err then
				-- On error, collapse back
				state.expanded_tasks[part_id] = nil
				M.rerender_task(part_id)
				return
			end

			-- Populate sync store with fetched data
			if response and type(response) == "table" then
				for _, msg_with_parts in ipairs(response) do
					local info = msg_with_parts.info
					if info then
						info.sessionID = child_session_id
						sync.handle_message_updated(info)
					end
					local parts = msg_with_parts.parts
					if parts then
						for _, part in ipairs(parts) do
							sync.handle_part_updated(part)
						end
					end
				end
			end

			-- Build and cache content
			state.task_child_cache[part_id] = build_child_session_content(child_session_id)
			M.rerender_task(part_id)
		end)
	end)
end

-- Re-render a regular tool widget in place (expand/collapse)
---@param part_id string
function M.rerender_tool(part_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.tools[part_id]
	if not pos then
		return
	end

	local is_expanded = state.expanded_tools[part_id] or false
	local result = render_tool_line(pos.tool_part, is_expanded)

	local old_line_count = pos.end_line - pos.start_line + 1
	local new_line_count = #result.lines
	local delta = new_line_count - old_line_count

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, result.lines)

	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + new_line_count)
	for _, hl in ipairs(result.highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		pcall(vim.api.nvim_buf_set_extmark, state.bufnr, chat_hl_ns, pos.start_line + hl.line, hl.col_start, {
			end_col = end_col,
			hl_group = hl.hl_group,
		})
	end

	vim.bo[state.bufnr].modifiable = false

	-- Update this tool's end_line
	state.tools[part_id].end_line = pos.start_line + new_line_count - 1

	-- Shift all widgets positioned after this tool by the delta
	if delta ~= 0 then
		for id, qpos in pairs(state.questions) do
			if qpos.start_line > pos.start_line then
				state.questions[id].start_line = qpos.start_line + delta
				state.questions[id].end_line = qpos.end_line + delta
			end
		end
		for id, ppos in pairs(state.permissions) do
			if ppos.start_line > pos.start_line then
				state.permissions[id].start_line = ppos.start_line + delta
				state.permissions[id].end_line = ppos.end_line + delta
			end
		end
		for id, epos in pairs(state.edits) do
			if epos.start_line > pos.start_line then
				state.edits[id].start_line = epos.start_line + delta
				state.edits[id].end_line = epos.end_line + delta
			end
		end
		for id, tpos in pairs(state.tasks) do
			if tpos.start_line > pos.start_line then
				state.tasks[id].start_line = tpos.start_line + delta
				state.tasks[id].end_line = tpos.end_line + delta
			end
		end
		for id, tlpos in pairs(state.tools) do
			if id ~= part_id and tlpos.start_line > pos.start_line then
				state.tools[id].start_line = tlpos.start_line + delta
				state.tools[id].end_line = tlpos.end_line + delta
			end
		end
	end
end

-- Handle tool toggle (expand/collapse tool input/output)
---@param part_id string
function M.handle_tool_toggle(part_id)
	local pos = state.tools[part_id]
	if not pos then
		return
	end

	if state.expanded_tools[part_id] then
		state.expanded_tools[part_id] = nil
	else
		state.expanded_tools[part_id] = true
	end
	M.rerender_tool(part_id)
end

-- Check if we're currently navigating between sessions (for event handlers to skip cleanup)
---@return boolean
function M.is_navigating()
	return state.navigating
end

-- Enter a child session (drill down into subagent output)
---@param part_id string
function M.enter_child_session(part_id)
	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	local metadata = pos.tool_part.state and pos.tool_part.state.metadata or {}
	local child_session_id = metadata.sessionId
	if not child_session_id then
		vim.notify("No child session available", vim.log.levels.WARN)
		return
	end

	local app_state = require("opencode.state")
	local client = require("opencode.client")
	local sync = require("opencode.sync")

	-- Push current session onto stack
	local current = app_state.get_session()
	local input = pos.tool_part.state and pos.tool_part.state.input or {}
	table.insert(state.session_stack, {
		id = current.id,
		name = current.name or "Session",
	})

	-- Derive a name for the child session
	local child_name = input.description or "Subagent"

	-- Switch session (set navigating flag to prevent session_change from clearing the stack)
	state.navigating = true
	app_state.set_session(child_session_id, child_name)
	state.navigating = false

	-- Fetch child session messages if not already in sync store
	local messages = sync.get_messages(child_session_id)
	if #messages > 0 then
		-- Schedule render after session_change cleanup runs
		vim.schedule(function()
			M.do_render()
		end)
	else
		-- Need to fetch first
		client.get_messages(child_session_id, {}, function(err, response)
			vim.schedule(function()
				if err then
					vim.notify("Failed to load subagent messages: " .. tostring(err), vim.log.levels.ERROR)
					M.leave_child_session()
					return
				end

				if response and type(response) == "table" then
					for _, msg_with_parts in ipairs(response) do
						local info = msg_with_parts.info
						if info then
							info.sessionID = child_session_id
							sync.handle_message_updated(info)
						end
						local parts = msg_with_parts.parts
						if parts then
							for _, part in ipairs(parts) do
								sync.handle_part_updated(part)
							end
						end
					end
				end

				M.do_render()
			end)
		end)
	end
end

-- Leave current child session and return to parent
function M.leave_child_session()
	if #state.session_stack == 0 then
		return
	end

	local app_state = require("opencode.state")
	local parent = table.remove(state.session_stack)

	state.navigating = true
	app_state.set_session(parent.id, parent.name)
	state.navigating = false

	-- Schedule render after session_change cleanup runs
	vim.schedule(function()
		M.do_render()
	end)
end

return M
