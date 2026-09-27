local chat_state = require("opencode.ui.chat.state").state
local render_state = require("opencode.ui.chat.render_state")
local sync = require("opencode.sync")
local app_state = require("opencode.state")

local M = {}

function M.setup()
	local surface = {
		winid = vim.api.nvim_get_current_win(),
		original_buffer = vim.api.nvim_get_current_buf(),
		saved_view = vim.tbl_extend("force", {}, chat_state),
		original_config = app_state.get_config(),
	}
	sync.clear_all()
	app_state.reset()
	app_state.set_config(vim.deepcopy(require("opencode.config").defaults))
	render_state.reset_chat_surface({ reset_expansions = true })
	chat_state.session_stack, chat_state.local_notices = {}, {}
	chat_state.task_child_cache, chat_state.task_child_loading = {}, {}
	chat_state.task_anim_frame = 1
	chat_state.render_scheduled, chat_state.render_in_progress = false, false
	chat_state.config = { max_rendered_messages = 20, session_tabs = { enabled = false } }
	surface.bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(surface.winid, surface.bufnr)
	chat_state.bufnr, chat_state.winid, chat_state.visible = surface.bufnr, surface.winid, true
	chat_state.auto_scroll = false
	return surface
end

function M.restore(surface)
	require("opencode.ui.chat.tasks").stop_task_animation_timer()
	vim.api.nvim_win_set_buf(surface.winid, surface.original_buffer)
	if vim.api.nvim_buf_is_valid(surface.bufnr) then
		vim.api.nvim_buf_delete(surface.bufnr, { force = true })
	end
	render_state.reset_chat_surface({ reset_expansions = true })
	for key in pairs(chat_state) do
		chat_state[key] = nil
	end
	for key, value in pairs(surface.saved_view) do
		chat_state[key] = value
	end
	sync.clear_all()
	app_state.reset()
	app_state.set_config(surface.original_config)
end

return M
