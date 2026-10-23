local cs = require("opencode.ui.chat.state")
return cs.factory("file_edit_results", function(view)
-- Unified final-result renderer for file editing tools. Normalization lives in
-- opencode.edit.tool_results; this module only renders its model.

local M = {}

local render = cs.module(view, require("opencode.ui.chat.render"))
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

local STATUS_HL = {
	applied = "String",
	partial = "Special",
	rejected = "ErrorMsg",
	failed = "ErrorMsg",
	unknown = "Comment",
}

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

---@param result table
---@param text string
---@param hl_group string|nil
---@param opts table|nil
---@return number line_index
---@return string line
local function add_line(result, text, hl_group, opts)
	if text == "" then
		return render.add_panel_blank(result, hl_group)
	end
	return render.add_panel_line(result, text, hl_group, opts)
end

---@param result table
---@param line_index number
---@param line string
---@param text string
---@param hl_group string
local function highlight_text(result, line_index, line, text, hl_group)
	if text == "" then
		return
	end
	local start_pos = line:find(text, 1, true)
	if not start_pos then
		return
	end
	table.insert(result.highlights, {
		line = line_index,
		col_start = start_pos - 1,
		col_end = start_pos + #text - 1,
		hl_group = hl_group,
	})
end

---@param result table
---@param line_index number
---@param line string
---@param additions number
---@param deletions number
local function highlight_stats(result, line_index, line, additions, deletions)
	local add_text = "+" .. tostring(additions or 0)
	local del_text = "-" .. tostring(deletions or 0)
	highlight_text(result, line_index, line, add_text, "DiffAdd")
	highlight_text(result, line_index, line, del_text, "DiffDelete")
end

---@param result table
---@param line_index number
---@param line string
---@param text string
---@param hl_group string
---@param marker string
local function highlight_text_after(result, line_index, line, text, hl_group, marker)
	if text == "" then
		return
	end
	local marker_pos = line:find(marker, 1, true)
	if not marker_pos then
		return
	end
	local start_pos = line:find(text, marker_pos + #marker, true)
	if not start_pos then
		return
	end
	table.insert(result.highlights, {
		line = line_index,
		col_start = start_pos - 1,
		col_end = start_pos + #text - 1,
		hl_group = hl_group,
	})
end

M.normalize_model = normalize_model

---@param model OpenCodeFileEditResult
---@return table
local function render_collapsed(model)
	local result = { lines = {}, highlights = {} }
	local additions, deletions = total_stats(model)
	local header = string.format(
		"%s %s  %s  %s",
		STATUS_ICON[model.status] or "?",
		model.title,
		file_count_label(#model.files),
		stats_label(additions, deletions)
	)
	local header_line_index, header_line = add_line(result, header, STATUS_HL[model.status] or "Comment")
	highlight_stats(result, header_line_index, header_line, additions, deletions)

	for _, file in ipairs(model.files) do
		local status = file.status or "unknown"
		local status_icon = STATUS_ICON[status] or "?"
		local type_marker = TYPE_MARKER[file.type] or "M"
		local path = file_display_path(file)
		local suffix
		if status == "rejected" then
			suffix = "rejected"
		elseif status == "failed" then
			suffix = "failed"
		else
			suffix = stats_label(file.additions, file.deletions)
			if status == "partial" or status == "unknown" then
				suffix = suffix .. " " .. status
			end
		end

		local prefix = string.format("  %s %s %s", status_icon, type_marker, path)
		local line_index, line = add_line(result, prefix .. "  " .. suffix, "Comment")
		highlight_text(result, line_index, line, status_icon, STATUS_HL[status] or "Comment")
		if status ~= "rejected" and status ~= "failed" then
			highlight_stats(result, line_index, line, file.additions, file.deletions)
		end
		if status == "partial" or status == "rejected" or status == "failed" then
			highlight_text(result, line_index, line, status, STATUS_HL[status] or "Comment")
		end
	end

	return result
end

---@param model OpenCodeFileEditResult
---@return table
local function render_expanded(model)
	local result = { lines = {}, highlights = {} }
	local additions, deletions = total_stats(model)
	local header = string.format(
		"▾ %s  %s  %s",
		model.title,
		file_count_label(#model.files),
		stats_label(additions, deletions)
	)
	local header_line_index, header_line = add_line(result, header, STATUS_HL[model.status] or "Comment")
	highlight_stats(result, header_line_index, header_line, additions, deletions)
	add_line(result, "", nil)

	for index, file in ipairs(model.files) do
		local status = file.status or "unknown"
		---@type string
		local label = status
		if status == "applied" then
			label = TYPE_LABEL[file.type] or "modified"
		end
		local path = file_display_path(file)
		local file_line = string.format("  %s %s %s", STATUS_ICON[status] or "?", label, path)
		local file_line_index, rendered_file_line = add_line(result, file_line, "Comment")
		highlight_text(
			result,
			file_line_index,
			rendered_file_line,
			STATUS_ICON[status] or "?",
			STATUS_HL[status] or "Comment"
		)
		highlight_text(result, file_line_index, rendered_file_line, label, STATUS_HL[status] or "Comment")

		if status == "rejected" then
			add_line(result, "    not applied", "Comment")
		elseif status == "failed" then
			add_line(result, "    failed", "ErrorMsg")
		elseif status == "partial" then
			if
				text_util.is_present(file.proposedDiff)
				and text_util.is_present(file.diff)
				and vim.trim(file.proposedDiff) ~= vim.trim(file.diff)
			then
				add_line(result, "    actual differs from proposed", "Comment")
			else
				add_line(result, "    partially applied", "Comment")
			end

			local proposed_additions, proposed_deletions = parse_diff_stats(file.proposedDiff)
			local stats = "    actual "
				.. stats_label(file.additions, file.deletions)
				.. ", proposed "
				.. stats_label(proposed_additions, proposed_deletions)
			local stats_line_index, stats_line = add_line(result, stats, "Comment")
			highlight_stats(result, stats_line_index, stats_line, file.additions, file.deletions)
			highlight_text_after(
				result,
				stats_line_index,
				stats_line,
				"+" .. tostring(proposed_additions),
				"DiffAdd",
				", proposed "
			)
			highlight_text_after(
				result,
				stats_line_index,
				stats_line,
				"-" .. tostring(proposed_deletions),
				"DiffDelete",
				", proposed "
			)
		else
			local stats = "    actual " .. stats_label(file.additions, file.deletions)
			local stats_line_index, stats_line = add_line(result, stats, "Comment")
			highlight_stats(result, stats_line_index, stats_line, file.additions, file.deletions)
		end

		local diagnostics = diagnostic_count(file.diagnostics)
		if diagnostics > 0 then
			add_line(result, "    " .. tostring(diagnostics) .. " diagnostics", "Comment")
			for _, diagnostic in ipairs(require("opencode.diagnostics").parse(file.diagnostics, file.filePath)) do
				if diagnostic.path == file.filePath or diagnostic.path == file.relativePath then
					local label = ({ "Error", "Warning", "Info", "Hint" })[diagnostic.severity] or "Diagnostic"
					add_line(result, string.format("    %s [%d:%d] %s", label, diagnostic.line, diagnostic.character + 1,
						diagnostic.message), diagnostic.severity == 1 and "DiagnosticError" or "DiagnosticWarn")
				end
			end
			add_line(result, "    /diagnostics: list and jump", "Comment")
		end

		if index < #model.files then
			add_line(result, "", nil)
		end
	end

	return result
end

---@return table
local function render_pending()
	local result = { lines = {}, highlights = {} }
	add_line(result, "~ Preparing file changes...", "Comment", { prefix = "   " })
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
