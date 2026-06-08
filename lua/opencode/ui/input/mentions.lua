-- opencode.nvim - Input @agent mentions

local M = {}

local sync = require("opencode.sync")

local NS_MENTIONS = vim.api.nvim_create_namespace("opencode_input_mentions")
local NS_POPUP = vim.api.nvim_create_namespace("opencode_input_mentions_popup")

local MAX_VISIBLE_ITEMS = 8
local MIN_POPUP_WIDTH = 24
local MAX_POPUP_WIDTH = 72

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function ensure_state(state)
	state.mentions = state.mentions or {}
	state.mentions.parts = state.mentions.parts or {}
	state.mentions.items = state.mentions.items or {}
	state.mentions.selected = state.mentions.selected or 1
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

local function display_width(text)
	return vim.fn.strdisplaywidth(tostring(text or ""))
end

local function truncate_to_width(text, width)
	text = tostring(text or "")
	if width <= 0 then
		return ""
	end
	if display_width(text) <= width then
		return text
	end

	local suffix = width > 3 and "..." or ""
	local target = math.max(1, width - #suffix)
	local result = ""
	for i = 1, vim.fn.strchars(text) do
		local next_result = vim.fn.strcharpart(text, 0, i)
		if display_width(next_result) > target then
			break
		end
		result = next_result
	end
	return result .. suffix
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

local function close_popup(state)
	local mention_state = state and state.mentions
	if not mention_state then
		return false
	end

	local was_open = valid_win(mention_state.popup_win)
	if was_open then
		pcall(vim.api.nvim_win_close, mention_state.popup_win, true)
	end
	if valid_buf(mention_state.popup_buf) then
		pcall(vim.api.nvim_buf_delete, mention_state.popup_buf, { force = true })
	end

	mention_state.popup_win = nil
	mention_state.popup_buf = nil
	mention_state.items = {}
	mention_state.trigger = nil
	mention_state.selected = 1
	set_completion_var(state, false)
	return was_open
end

function M.close_popup(state)
	return close_popup(state)
end

function M.is_popup_visible(state)
	local mention_state = state and state.mentions
	return mention_state ~= nil and valid_win(mention_state.popup_win)
end

function M.setup_highlights()
	vim.api.nvim_set_hl(0, "OpenCodeInputMentionSelected", { link = "CursorLine", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputMentionName", { link = "OpenCodeInputAgent", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputMentionDescription", { link = "Comment", default = true })
end

local function popup_width(items)
	local width = MIN_POPUP_WIDTH
	for _, agent in ipairs(items or {}) do
		local line = "  @" .. agent_name(agent)
		local description = agent_description(agent)
		if description ~= "" then
			line = line .. "  " .. description
		end
		width = math.max(width, display_width(line))
	end
	return math.min(MAX_POPUP_WIDTH, width)
end

local function visible_window(items, selected)
	local count = #items
	if count <= MAX_VISIBLE_ITEMS then
		return 1, count
	end

	local first = selected - math.floor(MAX_VISIBLE_ITEMS / 2)
	first = math.max(1, first)
	first = math.min(first, count - MAX_VISIBLE_ITEMS + 1)
	return first, first + MAX_VISIBLE_ITEMS - 1
end

local function format_agent_line(agent, selected, width)
	local name = "@" .. agent_name(agent)
	local prefix = selected and "> " or "  "
	local left = prefix .. name
	local description = agent_description(agent)

	if description == "" then
		return truncate_to_width(left, width)
	end

	local desc_width = display_width(description)
	local left_width = width - desc_width - 2
	if left_width <= display_width(prefix) + 4 then
		return truncate_to_width(left, width)
	end

	left = truncate_to_width(left, left_width)
	local padding = math.max(2, width - display_width(left) - desc_width)
	return left .. string.rep(" ", padding) .. description
end

local function popup_lines(items, selected, width, has_agents)
	if #items == 0 then
		local message = has_agents and "No matching agents" or "No mentionable agents"
		return { truncate_to_width("  " .. message, width) }
	end

	local first, last = visible_window(items, selected)
	local lines = {}
	for idx = first, last do
		table.insert(lines, format_agent_line(items[idx], idx == selected, width))
	end
	return lines
end

local function popup_position(state, trigger, width, height)
	local win_pos = vim.api.nvim_win_get_position(state.winid)
	local line = trigger.line or ""
	local prefix = line:sub(1, trigger.start_col)
	local col = win_pos[2] + display_width(prefix)
	local total_width = width + 2

	if col + total_width > vim.o.columns then
		col = math.max(0, vim.o.columns - total_width)
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local total_height = height + 2
	local max_row = math.max(0, vim.o.lines - total_height - 2)
	local above = win_pos[1] + cursor[1] - total_height
	local below = win_pos[1] + cursor[1]
	local row = above >= 0 and above or below

	return math.max(0, math.min(row, max_row)), math.max(0, col)
end

local function ensure_popup(state, width, height, trigger)
	local mention_state = ensure_state(state)
	local row, col = popup_position(state, trigger, width, height)
	local config = {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "single",
		focusable = false,
		zindex = 60,
	}

	if valid_win(mention_state.popup_win) and valid_buf(mention_state.popup_buf) then
		vim.api.nvim_win_set_config(mention_state.popup_win, config)
		return mention_state.popup_buf
	end

	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false

	local winid = vim.api.nvim_open_win(bufnr, false, config)
	vim.wo[winid].wrap = false
	vim.wo[winid].cursorline = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].winhighlight =
		"Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg,FloatBorder:OpenCodeInputBorderAgent"

	mention_state.popup_buf = bufnr
	mention_state.popup_win = winid
	return bufnr
end

local function mark_popup_lines(bufnr, lines, items, selected)
	vim.api.nvim_buf_clear_namespace(bufnr, NS_POPUP, 0, -1)
	if #items == 0 then
		vim.api.nvim_buf_add_highlight(bufnr, NS_POPUP, "OpenCodeInputMentionDescription", 0, 0, -1)
		return
	end

	local first = visible_window(items, selected)
	for line_idx, line in ipairs(lines) do
		local item_idx = first + line_idx - 1
		local agent = items[item_idx]
		if item_idx == selected then
			vim.api.nvim_buf_add_highlight(bufnr, NS_POPUP, "OpenCodeInputMentionSelected", line_idx - 1, 0, -1)
		end

		local name = "@" .. agent_name(agent)
		local start_col = line:find(name, 1, true)
		if start_col then
			vim.api.nvim_buf_add_highlight(
				bufnr,
				NS_POPUP,
				"OpenCodeInputMentionName",
				line_idx - 1,
				start_col - 1,
				start_col - 1 + #name
			)
		end
	end
end

local function render_popup(state)
	local mention_state = ensure_state(state)
	local trigger = mention_state.trigger
	if not trigger then
		close_popup(state)
		return
	end

	local items = mention_state.items or {}
	local has_agents = #(sync.get_mentionable_agents() or {}) > 0
	local width = popup_width(items)
	local height = math.max(1, math.min(#items, MAX_VISIBLE_ITEMS))
	local lines = popup_lines(items, mention_state.selected or 1, width, has_agents)
	height = #lines

	local bufnr = ensure_popup(state, width, height, trigger)
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false
	mark_popup_lines(bufnr, lines, items, mention_state.selected or 1)
	set_completion_var(state, true)
end

function M.refresh(state)
	if not state or not state.visible then
		close_popup(state)
		return false
	end

	local trigger = detect_trigger(state)
	if not trigger then
		close_popup(state)
		return false
	end

	local mention_state = ensure_state(state)
	local previous = mention_state.items and mention_state.items[mention_state.selected]
	local previous_name = previous and agent_name(previous) or nil
	local items = M.filter_agents(sync.get_mentionable_agents(), trigger.query)

	mention_state.trigger = trigger
	mention_state.items = items
	mention_state.selected = 1
	if previous_name then
		for idx, agent in ipairs(items) do
			if agent_name(agent) == previous_name then
				mention_state.selected = idx
				break
			end
		end
	end

	render_popup(state)
	return true
end

function M.move_selection(state, delta)
	local mention_state = ensure_state(state)
	if not valid_win(mention_state.popup_win) then
		return false
	end

	local count = #(mention_state.items or {})
	if count == 0 then
		return true
	end

	mention_state.selected = ((mention_state.selected - 1 + delta) % count) + 1
	render_popup(state)
	return true
end

local function char_after(line, col)
	if col >= #line then
		return ""
	end
	return line:sub(col + 1, col + 1)
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

	local end_col = trigger.start_col + #mention_value
	local extmark_id = vim.api.nvim_buf_set_extmark(state.bufnr, NS_MENTIONS, row, trigger.start_col, {
		end_row = row,
		end_col = end_col,
		right_gravity = false,
		end_right_gravity = false,
		invalidate = true,
		hl_group = "OpenCodeInputMentionName",
	})

	table.insert(ensure_state(state).parts, {
		type = "agent",
		name = name,
		source = {
			start = 0,
			["end"] = 0,
			value = mention_value,
		},
		_mention = {
			extmark_id = extmark_id,
			value = mention_value,
		},
	})

	vim.api.nvim_win_set_cursor(state.winid, { row + 1, trigger.start_col + #inserted })
	return true
end

function M.select_current(state)
	local mention_state = ensure_state(state)
	if not valid_win(mention_state.popup_win) then
		return false
	end

	local agent = mention_state.items and mention_state.items[mention_state.selected]
	if not agent then
		return true
	end

	local trigger = mention_state.trigger or detect_trigger(state)
	if not trigger then
		close_popup(state)
		return true
	end

	local ok = M.insert_mention(state, trigger, agent)
	close_popup(state)
	return ok or true
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

function M.clear(state)
	close_popup(state)
	if state then
		state.mentions = {
			parts = {},
			items = {},
			selected = 1,
		}
	end
end

return M
