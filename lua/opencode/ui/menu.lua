-- opencode.nvim - Shared list and searchable menu controller

local M = {}

local Popup = require("nui.popup")
local float_context = require("opencode.ui.float_context")

local hl_ns = vim.api.nvim_create_namespace("opencode_menu")

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
		local value = item.value or item.label
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
	if query == "" then
		return true
	end

	local label = item_label(item):lower()
	if label:find(query, 1, true) then
		return true
	end

	local description = item_description(item)
	if description and description:lower():find(query, 1, true) then
		return true
	end

	if type(item) == "table" and item.value ~= nil then
		return tostring(item.value):lower():find(query, 1, true) ~= nil
	end
	return false
end

local function format_item_line(item, selected, selected_items, multi_select, width)
	local prefix = selected and "▸ " or "  "
	local marker = ""
	if multi_select then
		marker = selected_items[item_key(item)] and "[x] " or "[ ] "
	end

	local left = prefix .. marker .. item_label(item)
	local description = item_description(item)
	if not description or description == "" then
		return truncate_to_width(left, width)
	end

	local desc_width = display_width(description)
	local left_width = width - desc_width - 2
	if left_width <= display_width(prefix .. marker) + 4 then
		return truncate_to_width(left, width)
	end

	left = truncate_to_width(left, left_width)
	local padding = math.max(2, width - display_width(left) - desc_width)
	return left .. string.rep(" ", padding) .. description
end

function M.open(opts)
	opts = opts or {}

	local items = opts.items or {}
	local keys = normalize_keys(opts.keys)
	local searchable = opts.searchable == true
	local multi_select = opts.multi_select == true
	local width = opts.width or (searchable and 60 or 40)
	local list_height = opts.list_height
		or math.max(math.min(math.max(#items, 1), searchable and 15 or 20), searchable and 8 or 1)
	local total_width = width + 2
	local total_height = searchable and (list_height + 5) or (list_height + 2)
	local relative, row, col, zindex = float_context.resolve_centered_placement(total_width, total_height)
	local footer = build_footer({
		footer = opts.footer,
		multi_select = multi_select,
		confirm_label = opts.confirm_label,
	}, keys)

	local is_closed = false
	local filtered_items = {}
	local selected_idx = 1
	local search_text = ""
	local selected_items = {}
	local input_popup = nil
	local list_popup = nil
	local layout = nil
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
		pcall(function()
			if layout then
				layout:unmount()
			elseif list_popup then
				list_popup:unmount()
			end
		end)
		if opts.refocus_chat ~= false then
			float_context.focus_chat_if_visible()
		end
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
			table.insert(lines, searchable and "  No matches found" or "  No items")
		else
			for idx, item in ipairs(filtered_items) do
				table.insert(lines, format_item_line(item, idx == selected_idx, selected_items, multi_select, width))
				if type(item) == "table" and item.priority and item.priority > 0 then
					table.insert(highlights, { line = idx, hl = "String" })
				end
			end
		end

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
	if searchable then
		local NuiInput = require("nui.input")
		local NuiLayout = require("nui.layout")
		input_popup = NuiInput({
			relative = relative,
			position = { row = row, col = col },
			size = { width = width },
			zindex = zindex and (zindex + 1) or nil,
			border = {
				style = "rounded",
				text = {
					top = opts.title or " Search ",
					top_align = "center",
				},
			},
			buf_options = {
				filetype = "opencode_float",
			},
			win_options = {
				winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
			},
		}, {
			prompt = " ",
			default_value = "",
		})

		list_popup = Popup({
			relative = relative,
			position = { row = row + 3, col = col },
			size = { width = width, height = list_height },
			zindex = zindex,
			border = {
				style = "rounded",
				text = {
					bottom = footer,
					bottom_align = "center",
				},
			},
			buf_options = {
				filetype = "opencode_float",
			},
			win_options = {
				cursorline = true,
				winhighlight = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:PmenuSel",
			},
		})

		layout = NuiLayout({
			relative = relative,
			position = { row = row, col = col },
			size = {
				width = width + 2,
				height = list_height + 5,
			},
			zindex = zindex,
		}, NuiLayout.Box({
			NuiLayout.Box(input_popup, { size = { height = 3 } }),
			NuiLayout.Box(list_popup, { size = { height = list_height } }),
		}, { dir = "col" }))

		layout:mount()
		render_list({ preserve_selection = false })
		map_common_keys(input_popup.bufnr, { "i", "n" })
		map_common_keys(list_popup.bufnr, { "n" })

		input_popup:on(event.TextChangedI, function()
			local lines = vim.api.nvim_buf_get_lines(input_popup.bufnr, 0, 1, false)
			search_text = lines[1] or ""
			render_list({ preserve_selection = false })
		end)
		input_popup:on(event.BufLeave, function()
			vim.defer_fn(close, 100)
		end)
		vim.cmd("startinsert!")
	else
		list_popup = Popup({
			relative = relative,
			enter = true,
			focusable = true,
			zindex = zindex,
			border = {
				style = "rounded",
				text = {
					top = opts.title or " Select ",
					top_align = "center",
					bottom = footer,
					bottom_align = "center",
				},
			},
			position = { row = row, col = col },
			size = { width = width, height = list_height },
			buf_options = {
				filetype = "opencode_float",
			},
			win_options = {
				cursorline = true,
				winhighlight = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:PmenuSel",
			},
		})

		list_popup:mount()
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
	ctx.layout = layout
	return ctx
end

return M
