local M = {}

local panel = require("opencode.ui.panel")
local render = require("opencode.ui.chat.render")
local chat_state = require("opencode.ui.chat.state").state

M.PANEL_PREFIX = "▏  "
M.PANEL_BLANK_PREFIX = "▏"
M.ANIM_FRAMES = { "|", "/", "-", "\\" }

---@param opts table
---@return OpenCodePanelHelpers
function M.create_panel(opts)
	opts = opts or {}
	local helpers = panel.create_helpers({
		prefix = opts.prefix or M.PANEL_PREFIX,
		blank_prefix = opts.blank_prefix or M.PANEL_BLANK_PREFIX,
		border_hl = opts.border_hl,
		default_hl = opts.default_hl,
	})

	function helpers.result()
		return { lines = {}, highlights = {} }
	end

	---@param result table
	---@param entry table
	function helpers.add_entry(result, entry)
		entry = entry or {}
		if entry.text == "" then
			helpers.add_blank(result, entry.hl_group)
			return
		end
		helpers.add_line(result, entry.text or "", entry.hl_group)
	end

	---@param result table
	---@param entries table[]
	---@param render_opts? table
	---@return number shown
	---@return boolean has_overflow
	function helpers.render_entries(result, entries, render_opts)
		render_opts = vim.tbl_extend("force", { panel = helpers }, render_opts or {})
		return M.render_entries(result, entries, render_opts)
	end

	return helpers
end

---@param tool_part table
---@return table
function M.context(tool_part)
	tool_part = type(tool_part) == "table" and tool_part or {}
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local status = tool_state.status or "pending"
	return {
		state = tool_state,
		input = tool_state.input or {},
		metadata = render.get_tool_metadata(tool_part),
		status = status,
		working = status == "pending" or status == "running",
		output = tool_state.output,
		error = tool_state.error,
	}
end

---@return number
function M.chat_width()
	return render.get_chat_text_width()
end

---@param frames? string[]
---@return string
function M.anim_frame(frames)
	frames = frames or M.ANIM_FRAMES
	local count = #frames
	if count == 0 then
		return ""
	end
	local index = tonumber(chat_state.task_anim_frame) or 1
	return frames[((index - 1) % count) + 1] or frames[1] or ""
end

---@param expanded boolean
---@return string
function M.fold_prefix(expanded)
	return expanded and "▾ " or "▸ "
end

---@param text string
---@param opts? table
---@return string
function M.header(text, opts)
	opts = opts or {}
	if opts.fold then
		text = M.fold_prefix(opts.expanded == true) .. text
	end
	if opts.working then
		text = text .. " " .. M.anim_frame(opts.frames)
	end
	return text
end

---@param entries table[]
---@param text string|nil
---@param hl_group string|nil
---@param opts? table
---@return number added
function M.append_entries(entries, text, hl_group, opts)
	opts = opts or {}
	if type(text) ~= "string" or text == "" then
		return 0
	end

	local added = 0
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		local line_hl = hl_group
		if type(opts.hl_for_line) == "function" then
			line_hl = opts.hl_for_line(line, hl_group)
		end
		table.insert(entries, { text = line, hl_group = line_hl })
		added = added + 1
	end
	return added
end

---@param entries table[]
---@param text string|nil
---@param hl_group string
---@param blank_hl string|nil
---@return number added
function M.append_error_entries(entries, text, hl_group, blank_hl)
	if type(text) ~= "string" or text == "" then
		return 0
	end
	if #entries > 0 then
		table.insert(entries, { text = "", hl_group = blank_hl })
	end
	return M.append_entries(entries, text, hl_group)
end

---@param entries table[]
---@param expanded boolean
---@param max_entries number
---@return number
function M.visible_count(entries, expanded, max_entries)
	if expanded then
		return #entries
	end
	return math.min(max_entries, #entries)
end

---@param remaining number
---@param noun? string
---@return string
function M.overflow_text(remaining, noun)
	noun = noun or "lines"
	return "… (" .. tostring(remaining) .. " more " .. noun .. ", press O to expand)"
end

---@param result table
---@param entries table[]
---@param opts table
---@return number shown
---@return boolean has_overflow
function M.render_entries(result, entries, opts)
	opts = opts or {}
	local max_entries = tonumber(opts.max) or #entries
	local expanded = opts.expanded == true
	local panel_helpers = opts.panel
	local shown = M.visible_count(entries, expanded, max_entries)

	for i = 1, shown do
		if type(opts.render_entry) == "function" then
			opts.render_entry(result, entries[i], i)
		elseif panel_helpers and type(panel_helpers.add_entry) == "function" then
			panel_helpers.add_entry(result, entries[i])
		end
	end

	local has_overflow = shown < #entries
	if has_overflow and not expanded and panel_helpers then
		local remaining = #entries - shown
		panel_helpers.add_line(result, M.overflow_text(remaining, opts.overflow_noun), opts.overflow_hl)
	end

	return shown, has_overflow
end

---@param value any
---@return number|nil
function M.normalize_number(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" and value ~= "" then
		return tonumber(value)
	end
	return nil
end

return M
