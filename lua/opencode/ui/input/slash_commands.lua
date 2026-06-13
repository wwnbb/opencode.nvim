-- opencode.nvim - Input /command completion support

local M = {}

local slash = require("opencode.slash")

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

function M.command_name(command)
	local name = type(command) == "table" and command.name or nil
	return type(name) == "string" and name or ""
end

function M.command_description(command)
	local description = type(command) == "table" and command.description or nil
	return type(description) == "string" and description or ""
end

local function command_aliases(command)
	local aliases = type(command) == "table" and command.aliases or nil
	return type(aliases) == "table" and aliases or {}
end

---@param line string
---@param col number 0-based byte column
---@param row? number 0-based row
---@return table|nil trigger
function M.detect_trigger_in_line(line, col, row)
	if row ~= nil and row ~= 0 then
		return nil
	end

	line = line or ""
	col = math.max(0, math.min(tonumber(col) or 0, #line))

	local before_cursor = line:sub(1, col)
	if before_cursor == "" or not before_cursor:match("^/%S*$") then
		return nil
	end

	return {
		start_col = 0,
		end_col = col,
		query = before_cursor:sub(2),
		value = before_cursor,
	}
end

function M.detect_trigger(state)
	if not valid_buf(state and state.bufnr) or not valid_win(state.winid) then
		return nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local row = cursor[1] - 1
	local col = cursor[2]
	local line = vim.api.nvim_buf_get_lines(state.bufnr, row, row + 1, false)[1] or ""
	local trigger = M.detect_trigger_in_line(line, col, row)
	if not trigger then
		return nil
	end

	trigger.row = row
	trigger.line = line
	return trigger
end

local function matches_command(command, needle)
	if needle == "" then
		return true
	end

	local name = M.command_name(command):lower()
	if name:find(needle, 1, true) ~= nil then
		return true
	end

	local description = M.command_description(command):lower()
	if description:find(needle, 1, true) ~= nil then
		return true
	end

	for _, alias in ipairs(command_aliases(command)) do
		if type(alias) == "string" and alias:lower():find(needle, 1, true) ~= nil then
			return true
		end
	end

	return false
end

---@param commands table[]|nil
---@param query string|nil
---@return table[]
function M.filter_commands(commands, query)
	local filtered = {}
	local needle = tostring(query or ""):lower()

	for _, command in ipairs(commands or {}) do
		if M.command_name(command) ~= "" and matches_command(command, needle) then
			table.insert(filtered, command)
		end
	end

	return filtered
end

function M.available_commands(query)
	return M.filter_commands(slash.get_commands(), query)
end

local function char_after(line, col)
	if col >= #line then
		return ""
	end
	return line:sub(col + 1, col + 1)
end

function M.insert_command(state, trigger, command)
	if not valid_buf(state and state.bufnr) or not valid_win(state.winid) then
		return false
	end
	if type(trigger) ~= "table" or type(command) ~= "table" then
		return false
	end

	local name = M.command_name(command)
	if name == "" then
		return false
	end

	local row = trigger.row or (vim.api.nvim_win_get_cursor(state.winid)[1] - 1)
	local line = vim.api.nvim_buf_get_lines(state.bufnr, row, row + 1, false)[1] or ""
	local command_value = "/" .. name
	local suffix = char_after(line, trigger.end_col):match("%s") and "" or " "
	local inserted = command_value .. suffix

	vim.api.nvim_buf_set_text(state.bufnr, row, trigger.start_col, row, trigger.end_col, { inserted })
	vim.api.nvim_win_set_cursor(state.winid, { row + 1, trigger.start_col + #inserted })
	return true
end

function M.clear(state)
	if state then
		state.slash_commands = nil
	end
end

function M.reset(state)
	if state then
		state.slash_commands = {}
	end
end

return M
