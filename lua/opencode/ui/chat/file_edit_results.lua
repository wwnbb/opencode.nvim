local cs = require("opencode.ui.chat.state")
return cs.factory("file_edit_results", function(view)
-- Unified final-result renderer for file editing tools. Normalization lives in
-- opencode.edit.tool_results; this module only renders its model.

local M = {}

local render = cs.module(view, require("opencode.ui.chat.render"))
local style = cs.module(view, require("opencode.ui.chat.tool_style"))
local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local text_util = require("opencode.util.text")
local tool_results = require("opencode.edit.tool_results")

local SUPPORTED_TOOLS = tool_results.SUPPORTED_TOOLS
local normalize_number = tool_results.normalize_number
local is_list = tool_results.is_list
local get_tool_state = tool_results.tool_state
local display_path = tool_results.display_path
local normalize_model = tool_results.normalize_model

---@type fun(diff: string|nil): number, number
local parse_diff_stats = text_util.diff_stats

local STATUS_ICON = {
	applied = "✓",
	partial = "◆",
	rejected = "✗",
	failed = "✗",
	unknown = "?",
}

-- Foreground-only groups: on the header they sit on the chat background, inside
-- the frame they combine with its CursorLine background.
local STATUS_HL = {
	applied = "OpenCodeFileEditApplied",
	partial = "OpenCodeFileEditPartial",
	rejected = "OpenCodeFileEditFailed",
	failed = "OpenCodeFileEditFailed",
}
local ADD_HL, DELETE_HL, WARNING_HL = "OpenCodeFileEditAdd", "OpenCodeFileEditDelete", "OpenCodeFileEditWarning"

require("opencode.ui.highlights").register("opencode.ui.chat.file_edit_results", function()
	local panel = require("opencode.ui.panel")
	local function fg(sources)
		for _, source in ipairs(sources) do
			local value = panel.get_hl(source).fg
			if value then return value end
		end
	end
	for name, sources in pairs({
		[STATUS_HL.applied] = { "String" },
		[STATUS_HL.partial] = { "Special" },
		[STATUS_HL.failed] = { "DiagnosticError", "ErrorMsg" },
		[ADD_HL] = { "String", "Added", "DiagnosticOk" },
		[DELETE_HL] = { "DiagnosticError", "Removed", "ErrorMsg" },
		[WARNING_HL] = { "DiagnosticWarn", "WarningMsg" },
	}) do
		vim.api.nvim_set_hl(0, name, { fg = fg(sources) })
	end
end)

local TYPE_MARKER = {
	add = "A",
	update = "M",
	delete = "D",
	move = "R",
	write = "W",
}

local TYPE_LABEL = {
	add = "added",
	update = "modified",
	delete = "deleted",
	move = "renamed",
	write = "wrote",
}

---@param status string
---@return string
local function status_hl(status)
	return STATUS_HL[status] or style.header_hl
end

---@param file OpenCodeFileEditResultFile
---@return string
local function file_display_path(file)
	local path = display_path(text_util.first_string(file.relativePath, file.filePath))
	if file.type == "move" and text_util.is_present(file.movePath) then
		return path .. " -> " .. display_path(file.movePath)
	end
	return path
end

---@param model OpenCodeFileEditResult
---@return number
---@return number
local function total_stats(model)
	local additions = 0
	local deletions = 0
	for _, file in ipairs(model.files) do
		additions = additions + (file.additions or 0)
		deletions = deletions + (file.deletions or 0)
	end
	return additions, deletions
end

---@param count number
---@return string
local function file_count_label(count)
	return tostring(count) .. " " .. (count == 1 and "file" or "files")
end

---@param additions number
---@param deletions number
---@return string
local function stats_label(additions, deletions)
	return "+" .. tostring(additions or 0) .. " -" .. tostring(deletions or 0)
end

---@param value any
---@return number
local function diagnostic_count(value)
	if type(value) == "string" then
		return value ~= "" and 1 or 0
	end
	if type(value) ~= "table" then
		return 0
	end
	local explicit = normalize_number(value.count)
	if explicit then
		return explicit
	end
	local count = #value
	if count > 0 then
		return count
	end
	for _, item in pairs(value) do
		if type(item) == "table" and is_list(item) then
			count = count + #item
		elseif not text_util.is_nil(item) then
			count = count + 1
		end
	end
	return count
end

---Highlight `text` in the last row added, searching after `after` when given.
---@param result table
---@param rows table[]
---@param text string
---@param hl_group string
---@param after? string
local function highlight_text(result, rows, text, hl_group, after)
	if text == "" then
		return
	end
	for _, row in ipairs(rows or {}) do
		---@type integer|nil
		local from = 1
		if after then
			local marker = row.line:find(after, 1, true)
			from = marker and (marker + #after) or nil
		end
		local start_pos = from and row.line:find(text, from, true)
		if start_pos then
			table.insert(result.highlights, {
				line = row.line_index,
				col_start = start_pos - 1,
				col_end = start_pos + #text - 1,
				hl_group = hl_group,
			})
			return
		end
	end
end

---@param result table
---@param rows table[]
---@param additions number
---@param deletions number
---@param after? string
local function highlight_stats(result, rows, additions, deletions, after)
	highlight_text(result, rows, "+" .. tostring(additions or 0), ADD_HL, after)
	highlight_text(result, rows, "-" .. tostring(deletions or 0), DELETE_HL, after)
end

M.normalize_model = normalize_model

---" ▸ ✓ <title> · N files · +A -D", the compact header for both states.
---@param result table
---@param model OpenCodeFileEditResult
---@param expanded boolean
local function add_header(result, model, expanded)
	local additions, deletions = total_stats(model)
	local icon = STATUS_ICON[model.status] or "?"
	local header = table.concat({
		tool_panel.fold_prefix(expanded) .. icon .. " " .. model.title,
		file_count_label(#model.files),
		stats_label(additions, deletions),
	}, " · ")
	local _, _, rows = render.add_panel_line(result, header, style.header_hl, { prefix = " " })
	highlight_text(result, rows, icon, status_hl(model.status))
	highlight_stats(result, rows, additions, deletions, " · ")
end

---@param model OpenCodeFileEditResult
---@return table
local function render_collapsed(model)
	local result = { lines = {}, highlights = {} }
	add_header(result, model, false)

	for _, file in ipairs(model.files) do
		local status = file.status or "unknown"
		local status_icon = STATUS_ICON[status] or "?"
		local type_marker = TYPE_MARKER[file.type] or "M"
		local suffix
		if status == "rejected" or status == "failed" then
			suffix = status
		else
			suffix = stats_label(file.additions, file.deletions)
			if status == "partial" or status == "unknown" then
				suffix = suffix .. " · " .. status
			end
		end

		local line = string.format("%s %s %s · %s", status_icon, type_marker, file_display_path(file), suffix)
		local rows = select(3, render.add_panel_line(result, line, style.header_hl, { prefix = style.SUB_PREFIX }))
		highlight_text(result, rows, status_icon, status_hl(status))
		if status ~= "rejected" and status ~= "failed" then
			highlight_stats(result, rows, file.additions, file.deletions, " · ")
		end
		if status == "partial" or status == "rejected" or status == "failed" then
			highlight_text(result, rows, status, status_hl(status), " · ")
		end
	end

	result.lines[#result.lines + 1] = ""
	return result
end

---@param model OpenCodeFileEditResult
---@return table
local function render_expanded(model)
	local result = { lines = {}, highlights = {} }
	local panel = style.panel
	add_header(result, model, true)
	style.add_border(result)

	for index, file in ipairs(model.files) do
		local status = file.status or "unknown"
		---@type string
		local label = status
		if status == "applied" then
			label = TYPE_LABEL[file.type] or "modified"
		end
		local icon = STATUS_ICON[status] or "?"
		local _, _, rows = panel.add_line(result, string.format("%s %s %s", icon, label, file_display_path(file)))
		highlight_text(result, rows, icon, status_hl(status))
		highlight_text(result, rows, label, status_hl(status))

		if status == "rejected" then
			panel.add_line(result, "  not applied", style.border_hl)
		elseif status == "failed" then
			panel.add_line(result, "  failed", style.body_error_hl)
		elseif status == "partial" then
			if
				text_util.is_present(file.proposedDiff)
				and text_util.is_present(file.diff)
				and vim.trim(file.proposedDiff) ~= vim.trim(file.diff)
			then
				panel.add_line(result, "  actual differs from proposed", style.border_hl)
			else
				panel.add_line(result, "  partially applied", style.border_hl)
			end

			local proposed_additions, proposed_deletions = parse_diff_stats(file.proposedDiff)
			local _, _, stats_rows = panel.add_line(result, "  actual " .. stats_label(file.additions, file.deletions)
				.. " · proposed " .. stats_label(proposed_additions, proposed_deletions), style.border_hl)
			highlight_stats(result, stats_rows, file.additions, file.deletions)
			highlight_stats(result, stats_rows, proposed_additions, proposed_deletions, " · proposed ")
		else
			local _, _, stats_rows = panel.add_line(result, "  actual " .. stats_label(file.additions, file.deletions),
				style.border_hl)
			highlight_stats(result, stats_rows, file.additions, file.deletions)
		end

		local diagnostics = diagnostic_count(file.diagnostics)
		if diagnostics > 0 then
			panel.add_line(result, "  " .. tostring(diagnostics) .. " diagnostics", style.border_hl)
			for _, diagnostic in ipairs(require("opencode.diagnostics").parse(file.diagnostics, file.filePath)) do
				if diagnostic.path == file.filePath or diagnostic.path == file.relativePath then
					local severity = ({ "Error", "Warning", "Info", "Hint" })[diagnostic.severity] or "Diagnostic"
					panel.add_line(result, string.format("  %s [%d:%d] %s", severity, diagnostic.line, diagnostic.character + 1,
						diagnostic.message), diagnostic.severity == 1 and style.body_error_hl or style.border_hl)
				end
			end
			panel.add_line(result, "  /diagnostics: list and jump", style.border_hl)
		end

		if index < #model.files then
			panel.add_blank(result)
		end
	end

	style.add_border(result, true)
	style.contain_background(result)
	result.lines[#result.lines + 1] = ""
	return result
end

---@return table
local function render_pending()
	local result = { lines = {}, highlights = {} }
	render.add_panel_line(result, "~ Preparing file changes… " .. tool_panel.anim_frame(), style.header_hl, { prefix = " " })
	result.lines[#result.lines + 1] = ""
	return result
end

---@param tool_part table
---@param is_expanded boolean
---@return table|nil result
function M.render_tool(tool_part, is_expanded)
	if type(tool_part) ~= "table" or not SUPPORTED_TOOLS[tool_part.tool] then
		return nil
	end

	local tool_state = get_tool_state(tool_part)
	local tool_status = tool_state.status or "pending"
	if tool_status == "pending" or tool_status == "running" then
		return render_pending()
	end

	local model = normalize_model(tool_part)
	if not model then
		return nil
	end
	if is_expanded then
		return render_expanded(model)
	end
	return render_collapsed(model)
end

return M

end)
