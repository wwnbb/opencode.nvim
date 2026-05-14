-- Dedicated read tool rendering for the chat buffer.

local M = {}

local render = require("opencode.ui.chat.render")

local function add_line(result, text, hl_group)
	text = render.sanitize_buffer_line(text)
	table.insert(result.lines, text)
	if hl_group then
		table.insert(result.highlights, {
			line = #result.lines - 1,
			col_start = 0,
			col_end = #text,
			hl_group = hl_group,
		})
	end
end

local function is_present(value)
	return value ~= nil and value ~= vim.NIL and tostring(value) ~= ""
end

local function basename(path)
	if not is_present(path) then
		return nil
	end
	path = tostring(path):gsub("[/\\]+$", "")
	return path:match("([^/\\]+)$") or path
end

local function get_input(tool_part)
	local state_input = tool_part and tool_part.state and tool_part.state.input
	if type(state_input) == "table" then
		return state_input
	end
	local part_input = tool_part and tool_part.input
	if type(part_input) == "table" then
		return part_input
	end
	return state_input or part_input or {}
end

local function get_read_path(input)
	if type(input) == "string" then
		return input
	end
	if type(input) ~= "table" then
		return nil
	end
	return input.filePath or input.file_path or input.filepath
end

local function get_status_parts(status)
	if status == "completed" then
		return "●", "Normal"
	elseif status == "running" then
		return "◐", "WarningMsg"
	elseif status == "error" then
		return "✗", "ErrorMsg"
	end
	return "○", "Comment"
end

local function append_text(result, value, hl_group)
	local text = type(value) == "string" and value or vim.inspect(value)
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		add_line(result, line, hl_group)
	end
end

local function append_error(result, err)
	local text = type(err) == "string" and err or vim.inspect(err)
	local lines = vim.split(text, "\n", { plain = true })
	if #lines == 0 then
		return
	end
	add_line(result, "Error: " .. lines[1], "ErrorMsg")
	for i = 2, #lines do
		add_line(result, lines[i], "ErrorMsg")
	end
end

local function append_loaded(result, metadata)
	local loaded = metadata and metadata.loaded
	if type(loaded) ~= "table" then
		return
	end
	for _, filepath in ipairs(loaded) do
		if type(filepath) == "string" and filepath ~= "" then
			add_line(result, "Loaded " .. filepath, "Comment")
		end
	end
end

---@param tool_part table
---@param is_expanded boolean
---@return table|nil result
function M.render_tool(tool_part, is_expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "read" then
		return nil
	end

	local tool_state = tool_part.state or {}
	local input = get_input(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	local status = tool_state.status or "pending"
	local status_symbol, status_hl = get_status_parts(status)
	local fold_icon = is_expanded and "▾" or "▸"
	local filename = basename(get_read_path(input)) or "unknown"
	local header = fold_icon .. " " .. status_symbol .. " Read " .. filename

	if type(input) == "table" then
		if is_present(input.offset) then
			header = header .. " offset=" .. tostring(input.offset)
		end
		if is_present(input.limit) then
			header = header .. " limit=" .. tostring(input.limit)
		end
	end

	local result = { lines = {}, highlights = {} }
	add_line(result, header, status_hl)

	if is_expanded then
		if tool_state.output ~= nil and tool_state.output ~= vim.NIL then
			append_text(result, tool_state.output, "Comment")
		end
		if tool_state.error ~= nil and tool_state.error ~= vim.NIL then
			append_error(result, tool_state.error)
		end
		if status == "completed" then
			append_loaded(result, metadata)
		end
	end

	return result
end

return M
