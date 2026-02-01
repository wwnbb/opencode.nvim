-- opencode.nvim - Tool calls display module
-- Display tool calls with collapsible cards

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

-- Tool call types and their icons
local tool_icons = {
	read_file = "📄",
	edit_file = "✏️ ",
	bash = "$",
	search = "🔍",
	list_dir = "📁",
	delete = "🗑️ ",
	create = "🆕",
	move = "📦",
	copy = "📋",
	web_search = "🌐",
	mcp = "🔧",
	default = "🔧",
}

-- Tool call statuses
local status_icons = {
	pending = "⏳",
	running = "▶️ ",
	success = "✓",
	error = "✗",
	cancelled = "⛔",
}

-- Tool call state management
local tool_state = {
	calls = {},
	expanded = {},
	ns_id = nil,
}

-- Get or create namespace for highlights
local function get_namespace()
	if not tool_state.ns_id then
		tool_state.ns_id = vim.api.nvim_create_namespace("opencode_tools")
	end
	return tool_state.ns_id
end

-- Parse tool call from message content
function M.parse_tool_call(content)
	-- Match tool calls in format: ToolCall: <name>(<args>) or similar patterns
	local tools = {}

	-- Pattern 1: ToolCall: name(args)
	for tool_name, args in content:gmatch("ToolCall:%s*(%w+)%s*%(([^)]+)%)%s*") do
		table.insert(tools, {
			name = tool_name,
			args = args,
			status = "pending",
			timestamp = os.time(),
		})
	end

	-- Pattern 2: Markdown code block with tool-call class
	for tool_json in content:gmatch("```tool%-call\n(.-)\n```") do
		local ok, tool_data = pcall(vim.json.decode, tool_json)
		if ok and type(tool_data) == "table" then
			table.insert(tools, {
				name = tool_data.name or tool_data.tool or "unknown",
				args = tool_data.args or tool_data.arguments or vim.json.encode(tool_data),
				status = tool_data.status or "pending",
				result = tool_data.result,
				timestamp = os.time(),
			})
		end
	end

	-- Pattern 3: Inline tool call indicators
	for tool_call in content:gmatch("<tool%-call>(.-)</tool%-call>") do
		local ok, tool_data = pcall(vim.json.decode, tool_call)
		if ok and type(tool_data) == "table" then
			table.insert(tools, {
				name = tool_data.name or "unknown",
				args = vim.json.encode(tool_data.args or {}),
				status = tool_data.status or "pending",
				result = tool_data.result,
				timestamp = os.time(),
			})
		end
	end

	return tools
end

-- Check if message contains tool calls
function M.has_tool_calls(content)
	local tools = M.parse_tool_call(content)
	return #tools > 0, tools
end

-- Format tool call for display
function M.format_tool_call(tool, index, expanded)
	local icon = tool_icons[tool.name] or tool_icons.default
	local status = status_icons[tool.status] or status_icons.pending
	local lines = {}
	local highlights = {}

	-- Header line
	local header = string.format("  %s %s %s", status, icon, tool.name)
	table.insert(lines, header)

	-- Status color
	local status_hl = "Comment"
	if tool.status == "success" then
		status_hl = "DiffAdd"
	elseif tool.status == "error" then
		status_hl = "DiffDelete"
	elseif tool.status == "running" then
		status_hl = "Search"
	end

	table.insert(highlights, {
		line = #lines - 1,
		col_start = 2,
		col_end = 5,
		hl_group = status_hl,
	})

	-- Tool name highlight
	table.insert(highlights, {
		line = #lines - 1,
		col_start = 6,
		col_end = 8,
		hl_group = "Special",
	})

	table.insert(highlights, {
		line = #lines - 1,
		col_start = 8,
		col_end = 8 + #tool.name,
		hl_group = "Function",
	})

	-- Expand/collapse indicator
	if expanded then
		table.insert(lines, "  ▼ Arguments:")
	else
		table.insert(lines, "  ▶ Arguments (press Enter to expand)")
	end

	if expanded then
		-- Arguments
		local args_lines = vim.split(tool.args, "\n", { plain = true })
		for _, arg_line in ipairs(args_lines) do
			table.insert(lines, "    " .. arg_line)
		end

		-- Result if available
		if tool.result then
			table.insert(lines, "")
			table.insert(lines, "  ▼ Result:")
			local result_lines = vim.split(vim.inspect(tool.result), "\n", { plain = true })
			for _, res_line in ipairs(result_lines) do
				table.insert(lines, "    " .. res_line)
			end
		end

		-- Actions hint
		table.insert(lines, "")
		table.insert(lines, "  [gd] Go to file  [gD] View diff")
	end

	table.insert(lines, "") -- Spacing

	return lines, highlights, index
end

-- Render tool calls section
function M.render_tool_calls(tools, start_line)
	local lines = {}
	local highlights = {}
	local tool_indices = {}

	if #tools == 0 then
		return lines, highlights, tool_indices
	end

	-- Section header
	table.insert(lines, " Tool Calls:")
	table.insert(highlights, {
		line = start_line,
		col_start = 0,
		col_end = 12,
		hl_group = "Title",
	})
	table.insert(lines, "")

	local current_line = start_line + 2

	for i, tool in ipairs(tools) do
		local expanded = tool_state.expanded[i] or false
		local tool_lines, tool_highlights = M.format_tool_call(tool, i, expanded)

		-- Store tool index mapping
		tool_indices[current_line] = i

		-- Add lines
		for _, line in ipairs(tool_lines) do
			table.insert(lines, line)
		end

		-- Adjust and add highlights
		for _, hl in ipairs(tool_highlights) do
			table.insert(highlights, {
				line = current_line + hl.line,
				col_start = hl.col_start,
				col_end = hl.col_end,
				hl_group = hl.hl_group,
			})
		end

		current_line = current_line + #tool_lines
	end

	return lines, highlights, tool_indices
end

-- Update tool call status
function M.update_tool_status(tool_index, status, result)
	if tool_state.calls[tool_index] then
		tool_state.calls[tool_index].status = status
		if result then
			tool_state.calls[tool_index].result = result
		end
	end
end

-- Toggle tool call expansion
function M.toggle_expansion(line_number, tool_indices)
	local tool_index = tool_indices[line_number]
	if tool_index then
		tool_state.expanded[tool_index] = not tool_state.expanded[tool_index]
		return true
	end
	return false
end

-- Get tool action for a line
function M.get_tool_action(line_number, tool_indices, tools)
	local tool_index = tool_indices[line_number]
	if not tool_index or not tools[tool_index] then
		return nil
	end

	local tool = tools[tool_index]

	-- Determine action based on tool type and context
	if tool.name == "read_file" or tool.name == "edit_file" then
		-- Extract file path from args
		local file_path = tool.args:match('"([^"]+)"') or tool.args:match("'([^']+)'") or tool.args:match("(%S+)")
		if file_path then
			return {
				type = "goto_file",
				file_path = file_path,
			}
		end
	elseif tool.name == "edit_file" and tool.result then
		return {
			type = "view_diff",
			tool = tool,
		}
	end

	return nil
end

-- Setup tool call keymaps for buffer
function M.setup_keymaps(bufnr, tools, tool_indices)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	-- Toggle expansion on Enter
	vim.keymap.set("n", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local line = cursor[1] - 1 -- 0-indexed

		if M.toggle_expansion(line, tool_indices) then
			-- Trigger re-render
			vim.api.nvim_exec_autocmds("User", { pattern = "OpenCodeToolToggle" })
		end
	end, opts)

	-- Go to file
	vim.keymap.set("n", "gd", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local line = cursor[1] - 1

		local action = M.get_tool_action(line, tool_indices, tools)
		if action and action.type == "goto_file" then
			-- Close chat or keep it open based on preference
			vim.cmd("edit " .. vim.fn.fnameescape(action.file_path))
		end
	end, opts)

	-- View diff
	vim.keymap.set("n", "gD", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local line = cursor[1] - 1

		local action = M.get_tool_action(line, tool_indices, tools)
		if action and action.type == "view_diff" then
			-- Trigger diff view event
			vim.api.nvim_exec_autocmds("User", {
				pattern = "OpenCodeViewDiff",
				data = action.tool,
			})
		end
	end, opts)
end

-- Clear tool state
function M.clear()
	tool_state.calls = {}
	tool_state.expanded = {}
end

-- Setup function
function M.setup(opts)
	if opts and opts.icons then
		tool_icons = vim.tbl_extend("force", tool_icons, opts.icons)
	end
	if opts and opts.status_icons then
		status_icons = vim.tbl_extend("force", status_icons, opts.status_icons)
	end
end

return M
