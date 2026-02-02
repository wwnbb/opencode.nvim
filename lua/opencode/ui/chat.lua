-- opencode.nvim - Chat buffer UI module
-- Main chat interface with configurable layouts

local M = {}

local Popup = require("nui.popup")
local Layout = require("nui.layout")
local event = require("nui.utils.autocmd").event
local input = require("opencode.ui.input")
local markdown = require("opencode.ui.markdown")
local tools = require("opencode.ui.tools")
local thinking = require("opencode.ui.thinking")

-- State
local state = {
	bufnr = nil,
	winid = nil,
	layout = nil,
	visible = false,
	messages = {},
	config = nil,
}

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

	-- Help
	vim.keymap.set("n", "?", function()
		M.show_help()
	end, opts)
end

-- Create chat buffer
local function create_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)
	setup_buffer(bufnr)
	return bufnr
end

	-- Show help popup
function M.show_help()
	local lines = {
		" Chat Buffer Keymaps ",
		"",
		" q          - Close chat",
		" i          - Focus input",
		" <C-u>      - Scroll up",
		" <C-d>      - Scroll down",
		" gg         - Go to top",
		" G          - Go to bottom",
		" ?          - Show this help",
		"",
		" Input Mode:",
		" <C-g>      - Send message",
		" <Esc>      - Cancel",
		" ↑/↓        - Navigate history",
		" <C-s>      - Stash input",
		" <C-r>      - Restore input",
		"",
		" Tool Calls:",
		" <CR>       - Toggle details",
		" gd         - Go to file",
		" gD         - View diff",
		"",
		" Press any key to close",
	}

	local width = 40
	local height = #lines
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

	local popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " Help ",
				top_align = "center",
			},
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
	})

	popup:mount()
	vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
	vim.bo[popup.bufnr].modifiable = false

	-- Close on various keys
	local close_keys = { "q", "<Esc>", "<CR>", "<Space>" }
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, function()
			popup:unmount()
		end, { buffer = popup.bufnr, noremap = true, silent = true })
	end

	-- Close on any alphanumeric key
	for i = 32, 126 do -- printable ASCII characters
		local char = string.char(i)
		if not char:match("[qQ]") then -- Skip 'q' as it's already mapped
			local ok, _ = pcall(function()
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

	-- Render initial content
	M.render()

	return state.bufnr
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
	end

	state.visible = true

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
	if message.role == "assistant" and 
	   (not message.content or message.content == "") and 
	   (not message.reasoning or message.reasoning == "") then
		return
	end

	-- Message header with ID for debugging
	local role_display = message.role == "user" and "You" or (message.role == "assistant" and "Assistant" or "System")
	local time_str = os.date("%H:%M", message.timestamp)
	local id_short = message.id and message.id:sub(1, 6) or "??????"
	local header_text = string.format("%s [%s] %s%s", role_display, id_short, string.rep(" ", 50 - #role_display - #time_str - #id_short - 3), time_str)
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
		vim.api.nvim_buf_add_highlight(state.bufnr, -1, hl.hl_group, line_count + hl.line, hl.col_start, hl.col_end)
	end

	vim.bo[state.bufnr].modifiable = false

	-- Auto-scroll if at bottom
	if state.visible and state.winid then
		local cursor = vim.api.nvim_win_get_cursor(state.winid)
		local win_height = vim.api.nvim_win_get_height(state.winid)
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)

		-- Only scroll if user is already at bottom
		if cursor[1] >= buf_lines - win_height - 1 then
			vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
		end
	end
end

-- Clear all messages
function M.clear()
	state.messages = {}
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
		M.render()
		vim.bo[state.bufnr].modifiable = false
	end
end

-- Get all messages
function M.get_messages()
	return vim.deepcopy(state.messages)
end

-- Render full buffer content (for initial load)
function M.render()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local lines = {}
	local highlights = {}

	-- Header
	table.insert(lines, " OpenCode Chat ")
	table.insert(highlights, { line = 0, col_start = 0, col_end = 15, hl_group = "Title" })
	table.insert(lines, string.rep("═", 60))
	table.insert(lines, "")

	-- Render all messages
	for _, message in ipairs(state.messages) do
		local role_display = message.role == "user" and "You" or (message.role == "assistant" and "Assistant" or "System")
		local time_str = os.date("%H:%M", message.timestamp)
		local id_short = message.id and message.id:sub(1, 6) or "??????"

		-- Skip empty assistant messages (no content and no reasoning)
		local has_content = message.content and message.content ~= ""
		local has_reasoning = message.reasoning and message.reasoning ~= ""
		local should_render = message.role ~= "assistant" or has_content or has_reasoning

		if should_render then
			local header_text = string.format("%s [%s] %s%s", role_display, id_short, string.rep(" ", 50 - #role_display - #time_str - #id_short - 3), time_str)
			table.insert(lines, header_text)
			table.insert(highlights, {
				line = #lines - 1,
				col_start = 0,
				col_end = #role_display,
				hl_group = message.role == "user" and "Identifier" or "Constant",
			})

			table.insert(lines, string.rep("─", 60))

			-- Render reasoning/thinking content if available
			if message.reasoning and message.reasoning ~= "" and thinking.is_enabled() then
				local reasoning_lines = thinking.format_reasoning(message.reasoning)
				local reasoning_start = #lines

				for _, line in ipairs(reasoning_lines) do
					table.insert(lines, line)
				end

				-- Schedule highlight application
				vim.schedule(function()
					if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
						thinking.apply_highlights(state.bufnr, reasoning_start, #reasoning_lines)
					end
				end)
			end

			-- Message content with markdown rendering
			local use_markdown = markdown.has_markdown(message.content)
			local content_start = #lines
			if use_markdown then
				local md_lines, md_highlights = markdown.render_to_lines(markdown.parse(message.content))
				for _, line in ipairs(md_lines) do
					table.insert(lines, line)
				end
				for _, hl in ipairs(md_highlights) do
					hl.line = content_start + hl.line
					table.insert(highlights, hl)
				end
			else
				-- Plain text
				local content_lines = vim.split(message.content, "\n", { plain = true })
				for _, line in ipairs(content_lines) do
					table.insert(lines, line)
				end
			end

			table.insert(lines, "")
		end
	end

	-- Initial state message
	if #state.messages == 0 then
		table.insert(lines, " Welcome to OpenCode!")
		table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = 22, hl_group = "Comment" })
		table.insert(lines, "")
		table.insert(lines, " Press 'i' to start typing or '?' for help.")
		table.insert(highlights, { line = #lines - 1, col_start = 0, col_end = 42, hl_group = "Comment" })
		table.insert(lines, "")
	end

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)

	-- Apply highlights
	for _, hl in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(state.bufnr, -1, hl.hl_group, hl.line, hl.col_start, hl.col_end)
	end

	vim.bo[state.bufnr].modifiable = false
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
	for _, msg in ipairs(state.messages) do
		if msg.id == message_id and msg.tool_calls and msg.tool_calls[tool_index] then
			msg.tool_calls[tool_index].status = status
			if result then
				msg.tool_calls[tool_index].result = result
			end
			-- Re-render the message
			-- Clear from buffer and re-render
			if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
				vim.bo[state.bufnr].modifiable = true
				vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
				M.render()
				vim.bo[state.bufnr].modifiable = false
			end
			return true
		end
	end
	return false
end

-- Track streaming assistant message
local streaming_message = {
	id = nil,
	content = "",
	line_start = nil, -- Line where this message starts in buffer
}

-- Update or create an assistant message (for streaming responses)
---@param message_id string Message ID from server
---@param content string Current content
function M.update_assistant_message(message_id, content)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	-- Check if this is a new message or update to existing
	if streaming_message.id ~= message_id then
		-- New message - add it
		streaming_message.id = message_id
		streaming_message.content = ""
		streaming_message.line_start = nil

		-- Find or create the message in our local state
		local found = false
		for _, msg in ipairs(state.messages) do
			if msg.id == message_id then
				found = true
				msg.content = content
				break
			end
		end

		if not found then
			-- Add new assistant message
			local message = {
				role = "assistant",
				content = content,
				timestamp = os.time(),
				id = message_id,
			}
			table.insert(state.messages, message)
		end

		-- Remember where this message starts
		streaming_message.line_start = vim.api.nvim_buf_line_count(state.bufnr)
	end

	-- Update the content
	streaming_message.content = content

	-- Update the message in state
	for _, msg in ipairs(state.messages) do
		if msg.id == message_id then
			msg.content = content
			break
		end
	end

	-- Re-render the buffer
	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
	M.render()
	vim.bo[state.bufnr].modifiable = false

	-- Auto-scroll to bottom if visible
	if state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
	end
end

-- Update reasoning content for a message (handles streaming reasoning parts)
---@param message_id string Message ID
---@param reasoning_text string Current reasoning content
function M.update_reasoning(message_id, reasoning_text)
	if not thinking.is_enabled() then
		return
	end

	-- Store reasoning in the thinking module
	thinking.store_reasoning(message_id, reasoning_text)

	-- Update the message in state
	for _, msg in ipairs(state.messages) do
		if msg.id == message_id then
			msg.reasoning = reasoning_text
			break
		end
	end

	-- Throttle UI updates to avoid excessive re-rendering
	if not thinking.should_update() then
		return
	end

	-- Re-render the buffer to show updated reasoning
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		vim.bo[state.bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, {})
		M.render()
		vim.bo[state.bufnr].modifiable = false

		-- Auto-scroll to bottom if visible
		if state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
			local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
			vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
		end
	end
end

-- Clear streaming state (called when message is complete)
function M.clear_streaming_state()
	streaming_message.id = nil
	streaming_message.content = ""
	streaming_message.line_start = nil
end

return M
