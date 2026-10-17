-- Chat view registry; each module instance captures its own view state.

local M = {}

-- UI state (only the chat buffer's view-layer state; message data lives in sync module)
M.state = {
	bufnr = nil,
	winid = nil,
	tabpage = nil,
	layout = nil,
	visible = false,
	full_history_sessions = {}, -- Explicitly expanded history by session ID
	local_notices = {},     -- Local user/system notices not backed by the server
	config = nil,
	questions = {},         -- Track question positions: { [request_id] = { start_line, end_line } }
	focus_question = nil,   -- request_id of question to focus cursor on after render
	focus_question_line = nil,
	focus_question_option = nil,
	permissions = {},       -- Track permission positions: { [permission_id] = { start_line, end_line } }
	focus_permission = nil, -- permission_id to focus cursor on after render
	focus_permission_line = nil,
	edits = {},             -- Track edit widget positions: { [permission_id] = { start_line, end_line } }
	focus_edit = nil,       -- permission_id to focus cursor on after render
	focus_edit_line = nil,
	message_positions = {}, -- Ordered visible message ranges for chat-local navigation
	pending_inputs = {},   -- Queued input widget ranges, excluding surrounding separators
	tasks = {},             -- Track task positions: { [part_id] = { start_line, end_line, tool_part } }
	expanded_tasks = {},    -- Toggle set: { [part_id] = true }
	task_child_cache = {},  -- Loaded child-session markers: { [part_id] = true }
	task_child_loading = {}, -- In-flight child-session loads: { [part_id] = true }
	task_summary_cache = { entries = {}, order = {} }, -- Derived child summaries keyed by summary revision
	tools = {},             -- Widget roots keyed by ID; containers own a children map of tool nodes
	expanded_tools = {},    -- Per-node toggle set; activity IDs are distinct from tool part IDs
	session_tabs_bufnr = nil, -- Float session tabs window buffer
	session_tabs_winid = nil, -- Float session tabs window id
	session_tabs_start = nil, -- First active-session index shown in the tab strip
	session_tabs_current_id = nil, -- Current root session id used for tab strip centering
	session_tabs_mouse_targets = {}, -- Float tab click targets: { start_col, end_col, target }
	stream_blocks = {},     -- Streaming part blocks: { [session/message/part/kind] = { start_line, end_line } }
	spinner_footer_line = nil,
	render_cache = nil,     -- Internal rendered block cache for stable chat content
	last_render_highlight_signature = nil,
	render_highlights_dirty_start = nil,
	force_full_render = false, -- Next render must replace the whole chat buffer
	session_stack = {},     -- Stack of { id, name } for parent session navigation
	last_render_time = 0,
	render_scheduled = false,
	render_in_progress = false,
	render_generation = 0,
	applied_render_generation = 0,
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
M.chat_anim_ns = vim.api.nvim_create_namespace("opencode_chat_anim")

-- A detail page may temporarily occupy the chat window while the transcript
-- continues receiving updates in its own buffer.
function M.is_chat_buffer_displayed(view)
	local state = view or M.state
	return state.bufnr ~= nil and state.winid ~= nil
		and vim.api.nvim_win_is_valid(state.winid)
		and vim.api.nvim_win_get_buf(state.winid) == state.bufnr
end

local defaults = vim.deepcopy(M.state)
M.state.id, M.state.generation = 1, 0
local views = { [1] = M.state }
local next_id, focused = 1, M.state
M.workspace = {}

function M.new()
	next_id = next_id + 1
	local view = vim.deepcopy(defaults)
	view.id, view.generation, view.session_bound = next_id, 0, true
	views[view.id] = view
	return view
end

function M.all()
	local result = {}
	for _, view in pairs(views) do result[#result + 1] = view end
	table.sort(result, function(a, b) return (a.id or 1) < (b.id or 1) end)
	return result
end

function M.get(id) return views[id] end

function M.for_window(win)
	local buf = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win)
	for _, view in pairs(views) do
		if view.winid == win then return view end
	end
	for _, view in pairs(views) do
		if view.session_bound and view.config and view.config.layout == "tab" and buf and view.bufnr == buf then return view end
	end
end

function M.windows(view)
	local result = {}
	if not view.bufnr then return result end
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == view.bufnr then result[#result + 1] = win end
	end
	return result
end

function M.current()
	return M.for_window(vim.api.nvim_get_current_win()) or focused
end

function M.activate(view)
	focused = view
	if view.config and view.config.layout == "tab" then M.workspace.last_view = view end
	local workspace = package.loaded["opencode.ui.chat.workspace"]
	if workspace then
		for _, layout in ipairs(workspace.list()) do
			if layout.id == view.workspace_id then layout.last_view = view end
		end
	end
end

function M.valid(view, generation)
	return view ~= nil and (view == M.state or views[view.id] == view)
		and (generation == nil or view.generation == generation)
end

function M.remove(view)
	view.generation = (view.generation or 0) + 1
	if view ~= M.state then views[view.id] = nil end
	if focused == view then
		focused = M.state
		for _, other in ipairs(M.all()) do
			if other ~= view and other.visible then focused = other; break end
		end
	end
end

function M.session(view)
	view = view or M.current()
	local app = require("opencode.state")
	if not view.session_bound then return app.get_session() end
	return app.get_session_record(view.session_id) or { id = view.session_id, name = view.session_name }
end

function M.for_session(id)
	if not id then return end
	for _, view in ipairs(M.all()) do
		if (view.visible or view.suspended) and (M.session(view).id == id or (view.session_stack[1] or {}).id == id) then return view end
	end
end

-- Each instance captures its owner; asynchronous work never swaps shared state.
function M.factory(name, build)
	local default = build(M.state)
	function default.for_view(view)
		if not view or view == M.state then return default end
		view.modules = view.modules or {}
		if not view.modules[name] then view.modules[name] = build(view) end
		return view.modules[name]
	end
	return default
end

function M.module(view, mod)
	return type(mod.for_view) == "function" and mod.for_view(view) or mod
end

return M
