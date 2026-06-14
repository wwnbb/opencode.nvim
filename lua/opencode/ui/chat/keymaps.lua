local M = {}

local actions = require("opencode.actions")
local chat_tasks = require("opencode.ui.chat.tasks")
local chat_todos = require("opencode.ui.chat.todos")
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

	vim.keymap.set("n", cfg.keymaps.abort, function()
		actions.abort()
	end, vim.tbl_extend("force", keymap_opts, { desc = "Stop current generation" }))

	vim.keymap.set("n", "a", function()
		if type(opts.toggle_auto_scroll) == "function" then
			opts.toggle_auto_scroll()
		end
	end, vim.tbl_extend("force", keymap_opts, { desc = "Toggle auto-scroll" }))

	local todo_keymap = cfg.todo and cfg.todo.keymaps and cfg.todo.keymaps.toggle
	if todo_keymap and todo_keymap ~= "" then
		vim.keymap.set("n", todo_keymap, function()
			chat_todos.toggle_current_dock()
		end, vim.tbl_extend("force", keymap_opts, { desc = "Cycle todo window" }))
	end

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

	vim.keymap.set("n", "gt", function()
		local count = tonumber(vim.v.count) or 0
		if count > 0 then
			chat_session_tabs.go_to_session_tab(count)
			return
		end
		chat_session_tabs.cycle_session(1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Next or counted OpenCode session" }))

	vim.keymap.set("n", "0gt", function()
		chat_session_tabs.go_to_session_tab(0)
	end, vim.tbl_extend("force", keymap_opts, { desc = "First OpenCode session" }))

	for i = 1, SESSION_TAB_COUNT_MAPPING_LIMIT do
		local index = i
		vim.keymap.set("n", tostring(index) .. "gt", function()
			chat_session_tabs.go_to_session_tab(index)
		end, vim.tbl_extend("force", keymap_opts, { desc = string.format("OpenCode session %d", index) }))
	end

	vim.keymap.set("n", "gT", function()
		chat_session_tabs.cycle_session(-1)
	end, vim.tbl_extend("force", keymap_opts, { desc = "Previous OpenCode session" }))

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
		chat_interactions.handle_question_confirm()
	end, keymap_opts)

	vim.keymap.set("n", "<Tab>", function()
		chat_interactions.handle_question_next_tab()
	end, keymap_opts)
	vim.keymap.set("n", "<S-Tab>", function()
		chat_interactions.handle_question_prev_tab()
	end, keymap_opts)

	for i = 1, 9 do
		vim.keymap.set("n", tostring(i), function()
			chat_interactions.handle_question_number_select(i)
		end, keymap_opts)
	end

	vim.keymap.set("n", "c", function()
		chat_interactions.handle_question_custom_input()
	end, keymap_opts)

	vim.keymap.set("n", "m", function()
		chat_interactions.handle_widget_message()
	end, keymap_opts)

	vim.keymap.set("n", "<Space>", function()
		chat_interactions.handle_question_toggle()
	end, keymap_opts)

	vim.keymap.set("n", "<C-a>", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_accept_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-a>", true, false, true), "n", false)
		end
	end, keymap_opts)

	vim.keymap.set("n", "<C-x>", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_reject_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x>", true, false, true), "n", false)
		end
	end, keymap_opts)

	vim.keymap.set("n", "<C-m>", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_resolve_file()
		else
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-m>", true, false, true), "n", false)
		end
	end, keymap_opts)

	vim.keymap.set("n", "=", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_toggle_diff()
		else
			vim.api.nvim_feedkeys("=", "n", false)
		end
	end, keymap_opts)

	vim.keymap.set("n", "A", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_accept_all()
		else
			vim.api.nvim_feedkeys("A", "n", false)
		end
	end, keymap_opts)

	vim.keymap.set("n", "X", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_reject_all()
		else
			vim.api.nvim_feedkeys("X", "n", false)
		end
	end, keymap_opts)

	vim.keymap.set("n", "M", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_resolve_all()
		else
			vim.api.nvim_feedkeys("M", "n", false)
		end
	end, keymap_opts)

	vim.keymap.set("n", "dt", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_diff_tab()
		end
	end, vim.tbl_extend("force", keymap_opts, { nowait = true }))

	vim.keymap.set("n", "dv", function()
		local eid = chat_edits.get_edit_at_cursor()
		if eid then
			chat_edits.handle_edit_diff_split()
		end
	end, vim.tbl_extend("force", keymap_opts, { nowait = true }))

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
