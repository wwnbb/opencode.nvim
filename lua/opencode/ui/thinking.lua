-- opencode.nvim - Thinking/Reasoning display module
-- Handles real-time display of model reasoning/thinking content

local M = {}

local hl_ns = vim.api.nvim_create_namespace("opencode_thinking")
local app_state = require("opencode.state")
local config_module = require("opencode.config")

-- State storage for reasoning content per message
local reasoning_store = {}

-- Throttling
local last_update = 0

-- Read merged app state with defaults for callers that render before setup.
local function get_config()
	local defaults = config_module.defaults.thinking or {}
	local active_config = app_state.get_config() or {}
	local configured = type(active_config.thinking) == "table" and active_config.thinking or {}
	return vim.tbl_deep_extend("force", vim.deepcopy(defaults), configured)
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
	return match and vim.trim(match) or nil
end

-- Format reasoning text for display
function M.format_reasoning(text, opts)
	opts = opts or {}
	local config = get_config()
	local max_lines = tonumber(opts.max_height or config.max_height) or 15
	max_lines = math.max(0, math.floor(max_lines))

	if config.enabled == false or not text or text == "" then
		return {}
	end

	local lines = {}
	local icon = config.icon or "💭"

	-- Add header with icon and optional topic
	local topic = M.extract_topic(text)
	local header
	if topic then
		header = string.format("%s %s", icon, topic)
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
function M.get_highlights(start_line, line_count)
	local config = get_config()
	local highlights = {}
	start_line = tonumber(start_line) or 0

	-- Header highlight
	table.insert(highlights, {
		line = start_line,
		col_start = 0,
		col_end = -1, -- Full line
		hl_group = config.header_highlight or "Title",
	})

	-- The formatter always emits a header, separator, content, and separator.
	-- Accepting the line count keeps this useful to both buffer and NuiLine
	-- renderers without duplicating the layout rules.
	if type(line_count) == "number" then
		for offset = 2, line_count - 2 do
			table.insert(highlights, {
				line = start_line + offset,
				col_start = 0,
				col_end = -1,
				hl_group = config.highlight or "Comment",
			})
		end
	end

	return highlights
end

-- Apply highlights to reasoning content in buffer
function M.apply_highlights(bufnr, start_line, line_count)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	for _, highlight in ipairs(M.get_highlights(start_line, line_count)) do
		local line_num = highlight.line
		local line_text = vim.api.nvim_buf_get_lines(bufnr, line_num, line_num + 1, false)[1] or ""
		vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_num, highlight.col_start or 0, {
			end_col = highlight.col_end == -1 and #line_text or highlight.col_end,
			hl_group = highlight.hl_group,
		})
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

return M
