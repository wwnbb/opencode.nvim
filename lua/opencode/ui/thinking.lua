-- opencode.nvim - Thinking/Reasoning display module
-- Handles real-time display of model reasoning/thinking content

local M = {}

-- State storage for reasoning content per message
local reasoning_store = {}

-- Throttling
local last_update = 0

-- Get config from main config module
local function get_config()
	local config_module = require("opencode.config")
	return config_module.defaults.thinking or {}
end

-- Initialize (called on module load to sync with main config)
function M.setup()
	-- Config is now read dynamically from main config
	last_update = 0
end

-- Store reasoning content for a message
function M.store_reasoning(message_id, text)
	reasoning_store[message_id] = {
		text = text or "",
		last_updated = vim.uv.now(),
	}
end

-- Get reasoning content for a message
function M.get_reasoning(message_id)
	local data = reasoning_store[message_id]
	return data and data.text or ""
end

-- Clear reasoning for a message
function M.clear_reasoning(message_id)
	reasoning_store[message_id] = nil
end

-- Clear all reasoning data
function M.clear_all()
	reasoning_store = {}
end

-- Extract topic from reasoning text (e.g., "**Planning** ..." -> "Planning")
function M.extract_topic(text)
	if not text then
		return nil
	end
	local match = text:match("^%s*%*%*(.-)%*%*")
	return match and match:trim() or nil
end

-- Format reasoning text for display
function M.format_reasoning(text, opts)
	opts = opts or {}
	local config = get_config()
	local max_lines = opts.max_height or config.max_height or 15

	if not text or text == "" then
		return {}
	end

	local lines = {}
	local icon = config.icon or "💭"

	-- Add header with icon and optional topic
	local topic = M.extract_topic(text)
	local header
	if topic then
		header = string.format("%s Thinking: %s", icon, topic)
	else
		header = string.format("%s Thinking", icon)
	end
	table.insert(lines, header)

	-- Process reasoning text
	local content_lines = vim.split(text, "\n", { plain = true })

	-- Remove empty lines at start
	while #content_lines > 0 and content_lines[1]:match("^%s*$") do
		table.remove(content_lines, 1)
	end

	-- Remove topic line if it was at the beginning
	if topic and content_lines[1] and content_lines[1]:match("%*%*" .. vim.pesc(topic) .. "%*%*") then
		table.remove(content_lines, 1)
	end

	-- Add separator
	table.insert(lines, "─")

	-- Add content lines (with truncation if needed)
	local added = 0
	local should_truncate = config.truncate ~= false
	for _, line in ipairs(content_lines) do
		if added >= max_lines then
			if should_truncate then
				table.insert(lines, "...")
			end
			break
		end

		-- Trim the line and add indentation for visual distinction
		local trimmed = line:gsub("^%s+", ""):gsub("%s+$", "")
		if trimmed ~= "" or added > 0 then
			table.insert(lines, "  " .. trimmed)
			added = added + 1
		end
	end

	-- Add bottom separator
	table.insert(lines, "─")

	return lines
end

-- Get highlight configuration for rendering
function M.get_highlights(start_line)
	local highlights = {}

	-- Header highlight
	table.insert(highlights, {
		line = start_line,
		col_start = 0,
		col_end = -1, -- Full line
		hl_group = config.header_highlight,
	})

	-- Content highlights (apply Comment highlight to all content lines)
	-- Note: actual line count depends on formatted content
	-- This is handled by the caller after formatting

	return highlights
end

-- Apply highlights to reasoning content in buffer
function M.apply_highlights(bufnr, start_line, line_count)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local config = get_config()
	local header_hl = config.header_highlight or "Title"
	local content_hl = config.highlight or "Comment"

	-- Header line gets title highlight
	vim.api.nvim_buf_add_highlight(bufnr, -1, header_hl, start_line, 0, -1)

	-- Content lines get comment highlight
	for i = 1, line_count - 3 do -- Skip header, separator, and bottom separator
		local line_num = start_line + i + 1 -- +1 to skip header and first separator
		vim.api.nvim_buf_add_highlight(bufnr, -1, content_hl, line_num, 0, -1)
	end
end

-- Check if thinking display is enabled
function M.is_enabled()
	local config = get_config()
	return config.enabled ~= false
end

-- Get configuration
function M.get_config()
	return vim.deepcopy(get_config())
end

-- Throttled update check (disabled - always returns true for live updates)
function M.should_update()
	-- Throttling disabled for live updates
	return true
end

-- Reset throttle (useful for final updates)
function M.reset_throttle()
	last_update = 0
end

return M
