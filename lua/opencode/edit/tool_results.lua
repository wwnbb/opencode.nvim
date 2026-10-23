-- Normalized file-edit tool results. Pure data: no chat state, rendering or IO.
-- Accepts every field spelling the edit/patch tools have produced.

local M = {}

local text_util = require("opencode.util.text")

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

M.SUPPORTED_TOOLS = {
	edit = true,
	patch = true,
	apply_patch = true,
	neovim_edit = true,
	neovim_patch = true,
}

---@param value any
---@return number|nil
function M.normalize_number(value)
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
local normalize_number = M.normalize_number

---@param tbl table
---@return boolean
local function has_keys(tbl)
	return type(tbl) == "table" and next(tbl) ~= nil
end

---@param value any
---@return boolean
function M.is_list(value)
	if type(vim.islist) == "function" then
		return vim.islist(value)
	end
	return vim.tbl_islist(value)
end
local is_list = M.is_list

---@param tool_part table
---@return table
function M.tool_state(tool_part)
	return type(tool_part.state) == "table" and tool_part.state or {}
end
local get_tool_state = M.tool_state

---Part metadata overlaid by state metadata (same merge as chat render).
---@param tool_part table|nil
---@return table
function M.tool_metadata(tool_part)
	tool_part = type(tool_part) == "table" and tool_part or {}
	local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
	local part_metadata = type(tool_part.metadata) == "table" and tool_part.metadata or {}
	local state_metadata = type(tool_state.metadata) == "table" and tool_state.metadata or {}
	return vim.tbl_deep_extend("force", {}, part_metadata, state_metadata)
end

---@param tool_part table
---@return table
local function get_input(tool_part)
	local tool_state = get_tool_state(tool_part)
	if type(tool_state.input) == "table" then
		return tool_state.input
	end
	return {}
end

---@type fun(diff: string|nil): number, number
local parse_diff_stats = text_util.diff_stats

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
function M.display_path(path)
	if not text_util.is_present(path) then
		return "unknown"
	end

	local raw = tostring(path)
	if raw:sub(1, 1) == "/" or raw:sub(1, 1) == "~" then
		return vim.fn.fnamemodify(raw, ":~:.")
	end
	return raw
end
local display_path = M.display_path

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
	return text_util.first_string(raw.filePath, raw.filepath, raw.file_path, raw.file, raw.path, raw.relativePath, raw.relative_path)
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
	local file_path = text_util.first_string(
		source.filePath,
		source.filepath,
		source.file_path,
		source.file,
		source.path,
		opts.filePath
	)
	local relative_path = text_util.first_string(
		source.relativePath,
		source.relative_path,
		opts.relativePath,
		file_path and display_path(file_path) or nil
	)
	if not text_util.is_present(file_path) and not text_util.is_present(relative_path) then
		return nil
	end

	local diff = text_util.first_string(source.diff, source.patch, opts.diff)
	if diff == nil and (source.diff == "" or source.patch == "" or opts.diff == "") then
		diff = ""
	end
	local proposed_diff = text_util.first_string(
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

	local file_type = normalize_type(source.type) or normalize_type(source.status) or opts.type
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
		movePath = text_util.first_string(source.movePath, source.move_path, source.newPath, source.new_path, proposed.movePath),
		diagnostics = source.diagnostics or opts.diagnostics,
	}
end

---Normalize each raw entry with per-entry options, dropping unusable entries.
---@param raw_files table[]
---@param file_opts fun(raw: table|string, index: integer): table
---@return OpenCodeFileEditResultFile[]
local function normalize_files(raw_files, file_opts)
	local files = {}
	for index, raw in ipairs(raw_files) do
		local file = normalize_file(raw, file_opts(raw, index))
		if file then
			files[#files + 1] = file
		end
	end
	return files
end

---@param tool_part table
---@param metadata table
---@return string
local function get_title(tool_part, metadata)
	local tool_state = get_tool_state(tool_part)
	local output = text_util.first_string(tool_state.output)
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

	local explicit = text_util.first_string(tool_state.title, metadata.title, output_title)
	if explicit then
		return explicit
	end

	if tool_part.tool == "edit" or tool_part.tool == "neovim_edit" then
		return "Edit completed"
	elseif tool_part.tool == "patch" or tool_part.tool == "apply_patch" then
		return "Patch applied"
	elseif tool_part.tool == "neovim_patch" then
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

---@param tool_part table
---@param metadata table
---@param files OpenCodeFileEditResultFile[]
---@param has_proposed boolean
---@return OpenCodeFileEditResult
local function make_result(tool_part, metadata, files, has_proposed)
	return {
		tool = tool_part.tool,
		title = get_title(tool_part, metadata),
		status = derive_overall_status(files, get_tool_state(tool_part).status),
		files = files,
		hasProposed = has_proposed,
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
	local native_files = normalize_file_list(metadata.files)
	if #native_files > 0 then
		local files = normalize_files(native_files, function()
			return {
				filePath = text_util.first_string(input.path, input.filePath, input.file_path),
				type = "update",
				status = file_status,
				diff = #native_files == 1 and metadata.diff or nil,
			}
		end)
		if #files == 0 then return nil end
		return make_result(tool_part, metadata, files, false)
	end
	local diff = nil
	local raw = nil

	if type(metadata.filediff) == "table" then
		raw = metadata.filediff
		diff = text_util.first_string(raw.diff, metadata.diff)
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
		filePath = text_util.first_string(metadata.filepath, metadata.filePath, metadata.file_path, input.path, input.filePath, input.file_path),
		relativePath = text_util.first_string(metadata.relativePath, metadata.relative_path),
		type = raw.before == "" and "add" or "update",
		status = file_status,
		diff = diff,
		diagnostics = metadata.diagnostics,
	})
	if not file then
		return nil
	end

	return make_result(tool_part, metadata, { file }, false)
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
		filePath = text_util.first_string(metadata.filediff.file, metadata.filepath, metadata.filePath),
		type = metadata.filediff.before == "" and "add" or "update",
		status = file_status,
		diff = metadata.diff,
		proposedDiff = metadata.proposed_diff,
		diagnostics = metadata.diagnostics,
	})
	if not file then
		return nil
	end

	return make_result(tool_part, metadata, { file }, text_util.is_present(metadata.proposed_diff))
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
	local single = #raw_files == 1
	local files = normalize_files(raw_files, function()
		return {
			type = "update",
			status = status,
			diff = single and metadata.diff or nil,
			diagnostics = single and metadata.diagnostics or nil,
		}
	end)
	if #files == 0 then
		return nil
	end

	return make_result(tool_part, metadata, files, false)
end

---@param tool_part table
---@param metadata table
---@return OpenCodeFileEditResult|nil
local function normalize_neovim_patch(tool_part, metadata)
	local tool_state = get_tool_state(tool_part)
	local raw_files = normalize_file_list(metadata.files)
	if #raw_files == 0 then
		return nil
	end

	local proposed_lookup = build_proposed_lookup(metadata.proposed_files)
	local status = normalize_result_status(metadata.status)
		or normalize_result_status(tool_state.status)
		or "unknown"
	local single = #raw_files == 1
	local files = normalize_files(raw_files, function(raw, index)
		local key = get_raw_file_key(raw)
		return {
			type = "update",
			status = status,
			diff = single and metadata.diff or nil,
			proposed = (key and (proposed_lookup[key] or proposed_lookup[display_path(key)])) or proposed_lookup[index],
			proposedDiff = single and metadata.proposed_diff or nil,
			diagnostics = single and metadata.diagnostics or nil,
		}
	end)
	if #files == 0 then
		return nil
	end

	return make_result(tool_part, metadata, files,
		text_util.is_present(metadata.proposed_diff) or #normalize_file_list(metadata.proposed_files) > 0)
end

---@param tool_part table
---@return OpenCodeFileEditResult|nil
function M.normalize_model(tool_part)
	local metadata = M.tool_metadata(tool_part)
	if not has_keys(metadata) then
		return nil
	end

	if tool_part.tool == "edit" then
		return normalize_edit(tool_part, metadata)
	elseif tool_part.tool == "patch" or tool_part.tool == "apply_patch" then
		return normalize_apply_patch(tool_part, metadata)
	elseif tool_part.tool == "neovim_edit" then
		return normalize_neovim_edit(tool_part, metadata)
	elseif tool_part.tool == "neovim_patch" then
		return normalize_neovim_patch(tool_part, metadata)
	end
	return nil
end

return M
