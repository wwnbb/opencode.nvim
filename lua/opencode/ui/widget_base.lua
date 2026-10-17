local M = {}

-- Legacy formatting exports remain available to user configuration.
M.SEPARATOR_WIDTH = 60
M.HEADER_WIDTH = 50

---@class OpenCodeWidgetMeta
---@field interactive_count number
---@field first_interactive_line number|nil
---@field auto_focus boolean
---@field option_lines table<number, number>|nil
---@field option_end_lines table<number, number>|nil
---@field file_ranges table[]|nil

---@param icon string
---@param title string
---@param id_label string
---@param timestamp number|nil
---@param opts? table
---@return string
function M.format_header(icon, title, id_label, timestamp, opts)
	opts = opts or {}
	local left = string.format("%s %s [%s]", icon, title, id_label)
	local right = os.date("%H:%M", timestamp or os.time())
	if type(opts.suffix) == "string" and opts.suffix ~= "" then right = right .. "  " .. opts.suffix end
	local padding = math.max(1, (opts.width or M.HEADER_WIDTH) - vim.fn.strdisplaywidth(left) - vim.fn.strdisplaywidth(right))
	return left .. string.rep(" ", padding) .. right
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
	highlights[#highlights + 1] = { line = line, col_start = 0, col_end = #text, hl_group = hl_group }
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

	local meta = {
		interactive_count = interactive_count,
		first_interactive_line = first_interactive_line,
		auto_focus = auto_focus,
	}

	for key, value in pairs(opts) do
		if meta[key] == nil then
			meta[key] = value
		end
	end

	return meta
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

-- Wrapped choices occupy all of their rendered rows; footers are not choices.
function M.get_option_index(meta, line)
	if not meta then return nil end
	if meta.option_lines then
		for index, first in pairs(meta.option_lines) do
			local last = (meta.option_end_lines or {})[index] or first
			if line >= first and line <= last then return index end
		end
		return nil
	end
	local count = meta.option_count or meta.interactive_count or 0
	local first = meta.first_interactive_line
	if first and line >= first and line < first + count then return line - first + 1 end
end

return M
