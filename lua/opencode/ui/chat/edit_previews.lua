local M = {}

local edit_state = require("opencode.edit.state")
local file_edit_results = require("opencode.ui.chat.file_edit_results")
local sync = require("opencode.sync")
local perf = require("opencode.perf")

local PREVIEW_TOOLS = {
	edit = true,
	apply_patch = true,
	neovim_edit = true,
	neovim_apply_patch = true,
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
---@return table files
---@return table statuses
local function model_to_edit_files(model)
	local files = {}
	local statuses = {}

	for _, file in ipairs(model.files or {}) do
		local diff = file.diff
		if not is_present(diff) then
			diff = file.proposedDiff
		end

		table.insert(files, {
			filePath = file.filePath,
			relativePath = file.relativePath,
			before = "",
			after = "",
			diff = diff,
			additions = file.additions,
			deletions = file.deletions,
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

	local files, statuses = model_to_edit_files(model)
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

	local done = perf.start("chat.edit_previews.sync_session")
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
	done({ session_id = session_id, created = created })
	return created
end

return M
