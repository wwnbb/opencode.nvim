local M = {}

---@param filepath string
---@return string
local function read_file(filepath)
	local file = io.open(filepath, "r")
	if not file then
		return ""
	end
	local content = file:read("*all") or ""
	file:close()
	return content
end

---@param input any
---@return table|nil
local function decode_input(input)
	if type(input) == "string" then
		local ok, parsed = pcall(vim.json.decode, input)
		if ok and type(parsed) == "table" then
			return parsed
		end
	end
	if type(input) == "table" then
		return input
	end
	return nil
end

---@param tool_name string
---@return boolean
local function is_edit_tool(tool_name)
	if tool_name == "neovim_edit" or tool_name == "neovim_apply_patch" then
		return false
	end

	local lowered = tool_name:lower()
	return tool_name == "edit_file"
		or tool_name == "write_file"
		or tool_name == "apply_patch"
		or lowered == "edit"
		or lowered == "write"
		or lowered:find("edit", 1, true) ~= nil
		or lowered:find("patch", 1, true) ~= nil
end

---@param input table
---@param original string
---@return string
local function proposed_content(input, original)
	local old_string = type(input.old_string) == "string" and input.old_string or ""
	if old_string ~= "" and type(input.new_string) == "string" then
		return original:gsub(vim.pesc(old_string), input.new_string, 1)
	end
	return input.new_string or input.content or input.modified or ""
end

---@param data table|nil
---@param logger table
function M.handle_tool_update(data, logger)
	if type(data) ~= "table" then
		return
	end

	local tool_name = data.tool_name or ""
	local status = data.status or ""
	logger.debug("tool_update event", {
		tool = tool_name,
		status = status,
		data = data,
	})

	local needs_review = status == "pending" or status == "running" or status == ""
	if not is_edit_tool(tool_name) or not needs_review then
		return
	end

	local input = decode_input(data.input)
	if not input then
		return
	end

	local filepath = input.file_path or input.filepath or input.path or input.file
	if not filepath then
		return
	end

	local original = vim.fn.filereadable(filepath) == 1 and read_file(filepath) or ""
	local modified = proposed_content(input, original)
	if modified == "" or modified == original then
		return
	end

	require("opencode.artifact.changes").add_change(filepath, original, modified, {
		metadata = {
			source = "tool_call",
			tool_name = tool_name,
			call_id = data.call_id or data.callID,
			message_id = data.message_id or data.messageID,
		},
	})
end

---@param data table|nil
function M.handle_edit(data)
	if type(data) ~= "table" then
		return
	end

	local filepath = data.file or data.filepath or data.file_path
	local original = data.original or data.original_content or ""
	local modified = data.modified or data.modified_content or data.content or ""

	if not filepath then
		vim.notify("Edit event missing filepath", vim.log.levels.WARN)
		return
	end

	if original == "" and vim.fn.filereadable(filepath) == 1 then
		original = read_file(filepath)
	end

	if modified == "" then
		vim.notify("File edited: " .. filepath, vim.log.levels.INFO)
		return
	end

	local change_id = require("opencode.artifact.changes").add_change(filepath, original, modified, {
		metadata = {
			source = "server",
			session_id = data.sessionID or data.session_id,
		},
	})
	if not change_id then
		vim.notify("Failed to create change record for: " .. filepath, vim.log.levels.ERROR)
	end
end

---@param data table|nil
function M.handle_session_diff(data)
	if type(data) ~= "table" then
		return
	end

	local diffs = data.diffs or { data }
	for _, diff_data in ipairs(diffs) do
		local filepath = diff_data.file or diff_data.filepath or diff_data.file_path
		local original = diff_data.original or ""
		local modified = diff_data.modified or diff_data.content or ""

		if filepath and modified ~= "" then
			if original == "" and vim.fn.filereadable(filepath) == 1 then
				original = read_file(filepath)
			end

			require("opencode.artifact.changes").add_change(filepath, original, modified, {
				metadata = {
					source = "session_diff",
					session_id = data.sessionID or data.session_id,
				},
			})
		end
	end
end

return M
