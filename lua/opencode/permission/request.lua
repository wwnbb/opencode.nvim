-- opencode.nvim - Permission request projection
-- What a native permission request asks for, in display form. No rendering.

local M = {}

local text = require("opencode.util.text")
local tool_names = require("opencode.util.tool_names")

-- Permission types whose request is a shell command: native "shell" and the bash tool's own "bash".
local SHELL_TYPES = { bash = true, shell = true }

local TOOL_INPUT_FIELDS = {
	"command",
	"description",
	"workdir",
	"cwd",
	"directory",
	"parentDir",
	"path",
	"file_path",
	"filePath",
	"filepath",
	"file",
	"pattern",
	"type",
	"glob",
	"query",
	"url",
	"subagent_type",
	"subagentType",
}

local TITLES = {
	external_directory = "External directory",
	diff_review = "Diff review",
	doom_loop = "Continue after repeated failures",
}

---@param ... any
---@return string
local function first_non_empty(...)
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if type(value) == "string" and value ~= "" then
			return value
		end
	end
	return ""
end

---@param value any
---@return table|nil
local function as_table(value)
	if type(value) == "table" then
		return value
	end
	if type(value) == "string" and value ~= "" then
		local ok, decoded = pcall(vim.json.decode, value)
		if ok and type(decoded) == "table" then
			return decoded
		end
	end
	return nil
end

---@param part table
---@return table
local function tool_metadata(part)
	local tool_state = type(part.state) == "table" and part.state or {}
	return vim.tbl_deep_extend("force", {},
		type(part.metadata) == "table" and part.metadata or {},
		type(tool_state.metadata) == "table" and tool_state.metadata or {})
end

---@param dest table
---@param key string
---@param value any
local function set_non_empty(dest, key, value)
	if value ~= nil and value ~= "" then
		dest[key] = value
	end
end

---@param dest table
---@param source table|nil
local function merge_tool_input(dest, source)
	source = as_table(source)
	if not source then
		return
	end
	for _, key in ipairs(TOOL_INPUT_FIELDS) do
		set_non_empty(dest, key, source[key])
	end
	set_non_empty(dest, "directory", source.directory or source.parentDir)
	set_non_empty(dest, "subagent_type", source.subagent_type or source.subagentType)
end

---@param part table
---@param call_id string
---@return boolean
local function part_matches_call(part, call_id)
	return (part.callID or part.call_id or part.callId) == call_id
end

---The tool part that made the request, from the sync store.
---@param perm_state table
---@return table|nil
local function find_tool_part(perm_state)
	local message_id, call_id = perm_state.message_id, perm_state.call_id
	if type(message_id) ~= "string" or message_id == "" or type(call_id) ~= "string" or call_id == "" then
		return nil
	end
	local ok, sync = pcall(require, "opencode.sync")
	if not ok or type(sync.get_parts) ~= "function" then
		return nil
	end
	for _, part in ipairs(sync.get_parts(message_id)) do
		if part_matches_call(part, call_id) then
			return part
		end
	end
	return nil
end

---The request's tool input, refreshed from its tool part when that is known.
---@param perm_state table
---@param part table|nil
---@return table
local function resolve_tool_input(perm_state, part)
	local input = vim.deepcopy(type(perm_state.tool_input) == "table" and perm_state.tool_input or {})
	if part then
		merge_tool_input(input, tool_metadata(part))
		merge_tool_input(input, type(part.state) == "table" and part.state.input or nil)
	end
	return input
end

---@param perm_state table
---@param part table|nil
---@return string
local function resolve_tool_name(perm_state, part)
	local metadata = type(perm_state.metadata) == "table" and perm_state.metadata or {}
	local name = first_non_empty(perm_state.tool_name, metadata.tool, metadata.tool_name, metadata.toolName)
	if name ~= "" or type(part) ~= "table" then
		return name
	end
	local tool_state = type(part.state) == "table" and part.state or {}
	local part_metadata = tool_metadata(part)
	return first_non_empty(part.tool, part.tool_name, part.toolName, tool_state.tool, tool_state.tool_name,
		tool_state.toolName, part_metadata.tool, part_metadata.tool_name, part_metadata.toolName)
end

---A path as every widget shows it (util/text.normalize_path).
---@param filepath string
---@return string
function M.display_path(filepath)
	return text.normalize_path(filepath)
end

---Working directory of a shell request, or "" when it runs in the current directory.
---@param input table
---@param metadata table
---@return string
local function shell_workdir(input, metadata)
	local workdir = M.display_path(first_non_empty(input.workdir, input.cwd, input.directory, input.path,
		metadata.workdir, metadata.cwd, metadata.directory, metadata.path))
	return workdir ~= M.display_path(vim.fn.getcwd()) and workdir or ""
end

---@param permission_type string
---@param input table
---@param metadata table
---@param patterns string[]
---@return string
local function request_path(permission_type, input, metadata, patterns)
	local path
	if permission_type == "read" then
		path = first_non_empty(input.file_path, input.filePath, input.filepath, input.file, input.path, input.pattern,
			metadata.file_path, metadata.filePath, metadata.filepath, metadata.file, metadata.path, metadata.pattern,
			patterns[1])
	elseif permission_type == "glob" or permission_type == "grep" or permission_type == "rg" or permission_type == "list" then
		path = first_non_empty(input.path, metadata.path, input.directory, metadata.directory, vim.fn.getcwd())
	elseif permission_type == "external_directory" then
		path = first_non_empty(input.file_path, input.filePath, input.filepath, input.file,
			metadata.file_path, metadata.filePath, metadata.filepath, metadata.file,
			input.directory, input.path, metadata.directory, metadata.parentDir, metadata.path, patterns[1])
	else
		path = first_non_empty(input.file_path, input.filePath, input.filepath, input.file, input.path, input.directory,
			metadata.file_path, metadata.filePath, metadata.filepath, metadata.file, metadata.path, metadata.directory,
			patterns[1])
	end
	return M.display_path(path)
end

---@param values any
---@param shell boolean Values are shell commands, kept verbatim
---@return string[]
local function display_values(values, shell)
	local out = {}
	for _, value in ipairs(type(values) == "table" and values or {}) do
		if type(value) == "string" and vim.trim(value) ~= "" then
			out[#out + 1] = shell and value or M.display_path(value)
		end
	end
	return out
end

---@class OpenCodePermissionDetail
---@field label string
---@field value string

---@class OpenCodePermissionRequest
---@field type string Native permission type
---@field title string Display name of the permission
---@field tool string Display name of the tool that asked, or ""
---@field own boolean The asking tool's own permission (a shell request from bash included)
---@field shell boolean Shell request: the command is the requested resource
---@field command string Command the request runs, or ""
---@field details OpenCodePermissionDetail[]
---@field resources string[] Requested authorization resources
---@field always string[] Patterns an "always" reply saves
---@field message string Message attached to the reply, or ""

---@param permission_type any
---@return boolean
function M.is_shell(permission_type)
	return SHELL_TYPES[permission_type] == true
end

---Describe a permission request; never mutates the permission state.
---@param perm_state table Permission state from permission/state.lua
---@return OpenCodePermissionRequest
function M.describe(perm_state)
	local permission_type = perm_state.permission_type or ""
	local part = find_tool_part(perm_state)
	local input = resolve_tool_input(perm_state, part)
	local metadata = type(perm_state.metadata) == "table" and perm_state.metadata or {}
	local shell = M.is_shell(permission_type)
	local tool_name = vim.trim(resolve_tool_name(perm_state, part)):lower()
	local request = {
		type = permission_type,
		title = TITLES[permission_type] or tool_names.display_name(permission_type),
		tool = tool_names.display_name(tool_name),
		own = tool_name ~= "" and (tool_name == permission_type or (shell and tool_name == "bash")),
		shell = shell,
		command = "",
		details = {},
		resources = display_values(perm_state.patterns, shell),
		always = display_values(perm_state.always, shell),
		message = vim.trim(first_non_empty(perm_state.message)),
	}
	if permission_type == "diff_review" or permission_type == "doom_loop" then
		return request
	end

	local function add(label, value)
		if type(value) == "string" and value ~= "" then
			table.insert(request.details, { label = label, value = value })
		end
	end
	request.command = vim.trim(first_non_empty(input.command))
	add("Path", shell and shell_workdir(input, metadata)
		or request_path(permission_type, input, metadata, perm_state.patterns or {}))
	add("Pattern", input.pattern)
	add("Type", input.type)
	add("Glob", input.glob)
	add("Query", input.query)
	add("URL", input.url)
	add("Agent", input.subagent_type)
	add("Description", input.description)
	if permission_type == "bash" and request.command == "" and #request.details == 0 then
		add("Description", "Run bash command")
	end
	return request
end

return M
