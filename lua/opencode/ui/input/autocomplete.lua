-- opencode.nvim - Input autocomplete popup

local M = {}

local mentions = require("opencode.ui.input.mentions")
local slash_commands = require("opencode.ui.input.slash_commands")
local sync = require("opencode.sync")

local NS = vim.api.nvim_create_namespace("opencode_input_autocomplete")
local MAX_ITEMS = 10
local LABEL_GAP = 2
local SPLIT_BORDER = { "", "", "", "", "", "", "", "┃" }
local BORDER_PADDING = { top = 0, bottom = 0, left = 1, right = 1 }

local function valid_buf(bufnr)
	return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function valid_win(winid)
	return winid and vim.api.nvim_win_is_valid(winid)
end

local function ensure_state(state)
	state.autocomplete = state.autocomplete or {}
	return state.autocomplete
end

function M.setup_highlights()
	local ok, comment = pcall(vim.api.nvim_get_hl, 0, { name = "Comment", link = false })
	local description_hl = { italic = true }
	if ok and type(comment) == "table" and comment.fg then
		description_hl.fg = comment.fg
	else
		description_hl.link = "Comment"
	end

	vim.api.nvim_set_hl(0, "OpenCodeInputAutocompleteBg", { link = "Pmenu" })
	vim.api.nvim_set_hl(0, "OpenCodeInputAutocompleteSelected", { link = "PmenuSel" })
	vim.api.nvim_set_hl(0, "OpenCodeInputAutocompleteLabel", { link = "Pmenu" })
	vim.api.nvim_set_hl(0, "OpenCodeInputAutocompleteDescription", description_hl)
	vim.api.nvim_set_hl(0, "OpenCodeInputAutocompleteBorder", { link = "Comment" })
end

local function close_popup(ac)
	if ac and ac.popup then
		pcall(function()
			ac.popup:unmount()
		end)
	end
	if ac then
		ac.popup = nil
		ac.bufnr = nil
		ac.visible = false
		ac.items = {}
		ac.trigger = nil
		ac.kind = nil
		ac.query = nil
	end
end

function M.close(state)
	local ac = state and state.autocomplete
	close_popup(ac)
end

function M.clear(state)
	M.close(state)
	if state then
		state.autocomplete = nil
	end
end

function M.reset(state)
	M.close(state)
	if state then
		state.autocomplete = {}
	end
end

function M.is_visible(state)
	local ac = state and state.autocomplete
	return ac ~= nil and ac.visible == true
end

local function layout_input_geometry(state)
	local current_layout = state and state.layout
	if current_layout then
		local cfg = state.config or {}
		local min_height = cfg.min_height or 1
		local current_height = current_layout.current_height or min_height
		local vertical_shift = math.max(0, current_height - min_height)
		local row = (current_layout.row or 0) - vertical_shift
		local col = current_layout.col or 0

		if not current_layout.is_float then
			if not valid_win(state.parent_winid) then
				return nil
			end

			local pos = vim.fn.win_screenpos(state.parent_winid)
			row = (tonumber(pos[1]) or 1) - 1 + row
			col = (tonumber(pos[2]) or 1) - 1 + col
		end

		return {
			row = row,
			col = col,
			height = current_height,
			width = current_layout.content_width or (valid_win(state.winid) and vim.api.nvim_win_get_width(state.winid)) or 1,
		}
	end

	if not valid_win(state and state.winid) then
		return nil
	end

	local pos = vim.fn.win_screenpos(state.winid)
	return {
		row = (tonumber(pos[1]) or 1) - 1,
		col = (tonumber(pos[2]) or 1) - 1,
		height = vim.api.nvim_win_get_height(state.winid),
		width = math.max(1, vim.api.nvim_win_get_width(state.winid)),
	}
end

local function current_input_geometry(state, requested_height)
	local input = layout_input_geometry(state)
	if not input then
		return nil
	end

	local height = math.max(1, math.min(MAX_ITEMS, requested_height or 1))
	if input.row > 0 then
		height = math.min(height, input.row)
	end

	local row = input.row - height

	if row < 0 then
		row = input.row + input.height
		local max_row = math.max(0, vim.o.lines - height - 1)
		if row > max_row then
			row = math.max(0, input.row - height)
		end
	end

	return {
		row = row,
			-- Input popup has a left split border. Autocomplete adds right padding,
			-- so offset its inner layout to keep the left edge aligned with input.
		col = math.max(0, input.col + 1),
		width = math.max(1, input.width - 2),
		height = height,
	}
end

local function mount_or_update_popup(ac, geometry)
	if not ac.popup then
		local Popup = require("nui.popup")
		ac.popup = Popup({
			enter = false,
			focusable = false,
			relative = "editor",
			border = {
				style = SPLIT_BORDER,
				padding = BORDER_PADDING,
			},
			position = { row = geometry.row, col = geometry.col },
			size = { width = geometry.width, height = geometry.height },
			zindex = 100,
			buf_options = {
				buftype = "nofile",
				bufhidden = "wipe",
				swapfile = false,
				filetype = "opencode_input_autocomplete",
			},
			win_options = {
				winhighlight = "Normal:OpenCodeInputAutocompleteBg,EndOfBuffer:OpenCodeInputAutocompleteBg,FloatBorder:OpenCodeInputAutocompleteBorder",
				cursorline = false,
				wrap = false,
				signcolumn = "no",
				number = false,
				relativenumber = false,
				foldcolumn = "0",
				scrolloff = 0,
			},
		})
		ac.popup:mount()
		ac.bufnr = ac.popup.bufnr
	else
		ac.popup:update_layout({
			position = { row = geometry.row, col = geometry.col },
			size = { width = geometry.width, height = geometry.height },
		})
	end
end

local function item_label_width(items)
	local width = 0
	for _, item in ipairs(items or {}) do
		width = math.max(width, vim.fn.strdisplaywidth(item.label or ""))
	end
	return width + LABEL_GAP
end

local function truncate_display(text, width)
	if width <= 0 then
		return ""
	end
	if vim.fn.strdisplaywidth(text) <= width then
		return text
	end

	local result = {}
	local used = 0
	for idx = 0, vim.fn.strchars(text) - 1 do
		local char = vim.fn.strcharpart(text, idx, 1)
		local char_width = vim.fn.strdisplaywidth(char)
		if used + char_width > width then
			break
		end
		table.insert(result, char)
		used = used + char_width
	end
	return table.concat(result)
end

local function pad_display(text, width)
	local padding = math.max(0, width - vim.fn.strdisplaywidth(text))
	return text .. string.rep(" ", padding)
end

local function build_line(item, label_width, width)
	local label = item.label or ""
	local description = item.description or ""
	local label_display_width = vim.fn.strdisplaywidth(label)
	local gap = math.max(1, label_width - label_display_width)
	local content = label
	local desc_col = nil

	if description ~= "" then
		desc_col = #label + gap
		local desc_width = math.max(0, width - label_display_width - gap)
		content = content .. string.rep(" ", gap) .. truncate_display(description, desc_width)
	end

	local line = pad_display(truncate_display(content, width), width)

	return {
		line = line,
		label_start = 0,
		label_end = math.min(#line, #label),
		desc_start = desc_col and math.min(#line, desc_col) or nil,
	}
end

local function render(ac)
	if not valid_buf(ac and ac.bufnr) then
		return
	end

	local label_width = item_label_width(ac.items)
	local lines = {}
	local rows = {}
	for _, item in ipairs(ac.items or {}) do
		local row = build_line(item, label_width, ac.width or 1)
		table.insert(lines, row.line)
		table.insert(rows, row)
	end

	vim.bo[ac.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(ac.bufnr, 0, -1, false, lines)
	vim.api.nvim_buf_clear_namespace(ac.bufnr, NS, 0, -1)

	for idx, item in ipairs(ac.items or {}) do
		local row = idx - 1
		local row_info = rows[idx]
		if idx == ac.selected then
			vim.api.nvim_buf_set_extmark(ac.bufnr, NS, row, 0, {
				end_col = #lines[idx],
				hl_group = "OpenCodeInputAutocompleteSelected",
				hl_eol = true,
				line_hl_group = "OpenCodeInputAutocompleteSelected",
			})
		else
			local label_len = #(item.label or "")
			vim.api.nvim_buf_set_extmark(ac.bufnr, NS, row, row_info.label_start, {
				end_col = math.min(row_info.label_end, row_info.label_start + label_len),
				hl_group = "OpenCodeInputAutocompleteLabel",
			})

			local description = item.description or ""
			if description ~= "" and row_info.desc_start and row_info.desc_start < #lines[idx] then
				vim.api.nvim_buf_set_extmark(ac.bufnr, NS, row, row_info.desc_start, {
					end_col = #lines[idx],
					hl_group = "OpenCodeInputAutocompleteDescription",
				})
			end
		end
	end

	vim.bo[ac.bufnr].modifiable = false
end

local function slash_items(trigger)
	local items = {}
	for _, command in ipairs(slash_commands.available_commands(trigger.query)) do
		table.insert(items, {
			kind = "slash",
			label = "/" .. slash_commands.command_name(command),
			description = slash_commands.command_description(command),
			command = command,
		})
		if #items >= MAX_ITEMS then
			break
		end
	end
	return items
end

local function mention_items(trigger)
	local items = {}
	for _, agent in ipairs(mentions.filter_agents(sync.get_mentionable_agents(), trigger.query)) do
		local name = mentions.agent_name(agent)
		if name ~= "" then
			table.insert(items, {
				kind = "mention",
				label = "@" .. name,
				description = mentions.agent_description(agent),
				agent = agent,
			})
			if #items >= MAX_ITEMS then
				break
			end
		end
	end
	return items
end

local function source_for_state(state)
	local trigger = slash_commands.detect_trigger(state)
	if trigger then
		return "slash", trigger, slash_items(trigger)
	end

	trigger = mentions.detect_trigger(state)
	if trigger then
		return "mention", trigger, mention_items(trigger)
	end

	return nil, nil, {}
end

local function same_context(ac, kind, trigger)
	return ac.kind == kind and ac.query == trigger.query and ac.row == trigger.row and ac.start_col == trigger.start_col
end

function M.refresh(state)
	if not state or not state.visible or vim.fn.mode():sub(1, 1) ~= "i" then
		M.close(state)
		return false
	end

	local kind, trigger, items = source_for_state(state)
	if not kind or #items == 0 then
		M.close(state)
		return false
	end

	local geometry = current_input_geometry(state, #items)
	if not geometry then
		M.close(state)
		return false
	end

	if #items > geometry.height then
		local visible_items = {}
		for idx = 1, geometry.height do
			visible_items[idx] = items[idx]
		end
		items = visible_items
	end

	local ac = ensure_state(state)
	if not same_context(ac, kind, trigger) then
		ac.selected = 1
	else
		ac.selected = math.max(1, math.min(ac.selected or 1, #items))
	end

	ac.visible = true
	ac.kind = kind
	ac.query = trigger.query
	ac.row = trigger.row
	ac.start_col = trigger.start_col
	ac.trigger = trigger
	ac.items = items
	ac.width = geometry.width
	mount_or_update_popup(ac, geometry)
	render(ac)
	return true
end

local function move_selection(state, delta)
	local ac = state and state.autocomplete
	if not ac or not ac.visible or #(ac.items or {}) == 0 then
		return false
	end

	local count = #ac.items
	ac.selected = ((ac.selected or 1) - 1 + delta) % count + 1
	render(ac)
	return true
end

function M.select_next(state)
	return move_selection(state, 1)
end

function M.select_prev(state)
	return move_selection(state, -1)
end

function M.confirm(state)
	local ac = state and state.autocomplete
	if not ac or not ac.visible then
		return false
	end

	local item = ac.items and ac.items[ac.selected or 1]
	if not item then
		M.close(state)
		return false
	end

	local ok = false
	if item.kind == "slash" then
		ok = slash_commands.insert_command(state, ac.trigger, item.command)
	elseif item.kind == "mention" then
		ok = mentions.insert_mention(state, ac.trigger, item.agent)
	end

	M.close(state)
	return ok
end

return M
