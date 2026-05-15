-- Unified final-result renderer for file editing tools.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")

---@class OpenCodeFileEditResultFile
---@field filePath string
---@field relativePath string
---@field type "add"|"update"|"delete"|"move"|"write"
---@field status "applied"|"partial"|"rejected"|"failed"|"unknown"
---@field additions number
---@field deletions number
---@field diff string|nil
---@field proposedDiff string|nil
---@field movePath string|nil
---@field diagnostics table|nil

---@class OpenCodeFileEditResult
---@field tool string
---@field title string
---@field status "applied"|"partial"|"rejected"|"failed"|"unknown"
---@field files OpenCodeFileEditResultFile[]
---@field hasProposed boolean

local SUPPORTED_TOOLS = {
	write = true,
	edit = true,
	apply_patch = true,
	neovim_edit = true,
	neovim_apply_patch = true,
}

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

---@param value any
---@return boolean
local function is_nil(value)
	return value == nil or value == vim.NIL
end

---@param value any
---@return boolean
local function is_present(value)
	return not is_nil(value) and tostring(value) ~= ""
end

---@param ... any
---@return string|nil
local function first_string(...)
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if type(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

---@param value any
---@return number|nil
local function normalize_number(value)
	if type(value) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return nil
		end
		return value
	end
	if type(value) == "string" and value ~= "" then
		return tonumber(value)
	end
	return nil
end

---@param value any
---@return boolean
local function is_false(value)
	if value == false then
		return true
	end
	if type(value) == "string" then
		local lowered = value:lower()
		return lowered == "false" or lowered == "0" or lowered == "no"
	end
	return false
end

---@param tbl table
---@return boolean
local function has_keys(tbl)
	return type(tbl) == "table" and next(tbl) ~= nil
end

---@param value any
---@return boolean
local function is_list(value)
	if type(vim.islist) == "function" then
		return vim.islist(value)
	end
	return vim.tbl_islist(value)
end

---@param tool_part table
---@return table
local function get_tool_state(tool_part)
	return type(tool_part.state) == "table" and tool_part.state or {}
end

---@param tool_part table
---@return table
local function get_input(tool_part)
	local tool_state = get_tool_state(tool_part)
	if type(tool_state.input) == "table" then
		return tool_state.input
	end
	if type(tool_part.input) == "table" then
		return tool_part.input
	end
	return {}
end

---@param diff string|nil
---@return number additions
---@return number deletions
local function parse_diff_stats(diff)
	if type(diff) ~= "string" or diff == "" then
		return 0, 0
	end

	local additions = 0
	local deletions = 0
	for _, line in ipairs(vim.split(diff, "\n", { plain = true })) do
		if line:sub(1, 3) ~= "+++" and line:sub(1, 1) == "+" then
			additions = additions + 1
		elseif line:sub(1, 3) ~= "---" and line:sub(1, 1) == "-" then
			deletions = deletions + 1
		end
	end
	return additions, deletions
end

---@param value any
---@return "applied"|"partial"|"rejected"|"failed"|"unknown"|nil
local function normalize_result_status(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end

	local lowered = value:lower()
	if lowered == "completed" or lowered == "success" or lowered == "accepted" or lowered == "approved" then
		return "applied"
	end
	if lowered == "applied" then
		return "applied"
	end
	if lowered == "partial" or lowered == "partially_applied" or lowered == "resolved" then
		return "partial"
	end
	if lowered == "rejected" or lowered == "denied" then
		return "rejected"
	end
	if lowered == "failed" or lowered == "error" then
		return "failed"
	end
	if lowered == "unknown" then
		return "unknown"
	end
	return nil
end

---@param value any
---@return "add"|"update"|"delete"|"move"|"write"|nil
local function normalize_type(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end

	local lowered = value:lower()
	if lowered == "add" or lowered == "added" or lowered == "create" or lowered == "created" or lowered == "new" then
		return "add"
	end
	if lowered == "delete" or lowered == "deleted" or lowered == "remove" or lowered == "removed" then
		return "delete"
	end
	if lowered == "move" or lowered == "moved" or lowered == "rename" or lowered == "renamed" then
		return "move"
	end
	if lowered == "write" or lowered == "wrote" then
		return "write"
	end
	if
		lowered == "update"
		or lowered == "updated"
		or lowered == "modify"
		or lowered == "modified"
		or lowered == "edit"
	then
		return "update"
	end
	return nil
end

---@param path string|nil
---@return string
local function display_path(path)
	if not is_present(path) then
		return "unknown"
	end

	local raw = tostring(path)
	if raw:sub(1, 1) == "/" or raw:sub(1, 1) == "~" then
		return vim.fn.fnamemodify(raw, ":~:.")
	end
	return raw
end

---@param file OpenCodeFileEditResultFile
---@return string
local function file_display_path(file)
	local path = display_path(first_string(file.relativePath, file.filePath))
	if file.type == "move" and is_present(file.movePath) then
		return path .. " -> " .. display_path(file.movePath)
	end
	return path
end

---@param value any
---@return table[]
local function normalize_file_list(value)
	if type(value) ~= "table" then
		return {}
	end

	if is_list(value) then
		local result = {}
		for _, item in ipairs(value) do
			table.insert(result, item)
		end
		return result
	end

	if
		value.filePath
		or value.filepath
		or value.file_path
		or value.file
		or value.path
		or value.relativePath
		or value.diff
	then
		return { value }
	end

	local result = {}
	for _, item in pairs(value) do
		if type(item) == "table" or type(item) == "string" then
			table.insert(result, item)
		end
	end
	return result
end

---@param raw table|string
---@return string|nil
local function get_raw_file_key(raw)
	if type(raw) == "string" then
		return raw
	end
	if type(raw) ~= "table" then
		return nil
	end
	return first_string(raw.filePath, raw.filepath, raw.file_path, raw.file, raw.path, raw.relativePath, raw.relative_path)
end

---@param raw_files any
---@return table
local function build_proposed_lookup(raw_files)
	local lookup = {}
	for index, raw in ipairs(normalize_file_list(raw_files)) do
		local key = get_raw_file_key(raw)
		if key then
			lookup[key] = raw
			lookup[display_path(key)] = raw
		end
		lookup[index] = raw
	end
	return lookup
end

---@param raw table|string
---@param opts table
---@return OpenCodeFileEditResultFile|nil
local function normalize_file(raw, opts)
	opts = opts or {}
	local source = {}
	if type(raw) == "string" then
		source.filePath = raw
	elseif type(raw) == "table" then
		source = raw
	else
		return nil
	end

	local proposed = type(opts.proposed) == "table" and opts.proposed or {}
	local file_path = first_string(
		source.filePath,
		source.filepath,
		source.file_path,
		source.file,
		source.path,
		opts.filePath
	)
	local relative_path = first_string(
		source.relativePath,
		source.relative_path,
		opts.relativePath,
		file_path and display_path(file_path) or nil
	)
	if not is_present(file_path) and not is_present(relative_path) then
		return nil
	end

	local diff = first_string(source.diff, opts.diff)
	local proposed_diff = first_string(
		source.proposedDiff,
		source.proposed_diff,
		proposed.diff,
		proposed.proposedDiff,
		proposed.proposed_diff,
		opts.proposedDiff
	)
	local diff_additions, diff_deletions = parse_diff_stats(diff)
	local status = normalize_result_status(source.status) or opts.status or "unknown"
	local additions = normalize_number(source.additions)
		or normalize_number(source.added)
		or (type(source.stats) == "table" and normalize_number(source.stats.added) or nil)
	local deletions = normalize_number(source.deletions)
		or normalize_number(source.removed)
		or (type(source.stats) == "table" and normalize_number(source.stats.removed) or nil)

	if additions == nil then
		additions = status == "rejected" and 0 or diff_additions
	end
	if deletions == nil then
		deletions = status == "rejected" and 0 or diff_deletions
	end

	local file_type = normalize_type(source.type) or opts.type
	if not file_type then
		if source.before == "" or source.oldContent == "" then
			file_type = "add"
		else
			file_type = "update"
		end
	end

	return {
		filePath = file_path or relative_path,
		relativePath = relative_path or display_path(file_path),
		type = file_type,
		status = status,
		additions = additions or 0,
		deletions = deletions or 0,
		diff = diff,
		proposedDiff = proposed_diff,
		movePath = first_string(source.movePath, source.move_path, source.newPath, source.new_path, proposed.movePath),
		diagnostics = source.diagnostics or opts.diagnostics,
	}
end

---@param tool_part table
---@param metadata table
---@return string
local function get_title(tool_part, metadata)
	local tool_state = get_tool_state(tool_part)
	local output = first_string(tool_state.output, tool_part.output)
	local output_title = nil
	if output then
		for _, line in ipairs(vim.split(output, "\n", { plain = true })) do
			line = vim.trim(line):gsub("%.$", "")
			if line ~= "" and #line <= 80 then
				output_title = line
				break
			end
		end
	end

	local explicit = first_string(tool_state.title, metadata.title, output_title)
	if explicit then
		return explicit
	end

	if tool_part.tool == "write" then
		return "File write completed"
	elseif tool_part.tool == "edit" or tool_part.tool == "neovim_edit" then
		return "Edit completed"
	elseif tool_part.tool == "apply_patch" then
		return "Patch applied"
	elseif tool_part.tool == "neovim_apply_patch" then
		return "Patch review completed"
	end
	return "File changes completed"
end

---@param files OpenCodeFileEditResultFile[]
---@param tool_status string
---@return "applied"|"partial"|"rejected"|"failed"|"unknown"
local function derive_overall_status(files, tool_status)
	if tool_status == "error" then
		return "failed"
	end
	if #files == 0 then
		return "unknown"
	end

	local all_applied = true
	local all_rejected = true
	local all_unknown = true
	for _, file in ipairs(files) do
		if file.status == "failed" then
			return "failed"
		end
		if file.status == "partial" then
			return "partial"
		end
		if file.status ~= "applied" then
			all_applied = false
		end
		if file.status ~= "rejected" then
			all_rejected = false
		end
		if file.status ~= "unknown" then
			all_unknown = false
		end
	end

	if all_rejected then
		return "rejected"
	end
	if all_applied then
		return "applied"
	end
	if all_unknown then
		return "unknown"
	end
	return "partial"
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
		elseif not is_nil(item) then
			count = count + 1
		end
	end
	return count
end

---@param result table
---@param text string
---@param hl_group string|nil
---@return number line_index
---@return string line
local function add_line(result, text, hl_group)
	local line = render.sanitize_buffer_line(text)
	table.insert(result.lines, line)
	local line_index = #result.lines - 1
	if hl_group then
		table.insert(result.highlights, {
			line = line_index,
			col_start = 0,
			col_end = #line,
			hl_group = hl_group,
		})
	end
	return line_index, line
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

---@return number width
local function get_chat_text_width()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return 80
	end

	local width = vim.api.nvim_win_get_width(state.winid)
	local wininfo = vim.fn.getwininfo(state.winid)[1]
	local textoff = wininfo and tonumber(wininfo.textoff) or 0
	return math.max(1, width - textoff)
end

---@param prefix string
---@param suffix string
---@return string
local function align_suffix(prefix, suffix)
	local target = math.min(math.max(48, get_chat_text_width() - 18), 72)
	local width = vim.fn.strdisplaywidth(prefix)
	local padding = math.max(1, target - width)
	return prefix .. string.rep(" ", padding) .. suffix
end

---@param tool_part table
---@param metadata table
---@return OpenCodeFileEditResult|nil
local function normalize_write(tool_part, metadata)
	local input = get_input(tool_part)
	local tool_state = get_tool_state(tool_part)
	local status = normalize_result_status(metadata.status) or normalize_result_status(tool_state.status) or "unknown"
	local filepath = first_string(
		metadata.filepath,
		metadata.filePath,
		metadata.file_path,
		input.filePath,
		input.file_path
	)
	if not filepath then
		return nil
	end

	local diff = first_string(metadata.diff)
	local additions, deletions = parse_diff_stats(diff)
	local file = normalize_file({
		filePath = filepath,
		relativePath = first_string(metadata.relativePath, metadata.relative_path),
		type = is_false(metadata.exists) and "add" or "write",
		status = status,
		diff = diff,
		additions = normalize_number(metadata.additions) or additions,
		deletions = normalize_number(metadata.deletions) or deletions,
		diagnostics = metadata.diagnostics,
	}, {})
	if not file then
		return nil
	end

	return {
		tool = tool_part.tool,
		title = get_title(tool_part, metadata),
		status = derive_overall_status({ file }, tool_state.status),
		files = { file },
		hasProposed = false,
	}
end

---@param tool_part table
---@param metadata table
---@return OpenCodeFileEditResult|nil
local function normalize_edit(tool_part, metadata)
	local input = get_input(tool_part)
	local tool_state = get_tool_state(tool_part)
	local file_status = normalize_result_status(metadata.status)
		or normalize_result_status(tool_state.status)
		or "unknown"
	local diff = nil
	local raw = nil

	if type(metadata.filediff) == "table" then
		raw = metadata.filediff
		diff = first_string(raw.diff, metadata.diff)
	elseif type(metadata.filediff) == "string" and metadata.filediff ~= "" then
		diff = metadata.filediff
	elseif type(metadata.diff) == "string" and metadata.diff ~= "" then
		diff = metadata.diff
	end

	if not raw and not diff then
		return nil
	end

	raw = raw or {}
	local file = normalize_file(raw, {
		filePath = first_string(metadata.filepath, metadata.filePath, metadata.file_path, input.filePath, input.file_path),
		relativePath = first_string(metadata.relativePath, metadata.relative_path),
		type = raw.before == "" and "add" or "update",
		status = file_status,
		diff = diff,
		diagnostics = metadata.diagnostics,
	})
	if not file then
		return nil
	end

	return {
		tool = tool_part.tool,
		title = get_title(tool_part, metadata),
		status = derive_overall_status({ file }, tool_state.status),
		files = { file },
		hasProposed = false,
	}
end

---@param tool_part table
---@param metadata table
---@return OpenCodeFileEditResult|nil
local function normalize_neovim_edit(tool_part, metadata)
	local tool_state = get_tool_state(tool_part)
	if type(metadata.filediff) ~= "table" then
		return nil
	end

	local file_status = normalize_result_status(metadata.filediff.status)
		or normalize_result_status(metadata.status)
		or normalize_result_status(tool_state.status)
		or "unknown"
	local file = normalize_file(metadata.filediff, {
		filePath = first_string(metadata.filediff.file, metadata.filepath, metadata.filePath),
		type = metadata.filediff.before == "" and "add" or "update",
		status = file_status,
		diff = metadata.diff,
		proposedDiff = metadata.proposed_diff,
		diagnostics = metadata.diagnostics,
	})
	if not file then
		return nil
	end

	return {
		tool = tool_part.tool,
		title = get_title(tool_part, metadata),
		status = derive_overall_status({ file }, tool_state.status),
		files = { file },
		hasProposed = is_present(metadata.proposed_diff),
	}
end

---@param tool_part table
---@param metadata table
---@return OpenCodeFileEditResult|nil
local function normalize_apply_patch(tool_part, metadata)
	local tool_state = get_tool_state(tool_part)
	local raw_files = normalize_file_list(metadata.files)
	if #raw_files == 0 then
		return nil
	end

	local status = normalize_result_status(metadata.status) or normalize_result_status(tool_state.status) or "unknown"
	local files = {}
	for _, raw in ipairs(raw_files) do
		local file = normalize_file(raw, {
			type = "update",
			status = status,
			diff = #raw_files == 1 and metadata.diff or nil,
			diagnostics = #raw_files == 1 and metadata.diagnostics or nil,
		})
		if file then
			table.insert(files, file)
		end
	end
	if #files == 0 then
		return nil
	end

	return {
		tool = tool_part.tool,
		title = get_title(tool_part, metadata),
		status = derive_overall_status(files, tool_state.status),
		files = files,
		hasProposed = false,
	}
end

---@param tool_part table
---@param metadata table
---@return OpenCodeFileEditResult|nil
local function normalize_neovim_apply_patch(tool_part, metadata)
	local tool_state = get_tool_state(tool_part)
	local raw_files = normalize_file_list(metadata.files)
	if #raw_files == 0 then
		return nil
	end

	local proposed_lookup = build_proposed_lookup(metadata.proposed_files)
	local files = {}
	for index, raw in ipairs(raw_files) do
		local key = get_raw_file_key(raw)
		local proposed = (key and (proposed_lookup[key] or proposed_lookup[display_path(key)])) or proposed_lookup[index]
		local file = normalize_file(raw, {
			type = "update",
			status = normalize_result_status(metadata.status)
				or normalize_result_status(tool_state.status)
				or "unknown",
			diff = #raw_files == 1 and metadata.diff or nil,
			proposed = proposed,
			proposedDiff = #raw_files == 1 and metadata.proposed_diff or nil,
			diagnostics = #raw_files == 1 and metadata.diagnostics or nil,
		})
		if file then
			table.insert(files, file)
		end
	end
	if #files == 0 then
		return nil
	end

	return {
		tool = tool_part.tool,
		title = get_title(tool_part, metadata),
		status = derive_overall_status(files, tool_state.status),
		files = files,
		hasProposed = is_present(metadata.proposed_diff) or #normalize_file_list(metadata.proposed_files) > 0,
	}
end

---@param tool_part table
---@return OpenCodeFileEditResult|nil
local function normalize_model(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	if not has_keys(metadata) then
		return nil
	end

	if tool_part.tool == "write" then
		return normalize_write(tool_part, metadata)
	elseif tool_part.tool == "edit" then
		return normalize_edit(tool_part, metadata)
	elseif tool_part.tool == "apply_patch" then
		return normalize_apply_patch(tool_part, metadata)
	elseif tool_part.tool == "neovim_edit" then
		return normalize_neovim_edit(tool_part, metadata)
	elseif tool_part.tool == "neovim_apply_patch" then
		return normalize_neovim_apply_patch(tool_part, metadata)
	end
	return nil
end

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
		local line_index, line = add_line(result, align_suffix(prefix, suffix), "Comment")
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
				is_present(file.proposedDiff)
				and is_present(file.diff)
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
		end

		if index < #model.files then
			add_line(result, "", nil)
		end
	end

	return result
end

---@return table
local function render_pending()
	return {
		lines = { "~ Preparing file changes..." },
		highlights = {
			{
				line = 0,
				col_start = 0,
				col_end = #"~ Preparing file changes...",
				hl_group = "Comment",
			},
		},
	}
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
