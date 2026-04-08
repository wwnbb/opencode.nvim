local M = {}

M.SEPARATOR_WIDTH = 60
M.HEADER_WIDTH = 50

---@class OpenCodeWidgetMeta
---@field interactive_count number
---@field first_interactive_line number|nil
---@field auto_focus boolean

---@param icon string
---@param title string
---@param id_label string
---@param timestamp number|nil
---@param opts? table
---@return string
function M.format_header(icon, title, id_label, timestamp, opts)
	opts = opts or {}

	local left = string.format("%s %s [%s]", icon, title, id_label)
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

---@param opts? table
---@return OpenCodeWidgetMeta
function M.make_meta(opts)
	opts = opts or {}

	local interactive_count = opts.interactive_count or 0
	local first_interactive_line = type(opts.first_interactive_line) == "number" and opts.first_interactive_line or nil
	local auto_focus = opts.auto_focus ~= false

	if interactive_count <= 0 then
		first_interactive_line = nil
	end

	return {
		interactive_count = interactive_count,
		first_interactive_line = first_interactive_line,
		auto_focus = auto_focus,
	}
end

---@param meta OpenCodeWidgetMeta|nil
---@return number|nil
function M.get_focus_offset(meta)
	if not meta or meta.auto_focus == false then
		return nil
	end

	if (meta.interactive_count or 0) <= 0 then
		return nil
	end

	if type(meta.first_interactive_line) ~= "number" then
		return nil
	end

	return meta.first_interactive_line
end

return M
