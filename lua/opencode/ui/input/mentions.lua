-- opencode.nvim - Input native @agent completion

local M = {}

local sync = require("opencode.sync")

local NS_MENTIONS = vim.api.nvim_create_namespace("opencode_input_mentions")

local COMPLETION_SOURCE = "opencode_agent_mention"
local COMPLETEOPT = "menuone,noselect,noinsert"

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function ensure_state(state)
	state.mentions = state.mentions or {}
	state.mentions.parts = state.mentions.parts or {}
	return state.mentions
end

local function set_completion_var(state, value)
	if valid_buf(state and state.bufnr) then
		pcall(vim.api.nvim_buf_set_var, state.bufnr, "completion", value == true)
	end
end

local function agent_name(agent)
	local name = type(agent) == "table" and (agent.name or agent.id) or nil
	return type(name) == "string" and name or ""
end

local function agent_description(agent)
	local description = type(agent) == "table" and agent.description or nil
	return type(description) == "string" and description or ""
end

local function last_plain_at(text)
	local last = nil
	local search_from = 1
	while true do
		local found = text:find("@", search_from, true)
		if not found then
			return last
		end
		last = found
		search_from = found + 1
	end
end

---@param line string
---@param col number 0-based byte column
---@return table|nil trigger
function M.detect_trigger_in_line(line, col)
	line = line or ""
	col = math.max(0, math.min(tonumber(col) or 0, #line))

	local before_cursor = line:sub(1, col)
	local at_idx = last_plain_at(before_cursor)
	if not at_idx then
		return nil
	end

	local query = before_cursor:sub(at_idx + 1)
	if query:find("%s") then
		return nil
	end

	if at_idx > 1 then
		local previous_byte = before_cursor:sub(at_idx - 1, at_idx - 1)
		if not previous_byte:match("%s") then
			return nil
		end
	end

	return {
		start_col = at_idx - 1,
		end_col = col,
		query = query,
		value = before_cursor:sub(at_idx),
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
	local trigger = M.detect_trigger_in_line(line, col)
	if not trigger then
		return nil
	end

	trigger.row = row
	trigger.line = line
	return trigger
end

---@param agents table[]|nil
---@param query string|nil
---@return table[]
function M.filter_agents(agents, query)
	local filtered = {}
	local needle = tostring(query or ""):lower()

	for _, agent in ipairs(agents or {}) do
		if sync.is_mentionable_agent(agent) then
			local name = agent_name(agent)
			local description = agent_description(agent)
			local include = needle == ""
				or name:lower():find(needle, 1, true) ~= nil
				or description:lower():find(needle, 1, true) ~= nil

			if include then
				table.insert(filtered, agent)
			end
		end
	end

	return filtered
end

function M.setup_highlights()
	vim.api.nvim_set_hl(0, "OpenCodeInputMentionName", { link = "OpenCodeInputAgent", default = true })
end

function M.enable_native_complete(state)
	local mention_state = ensure_state(state)
	if mention_state.completeopt_restore == nil then
		mention_state.completeopt_restore = vim.o.completeopt
	end
	vim.o.completeopt = COMPLETEOPT
end

function M.restore_native_complete(state)
	local mention_state = state and state.mentions
	if mention_state and mention_state.completeopt_restore ~= nil then
		vim.o.completeopt = mention_state.completeopt_restore
		mention_state.completeopt_restore = nil
	end
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

local function completion_user_data(agent)
	return vim.json.encode({
		source = COMPLETION_SOURCE,
		name = agent_name(agent),
	})
end

local function completion_items(agents)
	local items = {}
	for _, agent in ipairs(agents or {}) do
		local name = agent_name(agent)
		if name ~= "" then
			local description = agent_description(agent)
			table.insert(items, {
				word = "@" .. name,
				abbr = "@" .. name,
				kind = "Agent",
				menu = description,
				info = description,
				dup = 1,
				user_data = completion_user_data(agent),
			})
		end
	end
	return items
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

	local items = completion_items(M.filter_agents(sync.get_mentionable_agents(), trigger.query))
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

local function mark_completed_mention(state, item)
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

	local end_col = col
	local extmark_id = vim.api.nvim_buf_set_extmark(state.bufnr, NS_MENTIONS, row, start_col, {
		end_row = row,
		end_col = end_col,
		right_gravity = false,
		end_right_gravity = false,
		invalidate = true,
		hl_group = "OpenCodeInputMentionName",
	})

	table.insert(ensure_state(state).parts, {
		type = "agent",
		name = item.name,
		source = {
			start = 0,
			["end"] = 0,
			value = item.word,
		},
		_mention = {
			extmark_id = extmark_id,
			value = item.word,
		},
	})

	if char_after(line, end_col):match("%s") then
		return true
	end

	vim.api.nvim_buf_set_text(state.bufnr, row, end_col, row, end_col, { " " })
	vim.api.nvim_win_set_cursor(state.winid, { row + 1, end_col + 1 })
	return true
end

function M.complete_done(state)
	set_completion_var(state, false)

	local item = decoded_completion_item()
	if not item then
		return false
	end
	return mark_completed_mention(state, item)
end

local function position_to_offset(lines, row, col)
	local offset = 0
	for idx = 1, row do
		offset = offset + #(lines[idx] or "") + 1
	end
	return offset + col
end

local function extmark_part(state, stored, lines)
	local mention = stored._mention
	if type(mention) ~= "table" or not mention.extmark_id then
		return nil
	end

	local pos = vim.api.nvim_buf_get_extmark_by_id(state.bufnr, NS_MENTIONS, mention.extmark_id, { details = true })
	if not pos or #pos < 3 then
		return nil
	end

	local row, col, details = pos[1], pos[2], pos[3] or {}
	if details.invalid or details.end_row == nil or details.end_col == nil then
		return nil
	end

	local ok, text_lines = pcall(
		vim.api.nvim_buf_get_text,
		state.bufnr,
		row,
		col,
		details.end_row,
		details.end_col,
		{}
	)
	if not ok then
		return nil
	end

	local value = table.concat(text_lines, "\n")
	if value ~= mention.value then
		return nil
	end

	local start_offset = position_to_offset(lines, row, col)
	local end_offset = position_to_offset(lines, details.end_row, details.end_col)
	return {
		type = "agent",
		name = stored.name,
		source = {
			start = start_offset,
			["end"] = end_offset,
			value = value,
		},
	}
end

---@param state table
---@return table[]
function M.active_parts(state)
	local active = {}
	local mention_state = state and state.mentions
	if not mention_state or not valid_buf(state.bufnr) then
		return active
	end

	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	for _, stored in ipairs(mention_state.parts or {}) do
		local part = extmark_part(state, stored, lines)
		if part then
			table.insert(active, part)
		end
	end
	table.sort(active, function(a, b)
		return (a.source and a.source.start or 0) < (b.source and b.source.start or 0)
	end)
	return active
end

---@param state table
---@param trigger table
---@param agent table
---@return boolean
function M.insert_mention(state, trigger, agent)
	if not valid_buf(state and state.bufnr) or not valid_win(state.winid) then
		return false
	end
	if type(trigger) ~= "table" or type(agent) ~= "table" then
		return false
	end

	local name = agent_name(agent)
	if name == "" then
		return false
	end

	local row = trigger.row or (vim.api.nvim_win_get_cursor(state.winid)[1] - 1)
	local line = vim.api.nvim_buf_get_lines(state.bufnr, row, row + 1, false)[1] or ""
	local mention_value = "@" .. name
	local suffix = char_after(line, trigger.end_col):match("%s") and "" or " "
	local inserted = mention_value .. suffix

	vim.api.nvim_buf_set_text(state.bufnr, row, trigger.start_col, row, trigger.end_col, { inserted })
	vim.api.nvim_win_set_cursor(state.winid, { row + 1, trigger.start_col + #mention_value })
	local ok = mark_completed_mention(state, {
		word = mention_value,
		name = name,
	})
	if ok and suffix ~= "" then
		vim.api.nvim_win_set_cursor(state.winid, { row + 1, trigger.start_col + #inserted })
	end
	return ok
end

function M.clear(state)
	close_native_menu(state)
	if state then
		M.restore_native_complete(state)
		state.mentions = {
			parts = {},
		}
	end
end

function M.reset(state)
	close_native_menu(state)
	if state then
		local mention_state = ensure_state(state)
		state.mentions = {
			parts = {},
			completeopt_restore = mention_state.completeopt_restore,
		}
	end
end

return M
