local M = {}

local actions = require("opencode.actions")
local chat_tasks = require("opencode.ui.chat.tasks")
local chat_edits = require("opencode.ui.chat.edits")
local chat_interactions = require("opencode.ui.chat.interactions")
local chat_nav = require("opencode.ui.chat.nav")
local chat_session_tabs = require("opencode.ui.chat.session_tabs")
local palette = require("opencode.ui.palette")

local state = require("opencode.ui.chat.state").state

local SESSION_TAB_COUNT_MAPPING_LIMIT = 99

---@param bufnr number
---@param opts table
function M.setup_buffer(bufnr, opts)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode"
	vim.bo[bufnr].modifiable = false
	pcall(vim.api.nvim_buf_set_name, bufnr, "opencode")

	opts = opts or {}
	local cfg = state.config
	local keymap_opts = { buffer = bufnr, noremap = true, silent = true }

	vim.keymap.set("n", cfg.keymaps.close, function()
		if type(opts.close) == "function" then
			opts.close()
		end
	end, keymap_opts)

	vim.keymap.set("n", cfg.keymaps.focus_input, function()
		if type(opts.focus_input) == "function" then
			opts.focus_input()
		end
	end, keymap_opts)

	vim.keymap.set("n", cfg.keymaps.scroll_up, "<C-u>", keymap_opts)
	vim.keymap.set("n", cfg.keymaps.scroll_down, "<C-d>", keymap_opts)
	vim.keymap.set("n", cfg.keymaps.goto_top, "gg", keymap_opts)
	vim.keymap.set("n", cfg.keymaps.goto_bottom, "G", keymap_opts)
	vim.keymap.set("n", "[a", function()
		chat_nav.jump_user_message(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous user message" }))
	vim.keymap.set("n", "]a", function()
		chat_nav.jump_user_message(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next user message" }))
	vim.keymap.set("n", "[m", function()
		chat_nav.jump_message_or_widget(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous message or widget" }))
	vim.keymap.set("n", "]m", function()
		chat_nav.jump_message_or_widget(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next message or widget" }))
	vim.keymap.set("n", "[p", function()
		chat_nav.jump_pending_permission(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous pending permission" }))
	vim.keymap.set("n", "]p", function()
		chat_nav.jump_pending_permission(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next pending permission" }))

	vim.keymap.set("n", cfg.keymaps.abort, function()
		actions.abort()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Stop current generation" }))

	for _, mapping in ipairs({
		{ "cancel_pending", "cancel", "Cancel pending input at cursor" },
		{ "edit_pending", "edit", "Edit pending input at cursor" },
		{ "steer_pending", "steer", "Steer queued input at cursor" },
	}) do
		local key = cfg.keymaps[mapping[1]]
		if type(key) == "string" and key ~= "" then
			vim.keymap.set("n", key, function()
				if require("opencode.ui.chat.pending_inputs")[mapping[2]]() then return end
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
			end, vim.tbl_extend("force", keymap_opts, { desc = mapping[3] }))
		end
	end

	vim.keymap.set("n", "a", function()
		if type(opts.toggle_auto_scroll) == "function" then
			opts.toggle_auto_scroll()
		end
	end, vim.tbl_extend("force", keymap_opts, { desc = "Toggle auto-scroll" }))

	vim.keymap.set("n", "?", function()
		if type(opts.show_help) == "function" then
			opts.show_help()
		end
	end, keymap_opts)

	vim.keymap.set("n", "<C-p>", function()
		palette.show()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Open command palette" }))

	vim.keymap.set("n", "N", function()
		actions.new_session()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Start new session" }))

	if cfg.keymaps.close_session and cfg.keymaps.close_session ~= "" then
		vim.keymap.set("n", cfg.keymaps.close_session, function()
			actions.close_session({ notify = true })
		end, vim.tbl_extend("force", keymap_opts, { desc = "Close current OpenCode session tab" }))
	end

	-- Session tab switching by index: digits accumulate a pending count that the
	-- next `gt` consumes (`5gt`, `12gt`, `0gt` for the first session). The count
	-- lives in Lua instead of literal `Ngt` mappings so digit presses never wait
	-- on 'timeoutlen' disambiguation. Inside question/permission/edit widgets,
	-- digits select options immediately and drop any pending count.
	local pending_tab_count ---@type string|nil
	local pending_tab_timer ---@type integer|nil

	local function clear_pending_tab_count()
		pending_tab_count = nil
		if pending_tab_timer then
			vim.fn.timer_stop(pending_tab_timer)
			pending_tab_timer = nil
		end
	end

	local function arm_pending_tab_timer()
		if pending_tab_timer then
			vim.fn.timer_stop(pending_tab_timer)
			pending_tab_timer = nil
		end
		local timeout_ms = vim.api.nvim_get_option_value("timeoutlen", {})
		if type(timeout_ms) ~= "number" or timeout_ms <= 0 then
			return
		end
		pending_tab_timer = vim.fn.timer_start(timeout_ms, clear_pending_tab_count)
	end

	vim.keymap.set("n", "gt", function()
		if pending_tab_count ~= nil then
			local count = tonumber(pending_tab_count) or 0
			clear_pending_tab_count()
			chat_session_tabs.go_to_session_tab(count)
			return
		end
		local count = tonumber(vim.v.count) or 0
		if count > 0 then
			chat_session_tabs.go_to_session_tab(count)
			return
		end
		chat_session_tabs.cycle_session(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next or counted OpenCode session" }))

	vim.keymap.set("n", "gT", function()
		clear_pending_tab_count()
		chat_session_tabs.cycle_session(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous OpenCode session" }))

	for i = 0, 9 do
		local digit = i
		vim.keymap.set("n", tostring(digit), function()
			if digit >= 1 and chat_interactions.handle_question_number_select(digit) then
				clear_pending_tab_count()
				return
			end
			if pending_tab_count == nil and digit == 0 then
				-- Bare `0` keeps vanilla behavior (first column) while still
				-- arming count 0 so `0gt` jumps to the first session.
				vim.api.nvim_feedkeys("0", "n", false)
			end
			pending_tab_count = (pending_tab_count or "0") .. tostring(digit)
			if (tonumber(pending_tab_count) or 0) > SESSION_TAB_COUNT_MAPPING_LIMIT then
				pending_tab_count = tostring(digit)
			end
			arm_pending_tab_timer()
		end, keymap_opts)
	end

	vim.keymap.set("n", "j", function()
		chat_interactions.handle_question_navigation("down")
	end, keymap_opts)
	vim.keymap.set("n", "k", function()
		chat_interactions.handle_question_navigation("up")
	end, keymap_opts)
	vim.keymap.set("n", "<Down>", function()
		chat_interactions.handle_question_navigation("down")
	end, keymap_opts)
	vim.keymap.set("n", "<Up>", function()
		chat_interactions.handle_question_navigation("up")
	end, keymap_opts)

	vim.keymap.set("n", "<CR>", function()
		local id, pos = chat_tasks.get_tool_at_cursor()
		if pos and pos.activity_group then
			chat_tasks.handle_tool_toggle(id)
			return
		end
		chat_interactions.handle_question_confirm()
	end, keymap_opts)

	vim.keymap.set("n", "<Tab>", function()
		chat_interactions.handle_question_next_tab()
	end, keymap_opts)
	vim.keymap.set("n", "<S-Tab>", function()
		chat_interactions.handle_question_prev_tab()
	end, keymap_opts)

	vim.keymap.set("n", "c", function()
		chat_interactions.handle_question_custom_input()
	end, keymap_opts)

	vim.keymap.set("n", "m", function()
		chat_interactions.handle_widget_message()
	end, keymap_opts)

	vim.keymap.set("n", "<Space>", function()
		chat_interactions.handle_question_toggle()
	end, keymap_opts)

	local function dispatch_edit(key, handler, with_fallback, get_cursor)
		return function()
			local eid = (get_cursor or chat_edits.get_edit_at_cursor)()
			if eid then
				handler()
			elseif with_fallback ~= false then
				local key_to_feed = key
				if key:find("<") then
					key_to_feed = vim.api.nvim_replace_termcodes(key, true, false, true)
				end
				vim.api.nvim_feedkeys(key_to_feed, "n", false)
			end
		end
	end

	vim.keymap.set("n", "<C-a>", dispatch_edit("<C-a>", chat_edits.handle_edit_accept_file), keymap_opts)
	vim.keymap.set("n", "<C-x>", dispatch_edit("<C-x>", chat_edits.handle_edit_reject_file), keymap_opts)
	vim.keymap.set("n", "<C-m>", dispatch_edit("<C-m>", chat_edits.handle_edit_resolve_file), keymap_opts)
	vim.keymap.set("n", "=", dispatch_edit("=", chat_edits.handle_edit_toggle_diff, true, chat_edits.get_diffable_edit_at_cursor), keymap_opts)
	vim.keymap.set("n", "A", dispatch_edit("A", chat_edits.handle_edit_accept_all), keymap_opts)
	vim.keymap.set("n", "X", dispatch_edit("X", chat_edits.handle_edit_reject_all), keymap_opts)
	vim.keymap.set("n", "M", dispatch_edit("M", chat_edits.handle_edit_resolve_all), keymap_opts)
	vim.keymap.set("n", "dt", dispatch_edit("dt", chat_edits.handle_edit_diff_tab, false), vim.tbl_extend("force", keymap_opts, { nowait = true }))
	vim.keymap.set("n", "dv", dispatch_edit("dv", chat_edits.handle_edit_diff_split, false), vim.tbl_extend("force", keymap_opts, { nowait = true }))

	vim.keymap.set("n", "gd", function()
		local task_part_id = chat_tasks.get_task_at_cursor()
		if task_part_id then
			chat_nav.enter_child_session(task_part_id)
		end
	end, vim.tbl_extend("force", keymap_opts, { nowait = true }))

	vim.keymap.set("n", "<BS>", function()
		if #state.session_stack > 0 then
			chat_nav.leave_child_session()
		end
	end, keymap_opts)

	vim.keymap.set("n", "O", function()
		local task_part_id = chat_tasks.get_task_at_cursor()
		if task_part_id then
			chat_tasks.handle_task_toggle(task_part_id)
			return
		end

		local tool_part_id = chat_tasks.get_tool_at_cursor()
		if tool_part_id then
			chat_tasks.handle_tool_toggle(tool_part_id)
			return
		end
	end, vim.tbl_extend("force", keymap_opts, { desc = "Toggle tool output", nowait = true }))

	vim.api.nvim_create_autocmd("CursorMoved", {
		buffer = bufnr,
		callback = function()
			if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
				return
			end
			if vim.api.nvim_get_current_win() ~= state.winid then
				return
			end
			chat_interactions.sync_widget_selection_from_cursor()
		end,
	})
end

return M
