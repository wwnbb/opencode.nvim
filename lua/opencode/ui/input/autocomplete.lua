-- opencode.nvim - Input autocomplete popup

local M = {}

local mentions = require("opencode.ui.input.mentions")
local slash_commands = require("opencode.ui.input.slash_commands")
local command_registry = require("opencode.command_registry")
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
		ac.geometry = nil
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
	if valid_win(state and state.winid) then
		local border = state.popup and state.popup.border
		local frame = border and valid_win(border.winid) and border.winid or state.winid
		local position = vim.api.nvim_win_get_position(frame)
		local content = vim.api.nvim_win_get_position(state.winid)
		return {
			row = position[1],
			col = content[2],
			height = vim.api.nvim_win_get_height(frame),
			width = vim.api.nvim_win_get_width(state.winid),
		}
	end

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
			col = col + 1,
			height = current_height,
			width = current_layout.content_width or (valid_win(state.winid) and vim.api.nvim_win_get_width(state.winid)) or 1,
		}
	end

	return nil
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
		col = math.max(0, input.col),
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
	elseif not vim.deep_equal(ac.geometry, geometry) then
		-- NUI redraws its border before resizing content, so prepare content first.
		vim.api.nvim_win_set_config(ac.popup.winid, {
			relative = "editor", row = geometry.row, col = geometry.col,
			width = geometry.width, height = geometry.height,
		})
		ac.popup:update_layout({
			position = { row = geometry.row, col = geometry.col },
			size = { width = geometry.width, height = geometry.height },
		})
	end
	ac.geometry = geometry
end

local function item_label_width(items)
	local width = 0
	for _, item in ipairs(items or {}) do
		width = math.max(width, vim.fn.strdisplaywidth(item.label or ""))
	end
	return width + LABEL_GAP
end

local truncate_display = require("opencode.util.text").truncate

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

local function contexts_enabled(state)
	return state.allow_context == true and state.mode ~= "shell"
end

local function mention_items(state, trigger)
	local items = {}
	if contexts_enabled(state) then
		for _, item in ipairs(require("opencode.context").items(trigger.query)) do
			items[#items + 1] = {
				kind = "context", name = item.name, label = "@" .. item.name,
				description = "Context: " .. item.description,
			}
		end
	end
	for _, agent in ipairs(mentions.filter_agents(sync.get_agents(), trigger.query)) do
		local name = mentions.agent_name(agent)
		if name ~= "" then
			local description = mentions.agent_description(agent)
			table.insert(items, {
				kind = "mention",
				label = "@" .. name,
				description = description ~= "" and ("Agent: " .. description) or "Agent",
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
		return "mention", trigger, mention_items(state, trigger)
	end

	return nil, nil, {}
end

local function same_context(ac, kind, trigger)
	return ac.kind == kind and ac.query == trigger.query and ac.row == trigger.row and ac.start_col == trigger.start_col
end

function M.show_items(state, kind, trigger, items)
	if not state or not kind or not trigger or not items or #items == 0 then
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
	local mounted = ac.popup ~= nil
	if mounted then render(ac) end
	mount_or_update_popup(ac, geometry)
	if not mounted then render(ac) end
	return true
end

function M.refresh(state)
	if not state or not state.visible or vim.fn.mode():sub(1, 1) ~= "i" then
		M.close(state)
		return false
	end

	local kind, trigger, items = source_for_state(state)
	return M.show_items(state, kind, trigger, items)
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

local function has_following_text(state, trigger)
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, trigger.row or 0, -1, false)
	if #lines == 0 then return false end
	if lines[1]:sub(trigger.end_col + 1):match("%S") then return true end
	for index = 2, #lines do
		if lines[index]:match("%S") then return true end
	end
	return false
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

	if not state.visible or not valid_buf(state.bufnr) or not valid_win(state.winid)
		or vim.api.nvim_win_get_buf(state.winid) ~= state.bufnr then
		M.close(state)
		return false
	end
	local source = item.kind == "slash" and slash_commands
		or (item.kind == "mention" or item.kind == "context") and mentions
	local current = source and source.detect_trigger(state)
	local offered = ac.trigger
	if not current or not offered or current.query ~= offered.query or current.row ~= (offered.row or 0)
		or current.start_col ~= offered.start_col or current.end_col ~= offered.end_col then
		M.close(state)
		return false
	end

	local ok, selection = false, nil
	if item.kind == "slash" then
		local name = slash_commands.command_name(item.command)
		local id = type(item.command) == "table" and item.command.id or nil
		local command = id and command_registry.get(id) or command_registry.get_slash(name)
		local generation = type(item.command) == "table" and item.command.generation or nil
		if id and (not command or command_registry.get_slash(name) ~= command
			or (generation and generation ~= command._serial) or not command_registry.enabled(command)) then
			M.close(state)
			vim.notify("Command not available: /" .. name, vim.log.levels.WARN)
			return false
		end
		if state.allow_chat_commands and command and command.on_select and not has_following_text(state, current) then
			if command_registry.get_slash(name) ~= command or not command_registry.enabled(command) then
				M.close(state)
				return false
			end
			if command.with_parts == "reject" and (#(state.parts or {}) > 0 or #mentions.active_parts(state) > 0) then
				M.close(state)
				vim.notify(command.parts_error or ("/" .. name .. " does not support attachments"), vim.log.levels.WARN)
				return false
			end
			local original = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
			ok = slash_commands.consume_command(state, current)
			if ok then selection = { kind = "command", id = command.id, original = original } end
		else
			ok = slash_commands.insert_command(state, current, item.command)
		end
	elseif item.kind == "context" and contexts_enabled(state) then
		local context = vim.iter(require("opencode.context").items(current.query)):find(function(candidate)
			return candidate.name == item.name
		end)
		if context then
			local suffix = current.line:sub(current.end_col + 1, current.end_col + 1):match("%s") and "" or " "
			local inserted = "@" .. context.name .. suffix
			vim.api.nvim_buf_set_text(state.bufnr, current.row, current.start_col, current.row, current.end_col, { inserted })
			vim.api.nvim_win_set_cursor(state.winid, { current.row + 1, current.start_col + #inserted })
			ok = true
		end
	elseif item.kind == "mention" then
		local name = mentions.agent_name(item.agent)
		local agent = vim.iter(sync.get_mentionable_agents()):find(function(candidate)
			return mentions.agent_name(candidate) == name
		end)
		if agent then ok = mentions.insert_mention(state, current, agent) end
	end

	M.close(state)
	return ok, selection
end

return M
