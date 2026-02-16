-- opencode.nvim - Chat message components using nui Lines
-- Provides component-based rendering for chat messages with NuiLine/NuiText

local M = {}

local NuiLine = require("nui.line")
local NuiText = require("nui.text")
local markdown = require("opencode.ui.markdown")
local thinking = require("opencode.ui.thinking")

--==============================================================================
-- ChatMessage: Renders a single chat message using NuiLine/NuiText
--==============================================================================

local ChatMessage = {}
ChatMessage.__index = ChatMessage

---Create a new ChatMessage component
---@param opts table
---@return ChatMessage
function ChatMessage.new(opts)
	local self = setmetatable({}, ChatMessage)
	self.id = opts.id
	self.role = opts.role
	self.content = opts.content
	self.reasoning = opts.reasoning
	self.tool_parts = opts.tool_parts or {}
	self.timestamp = opts.timestamp
	self.complete = opts.complete ~= false
	self._lines = {} -- NuiLine[]
	self._line_count = 0
	self:_build_lines()
	return self
end

---Update message content and rebuild lines
---@param opts table
function ChatMessage:update(opts)
	if opts.content ~= nil then
		self.content = opts.content
	end
	if opts.reasoning ~= nil then
		self.reasoning = opts.reasoning
	end
	if opts.tool_parts ~= nil then
		self.tool_parts = opts.tool_parts
	end
	if opts.complete ~= nil then
		self.complete = opts.complete
	end
	self:_build_lines()
end

---Get the number of lines this message renders to
---@return number
function ChatMessage:line_count()
	return self._line_count
end

---Get raw content lines (for buffer insertion)
---@return string[]
function ChatMessage:get_content_lines()
	local lines = {}
	for _, nui_line in ipairs(self._lines) do
		table.insert(lines, nui_line:content())
	end
	return lines
end

---Re-render this component in place (for incremental updates)
---@param bufnr number
---@param ns_id number
---@param start_line number 0-indexed
function ChatMessage:rerender(bufnr, ns_id, start_line)
	if start_line < 0 then
		return
	end

	-- Clear existing highlights for this component
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line, start_line + self._line_count)

	-- Replace line content
	local content_lines = self:get_content_lines()
	vim.api.nvim_buf_set_lines(bufnr, start_line, start_line + self._line_count, false, content_lines)

	-- Apply highlights
	for i, nui_line in ipairs(self._lines) do
		nui_line:highlight(bufnr, ns_id, start_line + i - 1)
	end
end

---Build all NuiLine objects for this message
function ChatMessage:_build_lines()
	local lines = {}

	if self.role == "user" then
		self:_build_user_message(lines)
	else
		self:_build_assistant_message(lines)
	end

	self._lines = lines
	self._line_count = #lines
end

---Build user message with bordered box style
---@param lines NuiLine[]
function ChatMessage:_build_user_message(lines)
	local content = self.content or ""
	local content_lines = vim.split(content, "\n", { plain = true })

	-- Top border line with highlight bar
	local top_line = NuiLine()
	top_line:append(NuiText("│", "Special"))
	table.insert(lines, top_line)

	-- Content lines with border prefix
	for _, line in ipairs(content_lines) do
		local content_line = NuiLine()
		content_line:append(NuiText("│ ", "Special"))
		content_line:append(line)
		table.insert(lines, content_line)
	end

	-- Bottom border line
	local bottom_line = NuiLine()
	bottom_line:append(NuiText("│", "Special"))
	table.insert(lines, bottom_line)

	-- Empty separator
	table.insert(lines, NuiLine())
end

---Build assistant message with reasoning, tools, and content
---@param lines NuiLine[]
function ChatMessage:_build_assistant_message(lines)
	local has_reasoning = self.reasoning and self.reasoning ~= ""
	local has_tools = #self.tool_parts > 0
	local has_content = self.content and self.content ~= ""

	-- Render reasoning/thinking
	if has_reasoning and thinking.is_enabled() then
		local reasoning_lines = vim.split(self.reasoning, "\n", { plain = true })
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
		table.insert(lines, NuiLine())
	end

	-- Render tool calls
	if has_tools then
		for _, tool_part in ipairs(self.tool_parts) do
			self:_build_tool_line(lines, tool_part)
		end
	end

	-- Render content
	if has_content then
		self:_build_content_lines(lines)
	end

	-- Empty separator
	if #lines > 0 and lines[#lines]:content() ~= "" then
		table.insert(lines, NuiLine())
	end
end

---Build a single tool call line
---@param lines NuiLine[]
---@param tool_part table
function ChatMessage:_build_tool_line(lines, tool_part)
	local tool_name = tool_part.tool or "unknown"
	local tool_status = tool_part.state and tool_part.state.status or "pending"

	local status_symbol = "○"
	local hl_group = "Comment"
	if tool_status == "completed" then
		status_symbol = "●"
		hl_group = "Normal"
	elseif tool_status == "running" then
		status_symbol = "◐"
		hl_group = "WarningMsg"
	elseif tool_status == "error" then
		status_symbol = "✗"
		hl_group = "ErrorMsg"
	end

	local tool_line = NuiLine()
	tool_line:append(NuiText(status_symbol .. " ", hl_group))
	tool_line:append(NuiText(tool_name, "Function"))

	if tool_part.input and tool_part.input.description then
		tool_line:append(NuiText(" - " .. tool_part.input.description, "Comment"))
	end

	table.insert(lines, tool_line)
end

---Build content lines with markdown support
---@param lines NuiLine[]
function ChatMessage:_build_content_lines(lines)
	local content = self.content
	local use_markdown = markdown.has_markdown(content)

	if use_markdown then
		local parsed = markdown.parse(content)
		local md_lines, md_highlights = markdown.render_to_lines(parsed)

		for i, text in ipairs(md_lines) do
			local line = NuiLine()
			line:append(text)
			table.insert(lines, line)
		end
	else
		-- Plain text
		local content_lines = vim.split(content, "\n", { plain = true })
		for _, text in ipairs(content_lines) do
			local line = NuiLine()
			line:append(text)
			table.insert(lines, line)
		end
	end
end

--==============================================================================
-- MessageManager: Manages all chat message components
--==============================================================================

local MessageManager = {
	messages = {}, -- ChatMessage[] indexed by message id
	message_order = {}, -- Ordered list of message ids
	line_map = {}, -- message_id -> start_line (0-indexed)
	ns_id = nil,
	bufnr = nil,
}

---Initialize MessageManager
---@param bufnr number
---@param ns_id number
function MessageManager.init(bufnr, ns_id)
	MessageManager.bufnr = bufnr
	MessageManager.ns_id = ns_id
	MessageManager.messages = {}
	MessageManager.message_order = {}
	MessageManager.line_map = {}
end

---Add or update a message component
---@param message_data table
---@return string "added" | "updated" | "full_refresh"
function MessageManager.upsert_message(message_data)
	local id = message_data.id
	local existing = MessageManager.messages[id]

	if existing then
		-- Check if line count changed
		local old_count = existing:line_count()
		existing:update(message_data)
		local new_count = existing:line_count()

		if old_count == new_count then
			-- Incremental update possible
			local start_line = MessageManager.line_map[id]
			existing:rerender(MessageManager.bufnr, MessageManager.ns_id, start_line)
			MessageManager._refresh_line_map()
			return "updated"
		else
			-- Line count changed, need full refresh
			return "full_refresh"
		end
	else
		-- New message
		local msg = ChatMessage.new(message_data)
		MessageManager.messages[id] = msg
		table.insert(MessageManager.message_order, id)
		MessageManager._refresh_line_map()
		return "added"
	end
end

---Remove a message by id
---@param id string
function MessageManager.remove_message(id)
	if not MessageManager.messages[id] then
		return
	end

	MessageManager.messages[id] = nil
	for i, msg_id in ipairs(MessageManager.message_order) do
		if msg_id == id then
			table.remove(MessageManager.message_order, i)
			break
		end
	end
	MessageManager._refresh_line_map()
end

---Get message position in buffer
---@param id string
---@return number|nil start_line 0-indexed, or nil if not found
function MessageManager.get_message_position(id)
	return MessageManager.line_map[id]
end

---Get message by id
---@param id string
---@return ChatMessage|nil
function MessageManager.get_message(id)
	return MessageManager.messages[id]
end

---Refresh the line map for all messages
function MessageManager._refresh_line_map()
	MessageManager.line_map = {}
	local current_line = 0

	for _, id in ipairs(MessageManager.message_order) do
		local msg = MessageManager.messages[id]
		if msg then
			MessageManager.line_map[id] = current_line
			current_line = current_line + msg:line_count()
		end
	end
end

---Get total line count
---@return number
function MessageManager.total_lines()
	local total = 0
	for _, msg in pairs(MessageManager.messages) do
		total = total + msg:line_count()
	end
	return total
end

---Render all messages to buffer (full refresh)
function MessageManager.render_all()
	if not MessageManager.bufnr or not vim.api.nvim_buf_is_valid(MessageManager.bufnr) then
		return
	end

	-- Collect all lines
	local all_lines = {}
	for _, id in ipairs(MessageManager.message_order) do
		local msg = MessageManager.messages[id]
		if msg then
			vim.list_extend(all_lines, msg:get_content_lines())
		end
	end

	-- Clear buffer and set lines
	vim.api.nvim_buf_set_lines(MessageManager.bufnr, 0, -1, false, all_lines)

	-- Clear namespace and apply highlights
	if MessageManager.ns_id then
		vim.api.nvim_buf_clear_namespace(MessageManager.bufnr, MessageManager.ns_id, 0, -1)
	end

	local line_num = 0
	for _, id in ipairs(MessageManager.message_order) do
		local msg = MessageManager.messages[id]
		if msg then
			for _, nui_line in ipairs(msg._lines) do
				nui_line:highlight(MessageManager.bufnr, MessageManager.ns_id, line_num)
				line_num = line_num + 1
			end
		end
	end

	MessageManager._refresh_line_map()
end

---Get all messages in order
---@return ChatMessage[]
function MessageManager.get_all_messages()
	local result = {}
	for _, id in ipairs(MessageManager.message_order) do
		local msg = MessageManager.messages[id]
		if msg then
			table.insert(result, msg)
		end
	end
	return result
end

---Clear all messages
function MessageManager.clear()
	MessageManager.messages = {}
	MessageManager.message_order = {}
	MessageManager.line_map = {}
end

--==============================================================================
-- Public API
--==============================================================================

M.ChatMessage = ChatMessage
M.MessageManager = MessageManager

return M
