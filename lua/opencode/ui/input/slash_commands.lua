-- opencode.nvim - Input native /command completion

local M = {}

local slash = require("opencode.slash")

local COMPLETION_SOURCE = "opencode_slash_command"

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function ensure_state(state)
	state.slash_commands = state.slash_commands or {}
	return state.slash_commands
end

local function set_completion_var(state, value)
	if valid_buf(state and state.bufnr) then
		pcall(vim.api.nvim_buf_set_var, state.bufnr, "completion", value == true)
	end
end

local function command_name(command)
	local name = type(command) == "table" and command.name or nil
	return type(name) == "string" and name or ""
end

local function command_description(command)
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

local function detect_trigger(state)
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

	local name = command_name(command):lower()
	if name:find(needle, 1, true) ~= nil then
		return true
	end

	local description = command_description(command):lower()
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
		if command_name(command) ~= "" and matches_command(command, needle) then
			table.insert(filtered, command)
		end
	end

	return filtered
end

local function completion_user_data(command)
	return vim.json.encode({
		source = COMPLETION_SOURCE,
		name = command_name(command),
	})
end

local function completion_items(commands)
	local items = {}
	for _, command in ipairs(commands or {}) do
		local name = command_name(command)
		if name ~= "" then
			table.insert(items, {
				word = "/" .. name,
				abbr = "/" .. name,
				dup = 1,
				user_data = completion_user_data(command),
			})
		end
	end
	return items
end

local function close_native_menu(state)
	set_completion_var(state, false)
	if vim.fn.mode():sub(1, 1) == "i" and vim.fn.pumvisible() == 1 then
		local keys = vim.api.nvim_replace_termcodes("<C-e>", true, false, true)
		vim.api.nvim_feedkeys(keys, "n", false)
	end
end

function M.close_completion(state)
	close_native_menu(state)
end

---@param state table
---@return boolean opened
function M.refresh(state)
	if not state or not state.visible then
		close_native_menu(state)
		return false
	end
	if vim.fn.mode():sub(1, 1) ~= "i" then
		close_native_menu(state)
		return false
	end

	local trigger = detect_trigger(state)
	if not trigger then
		close_native_menu(state)
		return false
	end

	local items = completion_items(M.filter_commands(slash.get_commands(), trigger.query))
	if #items == 0 then
		close_native_menu(state)
		return false
	end

	ensure_state(state).trigger = trigger
	set_completion_var(state, true)
	pcall(vim.fn.complete, trigger.start_col + 1, items)
	return true
end

local function decoded_completion_item()
	local item = vim.v.completed_item
	if type(item) ~= "table" or item.word == nil or item.word == "" then
		return nil
	end

	local ok, data = pcall(vim.json.decode, item.user_data or "")
	if not ok or type(data) ~= "table" or data.source ~= COMPLETION_SOURCE then
		return nil
	end
	if type(data.name) ~= "string" or data.name == "" then
		return nil
	end

	return {
		word = tostring(item.word),
		name = data.name,
	}
end

local function char_after(line, col)
	if col >= #line then
		return ""
	end
	return line:sub(col + 1, col + 1)
end

local function append_trailing_space(state, item)
	if not valid_buf(state and state.bufnr) or not valid_win(state.winid) then
		return false
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local row = cursor[1] - 1
	local col = cursor[2]
	local line = vim.api.nvim_buf_get_lines(state.bufnr, row, row + 1, false)[1] or ""
	local start_col = col - #item.word
	if start_col < 0 or line:sub(start_col + 1, col) ~= item.word then
		return false
	end

	if char_after(line, col):match("%s") then
		return true
	end

	vim.api.nvim_buf_set_text(state.bufnr, row, col, row, col, { " " })
	vim.api.nvim_win_set_cursor(state.winid, { row + 1, col + 1 })
	return true
end

function M.complete_done(state)
	set_completion_var(state, false)

	local item = decoded_completion_item()
	if not item then
		return false
	end

	append_trailing_space(state, item)
	return true
end

function M.clear(state)
	close_native_menu(state)
	if state then
		state.slash_commands = nil
	end
end

function M.reset(state)
	close_native_menu(state)
	if state then
		state.slash_commands = {}
	end
end

return M
