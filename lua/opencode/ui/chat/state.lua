-- Shared UI state for the chat module.
-- All chat sub-modules require this to access the same mutable state table.

local M = {}

-- UI state (only the chat buffer's view-layer state; message data lives in sync module)
M.state = {
	bufnr = nil,
	winid = nil,
	tabpage = nil,
	layout = nil,
	visible = false,
	local_notices = {},     -- Local user/system notices not backed by the server
	config = nil,
	questions = {},         -- Track question positions: { [request_id] = { start_line, end_line } }
	focus_question = nil,   -- request_id of question to focus cursor on after render
	focus_question_line = nil,
	permissions = {},       -- Track permission positions: { [permission_id] = { start_line, end_line } }
	focus_permission = nil, -- permission_id to focus cursor on after render
	focus_permission_line = nil,
	edits = {},             -- Track edit widget positions: { [permission_id] = { start_line, end_line } }
	focus_edit = nil,       -- permission_id to focus cursor on after render
	focus_edit_line = nil,
	tasks = {},             -- Track task positions: { [part_id] = { start_line, end_line, tool_part } }
	expanded_tasks = {},    -- Toggle set: { [part_id] = true }
	task_child_cache = {},  -- Rendered child content: { [part_id] = { lines, highlights } }
	tools = {},             -- Track tool positions: { [part_id] = { start_line, end_line, tool_part } }
	expanded_tools = {},    -- Toggle set: { [part_id] = true }
	todo_bufnr = nil,       -- Live todo window buffer
	todo_winid = nil,       -- Live todo window id
	todo_dock_collapsed = {}, -- Toggle set by session: { [session_id] = boolean }
	session_tabs_bufnr = nil, -- Float session tabs window buffer
	session_tabs_winid = nil, -- Float session tabs window id
	stream_blocks = {},     -- Streaming text blocks: { [message_id] = { start_line, end_line } }
	spinner_footer_line = nil,
	session_stack = {},     -- Stack of { id, name } for parent session navigation
	navigating = false,     -- Compatibility flag for older callers; session actions carry navigation metadata
	last_render_time = 0,
	render_scheduled = false,
	auto_scroll = false,    -- Auto-scroll to bottom on new content
	focus_augroup = nil,
	spinner_anim_timer = nil,
	task_anim_timer = nil,
	task_anim_frame = 1,
	float_dims = nil,
	winbar_targets = {},
}

-- Namespace for all chat buffer highlights (enables incremental highlight updates)
M.chat_hl_ns = vim.api.nvim_create_namespace("opencode_chat_hl")

return M
