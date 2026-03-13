local M = {}

M.SEPARATOR_WIDTH = 60
M.HEADER_WIDTH = 50

---@param icon string
---@param title string
---@param id_short string
---@param timestamp number|nil
---@param opts? table
---@return string
function M.format_header(icon, title, id_short, timestamp, opts)
	opts = opts or {}

	local left = string.format("%s %s [%s]", icon, title, id_short)
	local time_str = os.date("%H:%M", timestamp or os.time())
	local right = time_str
	local suffix = opts.suffix

	if type(suffix) == "string" and suffix ~= "" then
		right = string.format("%s  %s", time_str, suffix)
	end

	local width = opts.width or M.HEADER_WIDTH
	local left_width = vim.fn.strdisplaywidth(left)
	local right_width = vim.fn.strdisplaywidth(right)
	local padding = string.rep(" ", math.max(1, width - left_width - right_width))
	return left .. padding .. right
end

---@param width? number
---@return string
function M.separator(width)
	return string.rep("─", width or M.SEPARATOR_WIDTH)
end

---@param highlights table
---@param line number
---@param text string
---@param hl_group string
function M.add_full_line_highlight(highlights, line, text, hl_group)
	table.insert(highlights, {
		line = line,
		col_start = 0,
		col_end = #text,
		hl_group = hl_group,
	})
end

return M
