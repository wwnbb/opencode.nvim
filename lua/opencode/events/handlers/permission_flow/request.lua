local M = {}

local util = require("opencode.events.util")
local sync = require("opencode.sync")

local EDIT_PERMISSION_TYPES = {
	diff_review = true,
	neovim_edit = true,
	neovim_apply_patch = true,
}

---@param value any
---@return string|nil
local function nonempty_string(value)
	if type(value) ~= "string" or value == "" then
		return nil
	end
	return value
end

---@param ... any
---@return string|nil
local function first_non_empty(...)
	for i = 1, select("#", ...) do
		local value = nonempty_string(select(i, ...))
		if value then
			return value
		end
	end
	return nil
end

---@param value any
---@return boolean
local function is_list(value)
	if vim.islist then
		return vim.islist(value)
	end
	return vim.tbl_islist(value)
end

---@param message_id string|nil
---@return string|nil
local function find_message_session_id(message_id)
	if not message_id then
		return nil
	end

	local ok_sync, sync = pcall(require, "opencode.sync")
	if ok_sync and sync.find_message_session_id then
		return nonempty_string(sync.find_message_session_id(message_id))
	end
	return nil
end

---@param data table
---@param metadata table
---@param message_id string|nil
---@return string|nil
local function resolve_session_id(data, metadata, message_id)
	return find_message_session_id(message_id)
		or first_non_empty(
			data.sessionID,
			data.session_id,
			data.sessionId,
			metadata.sessionID,
			metadata.session_id,
			metadata.sessionId
		)
end

---@param diff_text any
---@return number, number
local function diff_stats(diff_text)
	if type(diff_text) ~= "string" or diff_text == "" then
		return 0, 0
	end

	local additions = 0
	local deletions = 0
	for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
		if line:sub(1, 3) ~= "+++" and line:sub(1, 1) == "+" then
			additions = additions + 1
		elseif line:sub(1, 3) ~= "---" and line:sub(1, 1) == "-" then
			deletions = deletions + 1
		end
	end

	return additions, deletions
end

---@param patterns any
---@return string|nil
local function pattern_path(patterns)
	if type(patterns) ~= "table" then
		return nil
	end

	if is_list(patterns) then
		for _, item in ipairs(patterns) do
			if type(item) == "string" and item ~= "" then
				return item
			end
			if type(item) == "table" then
				local nested = first_non_empty(item.path, item.filepath, item.file_path, item.file, item.pattern)
				if nested then
					return nested
				end
			end
		end
		return nil
	end

	return first_non_empty(patterns.path, patterns.filepath, patterns.file_path, patterns.file, patterns.pattern)
end

---@param file table
---@return table
local function normalize_file(file)
	local path = first_non_empty(file.filePath, file.filepath, file.file_path, file.file, file.path) or "(pending edit)"
	local diff = first_non_empty(file.diff, file.patch)
	local parsed_additions, parsed_deletions = diff_stats(diff)

	return {
		filePath = path,
		relativePath = first_non_empty(file.relativePath, file.relative_path) or vim.fn.fnamemodify(path, ":."),
		before = file.before or "",
		after = file.after or file.content or "",
		diff = diff,
		additions = type(file.additions) == "number" and file.additions or parsed_additions,
		deletions = type(file.deletions) == "number" and file.deletions or parsed_deletions,
		type = file.type or "update",
	}
end

---@param data table
---@param metadata table
---@return table
local function inline_edit_file(data, metadata)
	local path = first_non_empty(
		metadata.filepath,
		metadata.file_path,
		metadata.file,
		metadata.path,
		data.filepath,
		data.file_path,
		data.file,
		data.path,
		metadata.pattern,
		data.pattern,
		pattern_path(metadata.patterns),
		pattern_path(data.patterns)
	) or "(pending edit)"
	local diff = first_non_empty(metadata.diff, data.diff, metadata.patch, data.patch)
	local parsed_additions, parsed_deletions = diff_stats(diff)

	return {
		filePath = path,
		relativePath = vim.fn.fnamemodify(path, ":."),
		before = metadata.before or data.before or "",
		after = metadata.after or data.after or metadata.content or data.content or "",
		diff = diff,
		additions = type(metadata.additions) == "number" and metadata.additions
			or type(data.additions) == "number" and data.additions
			or parsed_additions,
		deletions = type(metadata.deletions) == "number" and metadata.deletions
			or type(data.deletions) == "number" and data.deletions
			or parsed_deletions,
		type = metadata.type or data.type or "update",
	}
end

---@param data table
---@param metadata table
---@return table
local function normalize_edit_files(data, metadata)
	local raw_files = metadata.files
	if type(raw_files) == "table" then
		local files = {}
		if is_list(raw_files) then
			for _, file in ipairs(raw_files) do
				if type(file) == "table" then
					table.insert(files, normalize_file(file))
				end
			end
		else
			table.insert(files, normalize_file(raw_files))
		end
		if #files > 0 then
			return files
		end
	end

	return { inline_edit_file(data, metadata) }
end

---@param request table
---@return table
function M.resolve_tool_input(request)
	local data = request.data
	local metadata = request.metadata
	local metadata_input = type(metadata.input) == "table" and metadata.input or {}

	if request.message_id and request.call_id then
		local sync = require("opencode.sync")
		for _, part in ipairs(sync.get_parts(request.message_id)) do
			if part.callID == request.call_id and part.state and type(part.state.input) == "table" then
				return part.state.input
			end
		end
	end

	return vim.tbl_deep_extend("force", {}, metadata_input, {
		command = data.command or metadata.command,
		description = data.description or metadata.description,
		path = data.path or metadata.path or data.filepath or metadata.filepath,
		file_path = data.file_path or metadata.file_path or data.file or metadata.file or data.filepath or metadata.filepath,
		pattern = data.pattern or metadata.pattern,
		query = data.query or metadata.query,
		url = data.url or metadata.url,
		directory = data.directory or metadata.directory or data.parentDir or metadata.parentDir,
		subagent_type = data.subagent_type or metadata.subagent_type,
	})
end

---@param data table|nil
---@return table|nil, string|nil
function M.decode(data)
	if type(data) ~= "table" then
		return nil, "permission payload must be a table"
	end

	local metadata = type(data.metadata) == "table" and data.metadata or {}
	local id = first_non_empty(data.requestID, data.request_id, data.id)
	if not id then
		return nil, "permission payload missing request id"
	end

	local permission_type = first_non_empty(data.permission, data.type)
	if not permission_type then
		return nil, "permission payload missing permission type"
	end

	local message_id = util.resolve_event_message_id(data)
	local call_id = util.resolve_event_call_id(data)
	local session_id = resolve_session_id(data, metadata, message_id)
	if not session_id then
		return nil, "permission payload missing session id"
	end

	if not message_id and call_id then
		message_id = sync.find_message_id_by_call_id(session_id, call_id)
	end

	local is_native_diff = metadata.opencode_native_diff == true or EDIT_PERMISSION_TYPES[permission_type] == true
	local kind = (is_native_diff or permission_type == "edit") and "edit" or "permission"
	local review_mode = nil
	if kind == "edit" then
		review_mode = permission_type == "edit" and not is_native_diff and "readonly" or "interactive"
	end

	local request = {
		id = id,
		type = permission_type,
		session_id = session_id,
		message_id = message_id,
		call_id = call_id,
		timestamp = util.event_time_to_seconds(data.time and data.time.created),
		metadata = metadata,
		kind = kind,
		review_mode = review_mode,
		data = data,
		patterns = type(data.patterns) == "table" and data.patterns or {},
		always = type(data.always) == "table" and data.always or {},
	}

	if kind == "edit" then
		request.files = normalize_edit_files(data, metadata)
	end

	return request, nil
end

---@param data table|nil
---@return table|nil
function M.decode_reply(data)
	if type(data) ~= "table" then
		return nil
	end

	local id = first_non_empty(data.requestID, data.request_id, data.permissionID, data.permission_id, data.id)
	if not id then
		return nil
	end

	return {
		id = id,
		reply = data.reply or data.response,
		session_id = first_non_empty(data.sessionID, data.session_id, data.sessionId),
		data = data,
	}
end

return M
