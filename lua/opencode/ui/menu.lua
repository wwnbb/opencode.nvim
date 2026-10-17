-- opencode.nvim - Shared list and searchable menu controller

local M = {}

local Popup = require("opencode.ui.popup")
local float_context = require("opencode.ui.float_context")
local keymaps = require("opencode.util.keymap")

require("opencode.ui.highlights").register("opencode.ui.menu", function()
	for name, link in pairs({
		Normal = "Normal",
		Title = "Title",
		Footer = "FloatBorder",
		Selected = "PmenuSel",
		Priority = "String",
		Placeholder = "Question",
		Message = "Normal",
	}) do
		vim.api.nvim_set_hl(0, "OpenCodeMenu" .. name, { link = link, default = true })
	end
end)

local function display_width(text)
	return vim.fn.strdisplaywidth(tostring(text or ""))
end

local function truncate_to_width(text, width)
	return require("opencode.util.text").truncate(text, width, width > 3 and "..." or "")
end

local function item_label(item)
	if type(item) == "table" then
		return tostring(item.label or item.value or "")
	end
	return tostring(item or "")
end

local function item_description(item)
	if type(item) == "table" and item.description ~= nil then
		return tostring(item.description)
	end
	return nil
end

local function item_key(item)
	if type(item) == "table" then
		local value = item.key or item.value or item.label
		if value ~= nil then
			return tostring(value)
		end
	end
	return tostring(item)
end

local function normalize_keys(keys)
	local normalized = {}
	if type(keys) ~= "table" then
		return normalized
	end
	for _, key in ipairs(keys) do
		if type(key) == "table" and (key.action or key.key) and type(key.handler) == "function" then
			table.insert(normalized, key)
		end
	end
	return normalized
end

local function build_footer(opts, keys, mode, labels)
	if opts.footer then return opts.footer end
	local pieces = opts.searchable and { mode == "i" and "Search: type to filter" or "Actions" } or {}
	local function hint(actions, description)
		for _, action in ipairs(type(actions) == "table" and actions or { actions }) do
			local values = keymaps.keys(labels[action])
			if #values > 0 then
				pieces[#pieces + 1] = table.concat(values, ", ") .. ":" .. description
				return
			end
		end
	end
	hint(mode == "i" and { "previous", "previous_insert" } or { "previous_normal", "previous" }, "up")
	hint(mode == "i" and { "next", "next_insert" } or { "next_normal", "next" }, "down")
	if opts.multi_select then hint(mode == "i" and { "toggle_insert", "toggle" } or "toggle", "toggle") end
	hint("select", opts.confirm_label or (opts.multi_select and "confirm" or "select"))
	if mode == "i" then
		hint("normal_mode", "actions")
	else
		if opts.searchable then hint("search", "search") end
		for index, key in ipairs(keys) do
			if key.label and key.label ~= "" then
				if key.action then hint(key.action, key.label)
				elseif labels["custom_" .. index] then pieces[#pieces + 1] = key.label end
			end
		end
	end
	hint(mode == "i" and { "close_insert", "close" } or { "close_normal", "close" }, "close")
	return " " .. table.concat(pieces, "  ") .. " "
end

local function default_sort(a, b)
	local a_priority = type(a) == "table" and a.priority or 0
	local b_priority = type(b) == "table" and b.priority or 0
	if a_priority ~= b_priority then
		return (a_priority or 0) > (b_priority or 0)
	end
	return item_label(a) < item_label(b)
end

local function default_filter(item, query)
	local terms = {}
	for term in query:gmatch("%S+") do
		table.insert(terms, term)
	end
	if #terms == 0 then
		return true
	end

	local searchable_text = { vim.fn.tolower(item_label(item)) }
	local description = item_description(item)
	if description then
		table.insert(searchable_text, vim.fn.tolower(description))
	end
	if type(item) == "table" then
		if item.search_text ~= nil then table.insert(searchable_text, vim.fn.tolower(tostring(item.search_text))) end
		if item.value ~= nil then
			table.insert(searchable_text, vim.fn.tolower(tostring(item.value)))
		end
		if item.key ~= nil then
			table.insert(searchable_text, vim.fn.tolower(tostring(item.key)))
		end
	end

	-- Treat whitespace-separated words as an AND query. This lets users narrow
	-- model lists with both a provider and model name, even when the label has
	-- punctuation or other text between them.
	for _, term in ipairs(terms) do
		local found = false
		for _, text in ipairs(searchable_text) do
			if text:find(term, 1, true) then
				found = true
				break
			end
		end
		if not found then
			return false
		end
	end

	return true
end

local function format_item_content(item, selected_items, multi_select, width)
	local marker = ""
	if multi_select then
		marker = selected_items[item_key(item)] and "[x] " or "[ ] "
	end

	local left = marker .. item_label(item)
	local description = item_description(item)
	if not description or description == "" then
		return truncate_to_width(left, width)
	end

	local desc_width = display_width(description)
	local left_width = width - desc_width - 2
	if left_width <= display_width(marker) + 4 then
		return truncate_to_width(left, width)
	end

	left = truncate_to_width(left, left_width)
	local padding = math.max(2, width - display_width(left) - desc_width)
	return left .. string.rep(" ", padding) .. description
end

local function format_item_line(item, selected_items, multi_select, width)
	local content = format_item_content(item, selected_items, multi_select, math.max(0, width - 6))
	return "   " .. content .. string.rep(" ", math.max(0, width - 3 - display_width(content)))
end

-- Keep every shortcut visible, including custom actions in narrow selectors.
local function wrap_footer(text, width)
	local lines, line = {}, ""
	for word in vim.trim(text):gmatch("%S+") do
		if line ~= "" and display_width(line .. " " .. word) > width then
			table.insert(lines, line)
			line = ""
		end
		while display_width(word) > width do
			local count = 1
			while count < vim.fn.strchars(word) and display_width(vim.fn.strcharpart(word, 0, count + 1)) <= width do
				count = count + 1
			end
			table.insert(lines, vim.fn.strcharpart(word, 0, count))
			word = vim.fn.strcharpart(word, count)
		end
		line = line == "" and word or (line .. " " .. word)
	end
	if line ~= "" then
		table.insert(lines, line)
	end
	return lines
end

function M.open(opts)
	opts = opts or {}
	local owner = opts.context and opts.context.view
	if owner and (not require("opencode.ui.chat.state").valid(owner, opts.context.generation)
		or not owner.visible or not owner.winid or not vim.api.nvim_win_is_valid(owner.winid)) then return end

	local items = opts.items or {}
	local keys = normalize_keys(opts.keys)
	local scope = opts.keymap_scope or "menu"
	local _, customized = keymaps.resolve(scope)
	local searchable = opts.searchable == true
	local multi_select = opts.multi_select == true
	local active_mode = searchable and "i" or "n"
	local mode_labels = { i = {}, n = {} }
	local border_width, border_height = Popup.outer_insets()
	local width = math.max(12, math.min(opts.width or (searchable and 60 or 40), vim.o.columns - border_width))
	local footer = build_footer(opts, keys, active_mode, mode_labels[active_mode])
	local base_list_row = searchable and 5 or 3
	local detail_rows = 0
	local function layout_metrics(current_width)
		local next_footer_lines = wrap_footer(footer, current_width - 8)
		local next_message_lines = opts.message and wrap_footer(tostring(opts.message), current_width - 8) or {}
		local next_list_row = base_list_row + (#next_message_lines > 0 and #next_message_lines + 1 or 0)
		local next_frame_extra = next_list_row + #next_footer_lines + 2
		detail_rows = opts.item_detail and math.min(3, math.max(0,
			vim.o.lines - vim.o.cmdheight - next_frame_extra - border_height - 2)) or 0
		if detail_rows > 0 then next_frame_extra = next_frame_extra + detail_rows + 1 end
		local next_max_list_height = math.max(
			1,
			math.min(opts.list_height or (searchable and 15 or 20), vim.o.lines - vim.o.cmdheight - next_frame_extra - border_height)
		)
		return next_footer_lines, next_message_lines, next_list_row, next_frame_extra, next_max_list_height
	end
	local footer_lines, message_lines, list_row, frame_extra, max_list_height = layout_metrics(width)
	local list_height = math.min(max_list_height, math.max(1, #items))
	local relative, row, col, zindex = float_context.resolve_centered_placement(
		width + border_width, list_height + frame_extra + border_height, owner
	)
	zindex = zindex or 80

	local is_closed = false
	local filtered_items = {}
	local selected_idx = 1
	local search_text = ""
	local selected_items = {}
	local view = nil
	local ctx = {}
	local last_layout_width, last_frame_height, last_list_height, last_list_row

	local function current_item()
		return filtered_items[selected_idx], selected_idx
	end

	local function sync_selection()
		if view and view.content.winid and vim.api.nvim_get_current_win() == view.content.winid then
			selected_idx = math.min(math.max(1, vim.api.nvim_win_get_cursor(view.content.winid)[1]), math.max(1, #filtered_items))
		end
	end

	local function selected_item_list()
		local selected = {}
		for _, item in ipairs(items) do
			if selected_items[item_key(item)] then
				table.insert(selected, item)
			end
		end
		return selected
	end

	local function filter_items()
		local next_items = {}
		local query = vim.fn.tolower(search_text)
		for _, item in ipairs(items) do
			local include
			if type(opts.filter) == "function" then
				include = opts.filter(item, query)
			else
				include = default_filter(item, query)
			end
			if include then
				table.insert(next_items, item)
			end
		end

		if opts.sort ~= false then
			table.sort(next_items, type(opts.sort) == "function" and opts.sort or default_sort)
		end
		return next_items
	end

	local function close()
		if is_closed then
			return
		end
		is_closed = true
		if view then
			view:close()
		end
	end

	local function render_frame(height)
		local frame_height = height + frame_extra
		if last_layout_width ~= width or last_frame_height ~= frame_height or last_list_height ~= height
			or last_list_row ~= list_row then
			view:resize({
				frame = { size = { width = width, height = frame_height } },
				content = { size = { width = width - 2, height = height }, position = { row = list_row, col = 1 } },
				input = searchable and { size = { width = width - 8 }, position = { row = 3, col = 4 } } or nil,
			})
			last_layout_width, last_frame_height, last_list_height, last_list_row = width, frame_height, height, list_row
		end
		local title = truncate_to_width(vim.trim(opts.title or (searchable and "Search" or "Select")), math.max(1, width - 8))
		local header = "    " .. title
		local lines = { "", header }
		for _ = 3, list_row + height + 1 do
			table.insert(lines, "")
		end
		for index, line in ipairs(message_lines) do
			lines[base_list_row + index] = "    " .. line
		end
		local detail_start = #lines
		if detail_rows > 0 then
			local item = current_item()
			local detail = item and opts.item_detail(item) or ""
			local detail_lines = {}
			for _, line in ipairs(vim.split(tostring(detail or ""), "\n", { plain = true })) do
				vim.list_extend(detail_lines, wrap_footer(line, width - 8))
			end
			for index = 1, detail_rows do
				local text = detail_lines[index] or ""
				if index == detail_rows and #detail_lines > detail_rows then text = truncate_to_width(text, width - 11) .. "..." end
				table.insert(lines, "    " .. text)
			end
			table.insert(lines, "")
		end
		local footer_start = #lines
		for _, line in ipairs(footer_lines) do
			table.insert(lines, "    " .. line)
		end
		table.insert(lines, "")
		local marks = {
			{ line = 1, col = 4, end_col = 4 + #title, hl_group = "OpenCodeMenuTitle" },
		}
		for index = 1, detail_rows do
			local line = detail_start + index - 1
			table.insert(marks, { line = line, col = 4, end_col = #lines[line + 1], hl_group = "OpenCodeMenuMessage" })
		end
		for index = 1, #message_lines do
			local line = base_list_row + index - 1
			table.insert(marks, { line = line, col = 4, end_col = #lines[line + 1], hl_group = "OpenCodeMenuMessage" })
		end
		for i = 1, #footer_lines do
			local line = footer_start + i - 1
			table.insert(marks, { line = line, col = 0, end_col = #lines[line + 1], hl_group = "OpenCodeMenuFooter" })
		end
		view:render(lines, marks, "frame")
	end

	local function render_list(render_opts)
		render_opts = render_opts or {}
		local previous_key = nil
		if render_opts.preserve_selection ~= false then
			local previous = current_item()
			previous_key = previous and item_key(previous) or nil
		end

		filtered_items = filter_items()
		if previous_key then
			for idx, item in ipairs(filtered_items) do
				if item_key(item) == previous_key then
					selected_idx = idx
					break
				end
			end
		elseif render_opts.preserve_selection == false then
			selected_idx = 1
		end

		if #filtered_items == 0 then
			selected_idx = 1
		else
			selected_idx = math.min(math.max(selected_idx, 1), #filtered_items)
		end

		local lines = {}
		local highlights = {}
		if #filtered_items == 0 then
			table.insert(lines, truncate_to_width(searchable and "   No matches found" or "   No items", width - 2))
		else
			for idx, item in ipairs(filtered_items) do
				table.insert(lines, format_item_line(item, selected_items, multi_select, width - 2))
				if type(item) == "table" and item.priority and item.priority > 0 then
					table.insert(highlights, {
						line = idx - 1,
						col = 0,
						end_col = #lines[idx],
						hl_group = "OpenCodeMenuPriority",
					})
				end
			end
		end

		render_frame(math.min(max_list_height, #lines))
		view:render(lines, highlights, "content")

		if #filtered_items > 0 and view.content.winid and vim.api.nvim_win_is_valid(view.content.winid) then
			vim.api.nvim_win_set_cursor(view.content.winid, { selected_idx, 0 })
		end
	end

	function ctx.close()
		close()
	end

	function ctx.refresh()
		if not is_closed then
			render_list()
		end
	end

	function ctx.set_items(next_items)
		if is_closed then return end
		items = next_items
		render_list({ preserve_selection = false })
	end

	function ctx.current()
		sync_selection()
		return current_item()
	end

	function ctx.selected_items()
		return selected_item_list()
	end

	local function confirm_multi_selection()
		if #filtered_items == 0 then
			return
		end

		local selected = selected_item_list()
		if #selected == 0 and filtered_items[selected_idx] then
			selected = { filtered_items[selected_idx] }
		end
		if #selected == 0 then
			return
		end

		close()
		if type(opts.on_select) == "function" then
			opts.on_select(selected, ctx)
		end
	end

	local function select_current()
		sync_selection()
		if multi_select then
			confirm_multi_selection()
			return
		end

		local item = current_item()
		if not item then
			return
		end

		if opts.close_on_select == false then
			if type(opts.on_select) == "function" then
				opts.on_select(item, ctx)
			end
			ctx.refresh()
			return
		end

		close()
		if type(opts.on_select) == "function" then
			opts.on_select(item, ctx)
		end
	end

	local function toggle_current()
		sync_selection()
		if not multi_select then
			return
		end

		local item = current_item()
		if not item then
			return
		end

		local key = item_key(item)
		if selected_items[key] then
			selected_items[key] = nil
		else
			selected_items[key] = true
		end
		render_list()
	end

	local function move_selection(delta)
		sync_selection()
		if #filtered_items == 0 then
			return
		end
		selected_idx = selected_idx + delta
		if selected_idx < 1 then
			selected_idx = #filtered_items
		elseif selected_idx > #filtered_items then
			selected_idx = 1
		end
		if type(opts.filter) == "function" or type(opts.sort) == "function" or type(opts.on_move) == "function" then
			-- Extension callbacks may observe or mutate the list on every move.
			render_list()
		elseif view.content.winid and vim.api.nvim_win_is_valid(view.content.winid) then
			vim.api.nvim_win_set_cursor(view.content.winid, { selected_idx, 0 })
			if detail_rows > 0 then render_frame(math.min(max_list_height, #filtered_items)) end
		end
		if type(opts.on_move) == "function" then opts.on_move(current_item(), ctx) end
	end

	local function handle_key(key)
		sync_selection()
		local item = current_item()
		if not item and not key.allow_empty then
			return
		end
		key.handler(ctx, item)
		if not is_closed then
			render_list()
		end
	end

	local function update_footer(mode)
		if is_closed then return end
		active_mode = mode
		footer = build_footer(opts, keys, mode, mode_labels[mode])
		footer_lines, message_lines, list_row, frame_extra, max_list_height = layout_metrics(width)
		render_frame(math.min(max_list_height, math.max(1, #filtered_items)))
	end

	local function focus_search()
		if is_closed or not vim.api.nvim_win_is_valid(view.input.winid) then return end
		vim.api.nvim_set_current_win(view.input.winid)
		vim.cmd("startinsert!")
		update_footer("i")
	end

	local function focus_actions()
		vim.cmd("stopinsert")
		if not is_closed and vim.api.nvim_win_is_valid(view.content.winid) then
			vim.api.nvim_set_current_win(view.content.winid)
			update_footer("n")
		end
	end

	local function map_common_keys(bufnr, modes)
		local map, apply = keymaps.mapper(scope, bufnr)
		for _, mode in ipairs(modes) do
			map(mode, "select", select_current)
			local close_action = mode == "i" and searchable and "close_insert" or "close"
			if customized.close and not customized[close_action] then close_action = "close" end
			map(mode, close_action, close)
			map(mode, "previous", function() move_selection(-1) end)
			map(mode, "next", function() move_selection(1) end)
		end
		if not customized.close or customized.close_normal then map("n", "close_normal", close) end
		if not customized.next or customized.next_normal then map("n", "next_normal", function() move_selection(1) end) end
		if not customized.previous or customized.previous_normal then map("n", "previous_normal", function() move_selection(-1) end) end
		if searchable then
			map("n", "search", focus_search)
			if vim.tbl_contains(modes, "i") then
				map("i", "normal_mode", focus_actions)
				if not customized.previous or customized.previous_insert then map("i", "previous_insert", function() move_selection(-1) end) end
				if not customized.next or customized.next_insert then map("i", "next_insert", function() move_selection(1) end) end
			end
		end
		if multi_select then
			map("n", "toggle", toggle_current)
			if searchable and vim.tbl_contains(modes, "i") then map("i", customized.toggle and not customized.toggle_insert and "toggle" or "toggle_insert", toggle_current) end
		end
		for index, key in ipairs(keys) do
			map("n", key.action or ("custom_" .. index), function() handle_key(key) end,
				key.action and nil or { keys = key.key })
		end
		if not searchable then
			for index = 1, math.min(9, #items) do
				map("n", "option_" .. index, function()
					if not filtered_items[index] then return end
					selected_idx = index
					vim.api.nvim_win_set_cursor(view.content.winid, { index, 0 })
					select_current()
				end)
			end
		end
		for _, mode in ipairs(modes) do mode_labels[mode] = {} end
		for _, binding in ipairs(apply()) do
			local labels = mode_labels[binding.mode]
			labels[binding.action] = labels[binding.action] or {}
			table.insert(labels[binding.action], binding.lhs)
		end
	end

	local event = require("nui.utils.autocmd").event
	local win_options = {
		winhighlight = "Normal:OpenCodeMenuNormal,NormalNC:OpenCodeMenuNormal,EndOfBuffer:OpenCodeMenuNormal",
		winblend = 0,
		wrap = false,
		cursorline = false,
		scrolloff = 0,
	}
	view = Popup.new({
		frame = {
			relative = relative,
			position = { row = row, col = col },
			size = { width = width, height = list_height + frame_extra },
			enter = false,
			focusable = false,
			zindex = zindex,
			border = "none",
			buf_options = { filetype = "opencode_float", modifiable = false },
			win_options = win_options,
		},
		content = {
			position = { row = list_row, col = 1 },
			size = { width = width - 2, height = list_height },
			enter = not searchable,
			focusable = true,
			zindex = zindex + 1,
			border = "none",
			buf_options = { filetype = "opencode_float", modifiable = false },
			win_options = vim.tbl_extend("force", win_options, {
				cursorline = true,
				winhighlight = win_options.winhighlight .. ",CursorLine:OpenCodeMenuSelected",
			}),
		},
		input = searchable and {
			position = { row = 3, col = 4 },
			size = { width = width - 8 },
			zindex = zindex + 2,
			border = "none",
			buf_options = { filetype = "opencode_float" },
			win_options = win_options,
			prompt = "",
			default_value = "",
		} or nil,
		focus_restore = opts.refocus_chat ~= false and (owner and "previous" or "chat") or false,
		previous_win = owner and owner.winid,
		close_on_leave = true,
		on_close = function()
			is_closed = true
			if type(opts.on_close) == "function" then opts.on_close(ctx) end
		end,
		on_resize = function()
			width = math.max(12, math.min(opts.width or (searchable and 60 or 40), vim.o.columns - border_width))
			footer_lines, message_lines, list_row, frame_extra, max_list_height = layout_metrics(width)
			local _, next_row, next_col = float_context.resolve_centered_placement(
				width + border_width,
				math.min(max_list_height, math.max(1, #filtered_items)) + frame_extra + border_height, owner
			)
			view:resize({ frame = { position = { row = next_row, col = next_col } } })
			render_list()
		end,
	})
	view:mount()

	if searchable then
		local function update_placeholder()
			local marks = {}
			if search_text == "" then
				marks[1] = {
					line = 0,
					col = 0,
					virt_text = { { opts.search_placeholder or "Search", "OpenCodeMenuPlaceholder" } },
					virt_text_pos = "overlay",
				}
			end
			view:render(nil, marks, "input")
		end
		update_placeholder()
		render_list({ preserve_selection = false })
		map_common_keys(view.input.bufnr, { "i", "n" })
		map_common_keys(view.content.bufnr, { "n" })

		view:on({ event.TextChangedI, event.TextChanged }, function()
			local lines = vim.api.nvim_buf_get_lines(view.input.bufnr, 0, 1, false)
			if search_text == (lines[1] or "") then return end
			search_text = lines[1] or ""
			update_placeholder()
			if type(opts.on_search) == "function" then
				opts.on_search(search_text, ctx)
			else
				render_list({ preserve_selection = false })
			end
			if type(opts.on_move) == "function" and search_text ~= "" and #filtered_items > 0 then
				opts.on_move(current_item(), ctx)
			end
		end, "input")
		local update_pending = false
		local function refresh_mode()
			if update_pending then return end
			update_pending = true
			vim.schedule(function()
				update_pending = false
				if is_closed then return end
				local win = vim.api.nvim_get_current_win()
				if win == view.input.winid or win == view.content.winid then
					local inserting = vim.fn.mode():sub(1, 1) == "i"
					if win == view.content.winid and inserting then vim.cmd("stopinsert") end
					local mode = win == view.input.winid and inserting and "i" or "n"
					if mode ~= active_mode then update_footer(mode) end
				end
			end)
		end
		vim.api.nvim_create_autocmd({ "ModeChanged", "WinEnter" }, { group = view.augroup, callback = refresh_mode })
		focus_search()
	else
		render_list({ preserve_selection = false })
		map_common_keys(view.content.bufnr, { "n" })
		if view.content.winid and vim.api.nvim_win_is_valid(view.content.winid) and #filtered_items > 0 then
			vim.api.nvim_win_set_cursor(view.content.winid, { 1, 0 })
		end
	end

	view:on(event.CursorMoved, function()
		local previous = selected_idx
		sync_selection()
		if selected_idx ~= previous then
			if detail_rows > 0 then render_frame(math.min(max_list_height, math.max(1, #filtered_items))) end
			if type(opts.on_move) == "function" then opts.on_move(current_item(), ctx) end
		end
	end, "content")
	update_footer(active_mode)

	ctx.popup = view.content
	ctx.input = view.input
	ctx.frame = view.frame
	ctx.layout = searchable and { unmount = close } or nil
	return ctx
end

return M
