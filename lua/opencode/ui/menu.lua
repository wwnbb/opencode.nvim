-- opencode.nvim - Shared list and searchable menu controller

local M = {}

local Popup = require("nui.popup")
local float_context = require("opencode.ui.float_context")

local hl_ns = vim.api.nvim_create_namespace("opencode_menu")

require("opencode.ui.highlights").register("opencode.ui.menu", function()
	for name, link in pairs({
		Normal = "Normal",
		Title = "Title",
		Footer = "FloatBorder",
		Selected = "PmenuSel",
		Priority = "String",
		Placeholder = "Question",
	}) do
		vim.api.nvim_set_hl(0, "OpenCodeMenu" .. name, { link = link, default = true })
	end
end)

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
		if type(key) == "table" and key.key and type(key.handler) == "function" then
			table.insert(normalized, key)
		end
	end
	return normalized
end

local function key_footer_text(keys)
	local labels = {}
	for _, key in ipairs(keys) do
		if key.label and key.label ~= "" then
			table.insert(labels, key.label)
		end
	end
	return table.concat(labels, "  ")
end

local function build_footer(opts, keys)
	if opts.footer then
		return opts.footer
	end

	local pieces = { "↑↓/j,k:nav" }
	if opts.multi_select then
		table.insert(pieces, "tab/space:toggle")
		table.insert(pieces, "⏎:" .. (opts.confirm_label or "confirm"))
	else
		table.insert(pieces, "⏎:select")
	end

	local key_text = key_footer_text(keys)
	if key_text ~= "" then
		table.insert(pieces, key_text)
	end
	table.insert(pieces, "esc:close")
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

	local searchable_text = { item_label(item):lower() }
	local description = item_description(item)
	if description then
		table.insert(searchable_text, description:lower())
	end
	if type(item) == "table" then
		if item.value ~= nil then
			table.insert(searchable_text, tostring(item.value):lower())
		end
		if item.key ~= nil then
			table.insert(searchable_text, tostring(item.key):lower())
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

	local items = opts.items or {}
	local keys = normalize_keys(opts.keys)
	local searchable = opts.searchable == true
	local multi_select = opts.multi_select == true
	local width = math.max(12, math.min(opts.width or (searchable and 60 or 40), vim.o.columns - 2))
	local footer = build_footer({
		footer = opts.footer,
		multi_select = multi_select,
		confirm_label = opts.confirm_label,
	}, keys)
	local footer_lines = wrap_footer(footer, width - 8)
	local list_row = searchable and 5 or 3
	local frame_extra = list_row + #footer_lines + 2
	local max_list_height = math.max(
		1,
		math.min(opts.list_height or (searchable and 15 or 20), vim.o.lines - vim.o.cmdheight - frame_extra - 2)
	)
	local list_height = math.min(max_list_height, math.max(1, #items))
	local relative, row, col, zindex = float_context.resolve_centered_placement(width, list_height + frame_extra)
	zindex = zindex or 80

	local is_closed = false
	local filtered_items = {}
	local selected_idx = 1
	local search_text = ""
	local selected_items = {}
	local input_popup = nil
	local list_popup = nil
	local frame = nil
	local ctx = {}

	local function current_item()
		return filtered_items[selected_idx], selected_idx
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
		local query = search_text:lower():gsub("^%W+", "")
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
		-- Unmount the focused child first, then its list and backing surface.
		for _, popup in ipairs({ input_popup or false, list_popup, frame }) do
			if popup then
				pcall(function()
					popup:unmount()
				end)
			end
		end
		if opts.refocus_chat ~= false then
			float_context.focus_chat_if_visible()
		end
	end

	local function render_frame(height)
		if frame.win_config.height ~= height + frame_extra then
			frame:update_layout({ size = { width = width, height = height + frame_extra } })
			list_popup:update_layout({ size = { width = width - 2, height = height } })
		end
		local title = truncate_to_width(vim.trim(opts.title or (searchable and "Search" or "Select")), width - 12)
		local header = "    " .. title .. string.rep(" ", math.max(1, width - display_width(title) - 11)) .. "esc    "
		local lines = { "", header }
		for _ = 3, list_row + height + 1 do
			table.insert(lines, "")
		end
		for _, line in ipairs(footer_lines) do
			table.insert(lines, "    " .. line)
		end
		table.insert(lines, "")
		local buf = frame.bufnr
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_extmark(buf, hl_ns, 1, 4, { end_col = 4 + #title, hl_group = "OpenCodeMenuTitle" })
		vim.api.nvim_buf_set_extmark(
			buf,
			hl_ns,
			1,
			#header - 7,
			{ end_col = #header - 4, hl_group = "OpenCodeMenuFooter" }
		)
		for i = 1, #footer_lines do
			local line = list_row + height + i
			vim.api.nvim_buf_set_extmark(
				buf,
				hl_ns,
				line,
				0,
				{ end_col = #lines[line + 1], hl_group = "OpenCodeMenuFooter" }
			)
		end
		vim.bo[buf].modifiable = false
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
					table.insert(highlights, { line = idx, hl = "OpenCodeMenuPriority" })
				end
			end
		end

		render_frame(math.min(max_list_height, #lines))
		local bufnr = list_popup.bufnr
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false

		for _, hl in ipairs(highlights) do
			local line_text = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.line, false)[1] or ""
			vim.api.nvim_buf_set_extmark(bufnr, hl_ns, hl.line - 1, 0, {
				end_col = #line_text,
				hl_group = hl.hl,
			})
		end

		if #filtered_items > 0 and list_popup.winid and vim.api.nvim_win_is_valid(list_popup.winid) then
			vim.api.nvim_win_set_cursor(list_popup.winid, { selected_idx, 0 })
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

	function ctx.current()
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
		if #filtered_items == 0 then
			return
		end
		selected_idx = selected_idx + delta
		if selected_idx < 1 then
			selected_idx = #filtered_items
		elseif selected_idx > #filtered_items then
			selected_idx = 1
		end
		render_list()
	end

	local function handle_key(key)
		local item = current_item()
		if not item then
			return
		end
		key.handler(ctx, item)
		if not is_closed then
			render_list()
		end
	end

	local function map_common_keys(bufnr, modes)
		local keymap_opts = { buffer = bufnr, noremap = true, silent = true }
		for _, mode in ipairs(modes) do
			vim.keymap.set(mode, "<CR>", select_current, keymap_opts)
			if mode ~= "i" or not searchable then
				vim.keymap.set(mode, "<Esc>", close, keymap_opts)
			end
			vim.keymap.set(mode, "<C-c>", close, keymap_opts)
			vim.keymap.set(mode, "<Up>", function()
				move_selection(-1)
			end, keymap_opts)
			vim.keymap.set(mode, "<Down>", function()
				move_selection(1)
			end, keymap_opts)
		end

		vim.keymap.set("n", "q", close, keymap_opts)
		vim.keymap.set("n", "j", function()
			move_selection(1)
		end, keymap_opts)
		vim.keymap.set("n", "k", function()
			move_selection(-1)
		end, keymap_opts)

		if searchable then
			vim.keymap.set("i", "<C-p>", function()
				move_selection(-1)
			end, keymap_opts)
			vim.keymap.set("i", "<C-n>", function()
				move_selection(1)
			end, keymap_opts)
			vim.keymap.set("i", "<C-k>", function()
				move_selection(-1)
			end, keymap_opts)
			vim.keymap.set("i", "<C-j>", function()
				move_selection(1)
			end, keymap_opts)
		end

		if multi_select then
			vim.keymap.set("n", "<Space>", toggle_current, keymap_opts)
			if searchable then
				vim.keymap.set("i", "<Tab>", toggle_current, keymap_opts)
				vim.keymap.set("i", "<C-Space>", toggle_current, keymap_opts)
			end
		end

		for _, key in ipairs(keys) do
			vim.keymap.set("n", key.key, function()
				handle_key(key)
			end, keymap_opts)
		end

		if not searchable then
			for index = 1, math.min(9, #items) do
				vim.keymap.set("n", tostring(index), function()
					local item = filtered_items[index]
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
				end, keymap_opts)
			end
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
	frame = Popup({
		relative = relative,
		position = { row = row, col = col },
		size = { width = width, height = list_height + frame_extra },
		enter = false,
		focusable = false,
		zindex = zindex,
		border = "none",
		buf_options = { filetype = "opencode_float" },
		win_options = win_options,
	})
	frame:mount()
	local inner_relative = { type = "win", winid = frame.winid }
	list_popup = Popup({
		relative = inner_relative,
		position = { row = list_row, col = 1 },
		size = { width = width - 2, height = list_height },
		enter = not searchable,
		focusable = true,
		zindex = zindex + 1,
		border = "none",
		buf_options = { filetype = "opencode_float" },
		win_options = vim.tbl_extend("force", win_options, {
			cursorline = true,
			winhighlight = win_options.winhighlight .. ",CursorLine:OpenCodeMenuSelected",
		}),
	})
	list_popup:mount()

	if searchable then
		local NuiInput = require("nui.input")
		input_popup = NuiInput({
			relative = inner_relative,
			position = { row = 3, col = 4 },
			size = { width = width - 8 },
			zindex = zindex + 2,
			border = "none",
			buf_options = { filetype = "opencode_float" },
			win_options = win_options,
		}, { prompt = "", default_value = "" })
		input_popup:mount()
		local function update_placeholder()
			vim.api.nvim_buf_clear_namespace(input_popup.bufnr, hl_ns, 0, -1)
			if search_text == "" then
				vim.api.nvim_buf_set_extmark(input_popup.bufnr, hl_ns, 0, 0, {
					virt_text = { { "Search", "OpenCodeMenuPlaceholder" } },
					virt_text_pos = "overlay",
				})
			end
		end
		update_placeholder()
		render_list({ preserve_selection = false })
		map_common_keys(input_popup.bufnr, { "i", "n" })
		map_common_keys(list_popup.bufnr, { "n" })

		input_popup:on(event.TextChangedI, function()
			local lines = vim.api.nvim_buf_get_lines(input_popup.bufnr, 0, 1, false)
			search_text = lines[1] or ""
			update_placeholder()
			render_list({ preserve_selection = false })
		end)
		input_popup:on(event.BufLeave, function()
			vim.defer_fn(close, 100)
		end)
		vim.cmd("startinsert!")
	else
		render_list({ preserve_selection = false })
		map_common_keys(list_popup.bufnr, { "n" })
		if list_popup.winid and vim.api.nvim_win_is_valid(list_popup.winid) and #filtered_items > 0 then
			vim.api.nvim_win_set_cursor(list_popup.winid, { 1, 0 })
		end
		list_popup:on(event.BufLeave, function()
			vim.defer_fn(close, 100)
		end)
	end

	ctx.popup = list_popup
	ctx.input = input_popup
	ctx.frame = frame
	ctx.layout = searchable and { unmount = close } or nil
	return ctx
end

return M
