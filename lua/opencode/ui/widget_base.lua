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
---@field option_count number|nil Question widgets: options in the current question
---@field custom_interactive_line number|nil Question widgets: custom-answer row

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

-- ─── Shared panel builders for the interactive widgets ───────────────────────

---Empty render result carrying the renderer's width/render options.
---@param opts? table { width?: number, render?: table }
---@return table result
function M.new_result(opts)
	return { lines = {}, highlights = {}, width = opts and opts.width, render = opts and opts.render }
end

---Highlight for the selected-option marker: Special (or Title) on the cursor line.
---@param get_hl fun(name: string): table
---@return table attrs
function M.selected_marker_hl(get_hl)
	return {
		fg = get_hl("Special").fg or get_hl("Title").fg,
		bg = get_hl("CursorLine").bg,
		bold = true,
	}
end

---Append "<base>[ <title>][ <suffix>]" and highlight the title within it.
---@param helpers table Panel helpers (add_line, highlight_text)
---@param result table
---@param base string
---@param title string
---@param suffix string|nil
---@param hl_group string Header highlight for the widget status
---@param title_hl string
function M.add_status_header(helpers, result, base, title, suffix, hl_group, title_hl)
	local header = base
	if title ~= "" then
		header = header .. " " .. title
	end
	if suffix and suffix ~= "" then
		header = header .. " " .. suffix
	end

	local _, _, rows = helpers.add_line(result, header, hl_group)
	if title ~= "" then
		helpers.highlight_text(result, rows, title, title_hl)
	end
end

---Append numbered options ("<marker> <n>. <label>") and record their row ranges.
---@param result table
---@param labels string[]
---@param selected fun(index: integer): boolean
---@param marker fun(index: integer, is_selected: boolean): string
---@param style { add_raw_line: (fun(result: table, text: string, hl_group: string): any, any, table), highlight_text?: (fun(result: table, rows: table, text: string, hl_group: string)), selected_hl: string, option_hl: string, marker_hl?: string }
---@return table<integer, integer> option_lines First row of each option
---@return table<integer, integer> option_end_lines Last row of each option
function M.append_options(result, labels, selected, marker, style)
	local option_lines, option_end_lines = {}, {}
	for i, label in ipairs(labels) do
		local is_selected = selected(i)
		local option_marker = marker(i, is_selected)
		option_lines[i] = #result.lines
		local _, _, rows = style.add_raw_line(
			result,
			string.format("%s %d. %s", option_marker, i, label),
			is_selected and style.selected_hl or style.option_hl
		)
		option_end_lines[i] = #result.lines - 1
		if is_selected and style.marker_hl then
			style.highlight_text(result, rows, option_marker, style.marker_hl)
		end
	end
	return option_lines, option_end_lines
end

---The "<numbers> select" and "<prev> / <next> move" hint parts for chat widgets.
---@param option_count integer
---@param keys? table Chat keymap configuration
---@return string select_part
---@return string move_part
function M.selection_hint(option_count, keys)
	local keymaps = require("opencode.util.keymap")
	return keymaps.number_labels("chat", 1, option_count, keys) .. " select",
		keymaps.label("chat", "widget_prev", keys) .. " / " .. keymaps.label("chat", "widget_next", keys) .. " move"
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
