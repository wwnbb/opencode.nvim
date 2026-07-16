local M = {}

local edit_state = require("opencode.edit.state")
local file_edit_results = require("opencode.ui.chat.file_edit_results")
local render = require("opencode.ui.chat.render")
local sync = require("opencode.sync")

local PREVIEW_TOOLS = {
	edit = true,
	apply_patch = true,
	neovim_edit = true,
	neovim_apply_patch = true,
	write = true,
}

local RESULT_TO_EDIT_STATUS = {
	applied = "accepted",
	rejected = "rejected",
	failed = "rejected",
	partial = "resolved",
	unknown = "resolved",
}

---@param value any
---@return boolean
local function is_present(value)
	return type(value) == "string" and value ~= ""
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

---Return the first value at `raw[key]` for the given keys that is a string
---(including the empty string), or nil if no string value is found. A new
---file has `before=""` and a deletion has `after=""`, so empty strings are
---valid content and must not be skipped.
---@param raw table|nil
---@param ... string
---@return string|nil
local function first_string_or_empty(raw, ...)
	if type(raw) ~= "table" then
		return nil
	end
	for i = 1, select("#", ...) do
		local key = select(i, ...)
		local value = raw[key]
		if type(value) == "string" then
			return value
		end
	end
	return nil
end

---@param value any
---@return boolean
local function is_list(value)
	if type(value) ~= "table" then
		return false
	end
	if type(vim.islist) == "function" then
		return vim.islist(value)
	end
	return vim.tbl_islist(value)
end

---Count additions/deletions from a unified diff string.
---@param diff string
---@return number additions
---@return number deletions
local function count_diff_stats(diff)
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

---Build a lookup that maps a model file (and its 1-based index) to the RAW
---tool-part filediff entry, which still carries before/after content that
---file_edit_results.normalize_file drops.
---@param metadata table
---@return function|nil
local function raw_filediff_lookup(metadata)
	if type(metadata) ~= "table" then
		return nil
	end

	if type(metadata.filediff) == "table" then
		local filediff = metadata.filediff
		local filediff_path = first_string(
			filediff.file,
			filediff.filePath,
			filediff.filepath,
			filediff.file_path,
			filediff.path
		)
		return function(model_file, index)
			if index == 1 then
				return filediff
			end
			if model_file and filediff_path then
				local model_path = first_string(model_file.filePath, model_file.relativePath)
				if model_path and model_path == filediff_path then
					return filediff
				end
			end
			return nil
		end
	end

	if is_list(metadata.files) then
		local by_index = {}
		local by_path = {}
		for i, raw in ipairs(metadata.files) do
			by_index[i] = raw
			local key = first_string(raw.filePath, raw.filepath, raw.file_path, raw.file, raw.path)
			if key then
				by_path[key] = raw
			end
		end
		return function(model_file, index)
			if index and by_index[index] then
				return by_index[index]
			end
			if model_file and model_file.filePath and by_path[model_file.filePath] then
				return by_path[model_file.filePath]
			end
			return nil
		end
	end

	return nil
end

---Extract before/after content strings from a raw filediff entry, defensively.
---@param raw table|nil
---@return string|nil before
---@return string|nil after
local function extract_before_after(raw)
	if type(raw) ~= "table" then
		return nil, nil
	end
	local before = first_string_or_empty(raw, "before", "original", "oldContent", "old")
	local after = first_string_or_empty(raw, "after", "modified", "content", "new_string", "newString", "new")
	return before, after
end

---@param status any
---@return boolean
local function is_finished_status(status)
	if type(status) ~= "string" or status == "" then
		return false
	end
	return status ~= "pending" and status ~= "running"
end

---@param session_id string|nil
---@param message_id string|nil
---@param part table
---@return string|nil
local function preview_id(session_id, message_id, part)
	local part_id = part and (part.id or part.partID or part.callID)
	if not session_id or not message_id or not part_id then
		return nil
	end
	return table.concat({ "tool-preview", session_id, message_id, part_id }, ":")
end

---@param message table|nil
---@return number
local function message_timestamp(message)
	local time = type(message) == "table" and type(message.time) == "table" and message.time or {}
	local value = tonumber(time.completed or time.created)
	if not value then
		return os.time()
	end
	if value > 100000000000 then
		return math.floor(value / 1000)
	end
	return value
end

---@param message_id string|nil
---@param call_id string|nil
---@return boolean
local function has_existing_edit_for_tool(message_id, call_id)
	for _, estate in ipairs(edit_state.get_all()) do
		if message_id and estate.message_id == message_id then
			if not call_id or not estate.call_id or estate.call_id == call_id then
				return true
			end
		end
		if call_id and estate.call_id == call_id then
			return true
		end
	end
	return false
end

---@param model table
---@param part table|nil
---@return table files
---@return table statuses
local function model_to_edit_files(model, part)
	local files = {}
	local statuses = {}

	local metadata = part and render.get_tool_metadata(part) or {}
	local lookup = raw_filediff_lookup(metadata)

	for i, file in ipairs(model.files or {}) do
		local diff = file.diff
		if not is_present(diff) then
			diff = file.proposedDiff
		end

		local raw = lookup and lookup(file, i)
		if not is_present(diff) and raw then
			diff = first_string(raw.patch)
		end

		local before, after = extract_before_after(raw)

		local additions = file.additions
		local deletions = file.deletions

		if not is_present(diff) and before ~= nil and after ~= nil and before ~= after then
			local ok, computed = pcall(vim.diff, before, after, { result_type = "unified" })
			if ok and type(computed) == "string" and computed ~= "" then
				diff = computed
				additions, deletions = count_diff_stats(computed)
			end
		end

		table.insert(files, {
			filePath = file.filePath,
			relativePath = file.relativePath,
			before = before or "",
			after = after or "",
			diff = diff,
			additions = additions,
			deletions = deletions,
			type = file.type,
		})
		table.insert(statuses, RESULT_TO_EDIT_STATUS[file.status or model.status] or "resolved")
	end

	return files, statuses
end

---@param session_id string
---@param message table
---@param part table
---@return boolean created
local function sync_tool_part(session_id, message, part)
	if type(part) ~= "table" or part.type ~= "tool" or not PREVIEW_TOOLS[part.tool] then
		return false
	end

	local tool_state = type(part.state) == "table" and part.state or {}
	if not is_finished_status(tool_state.status) then
		return false
	end

	local message_id = part.messageID or message.id
	local call_id = part.callID
	if has_existing_edit_for_tool(message_id, call_id) then
		return false
	end

	local id = preview_id(session_id, message_id, part)
	if not id or edit_state.get_edit(id) then
		return false
	end

	local model = file_edit_results.normalize_model(part)
	if not model or #(model.files or {}) == 0 then
		return false
	end

	local files, statuses = model_to_edit_files(model, part)
	if #files == 0 then
		return false
	end

	edit_state.add_edit(id, session_id, files, {
		message_id = message_id,
		call_id = call_id,
		review_mode = "readonly",
		status = "sent",
		file_statuses = statuses,
		preview = true,
		timestamp = message_timestamp(message),
		metadata = {
			source = "tool_preview",
			tool = part.tool,
			status = model.status,
			title = model.title,
		},
	})
	return true
end

---@param session_id string|nil
---@return number created
function M.sync_session(session_id)
	if not session_id or session_id == "" then
		return 0
	end

	local created = 0
	for _, message in ipairs(sync.get_messages(session_id)) do
		if message.id then
			local render_parts = sync.get_message_render_parts(message.id)
			for _, part in ipairs(render_parts.tool_parts or {}) do
				if sync_tool_part(session_id, message, part) then
					created = created + 1
				end
			end
		end
	end
	return created
end

return M
