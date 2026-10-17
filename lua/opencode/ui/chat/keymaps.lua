local cs = require("opencode.ui.chat.state")
return cs.factory("keymaps", function(view)
local M = {}

local keymaps = require("opencode.util.keymap")

local actions = require("opencode.actions")
local chat_tasks = cs.module(view, require("opencode.ui.chat.tasks"))
local chat_edits = cs.module(view, require("opencode.ui.chat.edits"))
local chat_interactions = cs.module(view, require("opencode.ui.chat.interactions"))
local chat_questions = cs.module(view, require("opencode.ui.chat.questions"))
local chat_nav = cs.module(view, require("opencode.ui.chat.nav"))
local chat_session_tabs = cs.module(view, require("opencode.ui.chat.session_tabs"))
local palette = require("opencode.ui.palette")

local state = view

local SESSION_TAB_COUNT_MAPPING_LIMIT = 99

---@param bufnr number
---@param opts table
function M.setup_buffer(bufnr, opts)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode"
	vim.bo[bufnr].modifiable = false
	pcall(vim.api.nvim_buf_set_name, bufnr, view == cs.state and "opencode" or ("opencode [" .. view.id .. "]"))

	opts = opts or {}
	local cfg = state.config or {}
	local keymap_opts = { noremap = true, silent = true }
	local map, apply = keymaps.mapper("chat", bufnr, cfg.keymaps)
	local keys = keymaps.get("chat", cfg.keymaps)

	map("n", "close", function()
		if type(opts.close) == "function" then
			opts.close()
		end
	end, keymap_opts)

	if cfg.layout == "tab" then
		map("n", "split_vertical", function() actions.split("vertical", { view = view }) end, keymap_opts)
		map("n", "split_horizontal", function() actions.split("horizontal", { view = view }) end, keymap_opts)
	end

	map("n", "focus_input", function()
		if type(opts.focus_input) == "function" then
			opts.focus_input()
		end
	end, keymap_opts)

	map("n", "scroll_up", "<C-u>", keymap_opts)
	map("n", "scroll_down", "<C-d>", keymap_opts)
	map("n", "goto_top", "gg", keymap_opts)
	map("n", "goto_bottom", "G", keymap_opts)
	map("n", "prev_user_message", function()
		chat_nav.jump_user_message(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous user message" }))
	map("n", "next_user_message", function()
		chat_nav.jump_user_message(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next user message" }))
	map("n", "prev_message", function()
		chat_nav.jump_message_or_widget(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous message or widget" }))
	map("n", "next_message", function()
		chat_nav.jump_message_or_widget(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next message or widget" }))
	map("n", "prev_permission", function()
		chat_nav.jump_pending_permission(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous pending permission" }))
	map("n", "next_permission", function()
		chat_nav.jump_pending_permission(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next pending permission" }))

	map("n", "abort", function()
		actions.abort({ session_id = cs.session(view).id, view = view })
	end, vim.tbl_extend("force", keymap_opts, { desc = "Stop current generation" }))

	local pending_inputs = cs.module(view, require("opencode.ui.chat.pending_inputs"))
	for _, command in ipairs(pending_inputs.commands) do
		map("n", command.name .. "_pending", function(key)
			if pending_inputs.handle(command.name) then return end
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
		end, vim.tbl_extend("force", keymap_opts, { desc = command.description }))
	end

	map("n", "toggle_auto_scroll", function()
		if type(opts.toggle_auto_scroll) == "function" then
			opts.toggle_auto_scroll()
		end
	end, vim.tbl_extend("force", keymap_opts, { desc = "Toggle auto-scroll" }))

	map("n", "help", function()
		if type(opts.show_help) == "function" then
			opts.show_help()
		end
	end, keymap_opts)

	map("n", "command_palette", function()
		palette.show({ view = view, generation = view.generation })
	end, vim.tbl_extend("force", keymap_opts, { desc = "Open command palette" }))
	map("n", "timeline", function()
		require("opencode.ui.timeline").show({ view = view, generation = view.generation })
	end, vim.tbl_extend("force", keymap_opts, { desc = "Choose a historical user turn" }))
	map("n", "message_actions", function()
		require("opencode.ui.timeline").show_actions_at_cursor({ view = view, generation = view.generation })
	end, vim.tbl_extend("force", keymap_opts, { desc = "Actions for user message under cursor" }))

	map("n", "new_session", function()
		actions.new_session({ view = view })
	end, vim.tbl_extend("force", keymap_opts, { desc = "Start new session" }))

	map("n", "close_session", function()
		if cfg.layout == "tab" then return require("opencode.ui.chat.workspace").close_current() end
		actions.close_session({ notify = true, session_id = cs.session(view).id, view = view })
	end, vim.tbl_extend("force", keymap_opts, { desc = "Close current OpenCode session tab" }))

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

	map("n", "next_session", function()
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

	map("n", "prev_session", function()
		clear_pending_tab_count()
		chat_session_tabs.cycle_session(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous OpenCode session" }))

	for i = 0, 9 do
		local digit = i
		map("n", "select_" .. digit, function()
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

	map("n", "widget_next", function()
		chat_interactions.handle_question_navigation("down")
	end, keymap_opts)
	map("n", "widget_prev", function()
		chat_interactions.handle_question_navigation("up")
	end, keymap_opts)

	local function confirm(key)
		local id, pos = chat_tasks.get_tool_at_cursor()
		if chat_tasks.handle_tool_confirm(id, pos) then return end
		if pos and (pos.activity_group or pos.kind == "tool") then
			chat_tasks.handle_tool_toggle(id)
			return
		end
		chat_interactions.handle_question_confirm(key)
	end
	map("n", "confirm", confirm, keymap_opts)

	map("n", "next_question", function(key)
		chat_interactions.handle_question_next_tab(key)
	end, keymap_opts)
	map("n", "back", function(key)
		local request_id, question = chat_questions.get_question_at_cursor()
		if request_id and question.status ~= "confirming" then return end
		chat_interactions.handle_question_cancel(key)
	end, keymap_opts)
	map("n", "prev_question", function(key)
		chat_interactions.handle_question_prev_tab(key)
	end, keymap_opts)

	map("n", "custom_input", function(key)
		chat_interactions.handle_question_custom_input(key)
	end, keymap_opts)

	map("n", "widget_message", function(key)
		chat_interactions.handle_widget_message(key)
	end, keymap_opts)

	map("n", "toggle_selection", function(key)
		chat_interactions.handle_question_toggle(key)
	end, keymap_opts)

	local function dispatch_edit(handler, with_fallback, get_cursor)
		return function(key)
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

	map("n", "accept_edit", dispatch_edit(chat_edits.handle_edit_accept_file), keymap_opts)
	map("n", "reject_edit", dispatch_edit(chat_edits.handle_edit_reject_file), keymap_opts)
	local resolve_edit = dispatch_edit(chat_edits.handle_edit_resolve_file)
	map("n", "resolve_edit", function(key)
		-- Terminals encode the default <C-m> and <CR> as the same key.
		if keymaps.matches(keys.confirm, key) and not chat_edits.get_edit_at_cursor() then
			confirm(key)
		else
			resolve_edit(key)
		end
	end, vim.tbl_extend("force", keymap_opts, { aliases = { "confirm" } }))
	map("n", "toggle_diff", dispatch_edit(chat_edits.handle_edit_toggle_diff, true, chat_edits.get_diffable_edit_at_cursor), keymap_opts)
	map("n", "accept_all_edits", dispatch_edit(chat_edits.handle_edit_accept_all), keymap_opts)
	map("n", "reject_all_edits", dispatch_edit(chat_edits.handle_edit_reject_all), keymap_opts)
	map("n", "resolve_all_edits", dispatch_edit(chat_edits.handle_edit_resolve_all), keymap_opts)
	map("n", "diff_tab", dispatch_edit(chat_edits.handle_edit_diff_tab, false), vim.tbl_extend("force", keymap_opts, { nowait = true }))
	map("n", "diff_split", dispatch_edit(chat_edits.handle_edit_diff_split, false), vim.tbl_extend("force", keymap_opts, { nowait = true }))

	map("n", "enter_subagent", function()
		local task_part_id = chat_tasks.get_task_at_cursor()
		if task_part_id then
			chat_nav.enter_child_session(task_part_id)
		end
	end, vim.tbl_extend("force", keymap_opts, { nowait = true }))

	map("n", "leave_subagent", function()
		if #state.session_stack > 0 then
			chat_nav.leave_child_session()
		end
	end, keymap_opts)

	map("n", "toggle_tool", function()
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

	map("n", "cancel_question", function(key)
		local _, question = chat_questions.get_question_at_cursor()
		if question and question.status == "pending" then
			chat_interactions.confirm_question_cancel()
		elseif keymaps.matches(keys.back, key) then
			chat_interactions.handle_question_cancel(key)
		elseif not question then
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
		end
	end, vim.tbl_extend("force", keymap_opts, { desc = "Cancel question", aliases = { "back" } }))
	apply()

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = vim.api.nvim_create_augroup("OpenCodeChatKeymaps_" .. bufnr, { clear = true }),
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

end)
