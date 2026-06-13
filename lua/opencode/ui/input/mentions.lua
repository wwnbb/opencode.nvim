-- opencode.nvim - Input @agent mention support

local M = {}

local sync = require("opencode.sync")

local NS_MENTIONS = vim.api.nvim_create_namespace("opencode_input_mentions")

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

function M.agent_name(agent)
	local name = type(agent) == "table" and (agent.name or agent.id) or nil
	return type(name) == "string" and name or ""
end

function M.agent_description(agent)
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

function M.detect_trigger(state)
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
			local name = M.agent_name(agent)
			local description = M.agent_description(agent)
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

	local name = M.agent_name(agent)
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
	if state then
		state.mentions = {
			parts = {},
		}
	end
end

function M.reset(state)
	if state then
		state.mentions = {
			parts = {},
		}
	end
end

return M
