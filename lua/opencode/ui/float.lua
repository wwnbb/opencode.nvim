-- opencode.nvim - Shared float utilities
-- Reusable floating window helpers

local M = {}

local Popup = require("nui.popup")

-- Create a centered floating popup with standard styling
function M.create_centered_popup(opts)
	opts = opts or {}
	
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	
	local width = opts.width or math.min(60, ui.width - 10)
	local height = opts.height or math.min(20, ui.height - 6)
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)
	
	local bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
	
	local popup = Popup({
		enter = opts.enter ~= false,
		focusable = opts.focusable ~= false,
		border = {
			style = opts.border or "rounded",
			text = opts.title and {
				top = " " .. opts.title .. " ",
				top_align = "center",
			} or nil,
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
		bufnr = bufnr,
	})
	
	return popup, bufnr
end

-- Create a popup at specific position
function M.create_popup_at(position, size, opts)
	opts = opts or {}
	
	local bufnr = opts.bufnr or vim.api.nvim_create_buf(false, true)
	
	local popup = Popup({
		enter = opts.enter ~= false,
		focusable = opts.focusable ~= false,
		border = {
			style = opts.border or "single",
			text = opts.title and {
				top = " " .. opts.title .. " ",
				top_align = "center",
			} or nil,
		},
		position = position,
		size = size,
		bufnr = bufnr,
	})
	
	return popup, bufnr
end

-- Setup standard keymaps for a popup (q to close, Esc to close)
function M.setup_close_keymaps(bufnr, close_fn)
	local opts = { buffer = bufnr, noremap = true, silent = true }
	
	vim.keymap.set("n", "q", close_fn, opts)
	vim.keymap.set("n", "<Esc>", close_fn, opts)
end

-- Create loading spinner popup
function M.show_loading(message, opts)
	opts = opts or {}
	
	local popup, bufnr = M.create_centered_popup({
		width = opts.width or 40,
		height = 3,
		border = "rounded",
		title = " Loading ",
	})
	
	popup:mount()
	
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"",
		"  " .. (message or "Loading..."),
		"",
	})
	
	vim.bo[bufnr].modifiable = false
	
	-- Return close function
	return function()
		popup:unmount()
	end
end

-- Show notification popup (auto-closing)
function M.show_notification(message, level, timeout)
	level = level or vim.log.levels.INFO
	timeout = timeout or 3000
	
	local width = math.min(50, #message + 10)
	local height = 3
	
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	
	local row = 1  -- Top of screen
	local col = ui.width - width - 2  -- Right aligned
	
	local bufnr = vim.api.nvim_create_buf(false, true)
	local popup = Popup({
		enter = false,
		focusable = false,
		border = "rounded",
		position = { row = row, col = col },
		size = { width = width, height = height },
		bufnr = bufnr,
	})
	
	popup:mount()
	
	local hl_group = "Normal"
	if level == vim.log.levels.ERROR then
		hl_group = "ErrorMsg"
	elseif level == vim.log.levels.WARN then
		hl_group = "WarningMsg"
	elseif level == vim.log.levels.INFO then
		hl_group = "MoreMsg"
	end
	
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
		"",
		"  " .. message,
		"",
	})
	
	vim.api.nvim_buf_add_highlight(bufnr, -1, hl_group, 1, 0, -1)
	vim.bo[bufnr].modifiable = false
	
	-- Auto close
	vim.defer_fn(function()
		pcall(function()
			popup:unmount()
		end)
	end, timeout)
	
	return popup
end

-- Create menu/selection popup (basic version for backwards compatibility)
function M.create_menu(items, on_select, opts)
	opts = opts or {}

	local width = opts.width or 40
	local height = math.min(#items + 2, 20)

	local bufnr = vim.api.nvim_create_buf(false, true)
	local popup, bufnr = M.create_centered_popup({
		width = width,
		height = height,
		border = "rounded",
		title = opts.title or " Select ",
		bufnr = bufnr,
	})

	-- Set content
	local lines = {}
	for i, item in ipairs(items) do
		table.insert(lines, string.format("  %d. %s", i, item.label or item))
	end

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
	vim.bo[bufnr].modifiable = false

	-- Setup keymaps
	local opts_map = { buffer = bufnr, noremap = true, silent = true }

	vim.keymap.set("n", "<CR>", function()
		local cursor = vim.api.nvim_win_get_cursor(0)
		local idx = cursor[1]
		if items[idx] then
			on_select(items[idx], idx)
			popup:unmount()
		end
	end, opts_map)

	vim.keymap.set("n", "q", function()
		popup:unmount()
	end, opts_map)

	vim.keymap.set("n", "<Esc>", function()
		popup:unmount()
	end, opts_map)

	-- Number shortcuts
	for i = 1, math.min(9, #items) do
		vim.keymap.set("n", tostring(i), function()
			on_select(items[i], i)
			popup:unmount()
		end, opts_map)
	end

	popup:mount()

	return popup
end

-- Create input popup for text entry (API keys, codes, etc.)
-- opts: { title?, prompt?, on_submit, on_cancel?, width?, password? }
function M.create_input_popup(opts)
	opts = opts or {}

	local NuiInput = require("nui.input")
	local event = require("nui.utils.autocmd").event

	local width = opts.width or 50

	-- Get current window dimensions for centering
	local win_width = vim.api.nvim_win_get_width(0)
	local win_height = vim.api.nvim_win_get_height(0)
	local row = math.floor((win_height - 3) / 2)
	local col = math.floor((win_width - width) / 2)

	local input = NuiInput({
		relative = "win",
		position = { row = row, col = col },
		size = { width = width },
		border = {
			style = "rounded",
			text = {
				top = opts.title or " Input ",
				top_align = "center",
				bottom = " ⏎:submit  esc:cancel ",
				bottom_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
	}, {
		prompt = opts.prompt and (opts.prompt .. " ") or "> ",
		default_value = opts.default or "",
	})

	input:mount()

	local is_closed = false
	local function close()
		if is_closed then return end
		is_closed = true
		input:unmount()
	end

	-- Setup keymaps
	local input_bufnr = input.bufnr
	local keymap_opts = { buffer = input_bufnr, noremap = true, silent = true }

	vim.keymap.set("i", "<CR>", function()
		local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false)
		local value = lines[1] or ""
		-- Remove prompt prefix if present
		if opts.prompt then
			value = value:gsub("^" .. vim.pesc(opts.prompt) .. "%s*", "")
		end
		value = value:gsub("^>%s*", "")
		close()
		if opts.on_submit then
			opts.on_submit(value)
		end
	end, keymap_opts)

	vim.keymap.set("i", "<Esc>", function()
		close()
		if opts.on_cancel then
			opts.on_cancel()
		end
	end, keymap_opts)

	vim.keymap.set("i", "<C-c>", function()
		close()
		if opts.on_cancel then
			opts.on_cancel()
		end
	end, keymap_opts)

	-- Close on buffer leave
	input:on(event.BufLeave, function()
		vim.defer_fn(close, 100)
	end)

	-- Start in insert mode
	vim.cmd("startinsert!")

	return {
		close = close,
		input = input,
	}
end

-- Create interactive searchable menu with fuzzy filtering
-- items: array of { label, value, description?, group?, priority? }
-- on_select: function(item) called when item is selected
-- opts: { title?, width?, placeholder?, groups? }
function M.create_searchable_menu(items, on_select, opts)
	opts = opts or {}

	local NuiLayout = require("nui.layout")
	local NuiInput = require("nui.input")
	local event = require("nui.utils.autocmd").event

	local width = opts.width or 60
	local list_height = math.min(#items + 2, 15)

	-- Get current window dimensions for centering
	local win_width = vim.api.nvim_win_get_width(0)
	local win_height = vim.api.nvim_win_get_height(0)
	local total_height = list_height + 5
	local row = math.floor((win_height - total_height) / 2)
	local col = math.floor((win_width - width - 2) / 2)

	-- Track state
	local filtered_items = vim.deepcopy(items)
	local selected_idx = 1
	local search_text = ""
	local is_closed = false

	-- Create input popup for search
	local input_popup = NuiInput({
		relative = "win",
		position = { row = row, col = col },
		size = { width = width },
		border = {
			style = "rounded",
			text = {
				top = opts.title or " Search ",
				top_align = "center",
			},
		},
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
	}, {
		prompt = " ",
		default_value = "",
		on_change = function(value)
			search_text = value
			-- Filter and update list
			M._update_searchable_list(filtered_items, items, search_text, list_popup, selected_idx)
		end,
	})

	-- Create list popup for results
	local list_bufnr = vim.api.nvim_create_buf(false, true)
	local list_popup = Popup({
		relative = "win",
		position = { row = row + 3, col = col },
		size = { width = width, height = list_height },
		border = {
			style = "rounded",
			text = {
				bottom = " ↑↓/j,k:navigate  ⏎:select  esc:close ",
				bottom_align = "center",
			},
		},
		bufnr = list_bufnr,
		win_options = {
			cursorline = true,
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder,CursorLine:PmenuSel",
		},
	})

	-- Create layout combining both
	local layout = NuiLayout(
		{
			relative = "win",
			position = { row = row, col = col },
			size = {
				width = width + 2,
				height = list_height + 5,
			},
		},
		NuiLayout.Box({
			NuiLayout.Box(input_popup, { size = { height = 3 } }),
			NuiLayout.Box(list_popup, { size = { height = list_height } }),
		}, { dir = "col" })
	)

	-- Filter function
	local function filter_items()
		filtered_items = {}
		local query = search_text:lower()

		for _, item in ipairs(items) do
			local label = (item.label or ""):lower()
			local desc = (item.description or ""):lower()

			if query == "" or label:find(query, 1, true) or desc:find(query, 1, true) then
				table.insert(filtered_items, item)
			end
		end

		-- Sort: prioritized items first, then alphabetically
		table.sort(filtered_items, function(a, b)
			local a_priority = a.priority or 0
			local b_priority = b.priority or 0
			if a_priority ~= b_priority then
				return a_priority > b_priority
			end
			return (a.label or "") < (b.label or "")
		end)

		return filtered_items
	end

	-- Render list
	local function render_list()
		filtered_items = filter_items()

		local lines = {}
		local highlights = {}

		if #filtered_items == 0 then
			table.insert(lines, "  No matches found")
		else
			for i, item in ipairs(filtered_items) do
				local prefix = i == selected_idx and "▸ " or "  "
				local label = item.label or tostring(item.value)
				local line = prefix .. label

				-- Add description if present
				if item.description then
					local desc_space = width - #line - #item.description - 4
					if desc_space > 0 then
						line = line .. string.rep(" ", desc_space) .. item.description
					end
				end

				table.insert(lines, line)

				-- Highlight connected/priority items
				if item.priority and item.priority > 0 then
					table.insert(highlights, { line = i, hl = "String" })
				end
			end
		end

		vim.bo[list_bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(list_bufnr, 0, -1, false, lines)
		vim.bo[list_bufnr].modifiable = false

		-- Apply highlights
		for _, hl in ipairs(highlights) do
			vim.api.nvim_buf_add_highlight(list_bufnr, -1, hl.hl, hl.line - 1, 0, -1)
		end

		-- Position cursor
		if #filtered_items > 0 and list_popup.winid and vim.api.nvim_win_is_valid(list_popup.winid) then
			vim.api.nvim_win_set_cursor(list_popup.winid, { math.min(selected_idx, #filtered_items), 0 })
		end
	end

	-- Close function
	local function close()
		if is_closed then return end
		is_closed = true
		layout:unmount()
	end

	-- Select current item
	local function select_current()
		if #filtered_items > 0 and filtered_items[selected_idx] then
			local item = filtered_items[selected_idx]
			close()
			on_select(item)
		end
	end

	-- Move selection
	local function move_selection(delta)
		if #filtered_items == 0 then return end
		selected_idx = selected_idx + delta
		if selected_idx < 1 then
			selected_idx = #filtered_items
		elseif selected_idx > #filtered_items then
			selected_idx = 1
		end
		render_list()
	end

	-- Mount layout
	layout:mount()

	-- Initial render
	render_list()

	-- Setup keymaps on input
	local input_bufnr = input_popup.bufnr
	local keymap_opts = { buffer = input_bufnr, noremap = true, silent = true }

	vim.keymap.set("i", "<CR>", select_current, keymap_opts)
	vim.keymap.set("i", "<Esc>", close, keymap_opts)
	vim.keymap.set("i", "<C-c>", close, keymap_opts)
	vim.keymap.set("i", "<Up>", function() move_selection(-1) end, keymap_opts)
	vim.keymap.set("i", "<Down>", function() move_selection(1) end, keymap_opts)
	vim.keymap.set("i", "<C-p>", function() move_selection(-1) end, keymap_opts)
	vim.keymap.set("i", "<C-n>", function() move_selection(1) end, keymap_opts)
	vim.keymap.set("i", "<C-k>", function() move_selection(-1) end, keymap_opts)
	vim.keymap.set("i", "<C-j>", function() move_selection(1) end, keymap_opts)

	-- Normal mode keymaps
	vim.keymap.set("n", "<CR>", select_current, keymap_opts)
	vim.keymap.set("n", "<Esc>", close, keymap_opts)
	vim.keymap.set("n", "q", close, keymap_opts)
	vim.keymap.set("n", "j", function() move_selection(1) end, keymap_opts)
	vim.keymap.set("n", "k", function() move_selection(-1) end, keymap_opts)
	vim.keymap.set("n", "<Up>", function() move_selection(-1) end, keymap_opts)
	vim.keymap.set("n", "<Down>", function() move_selection(1) end, keymap_opts)

	-- Update on text change
	input_popup:on(event.TextChangedI, function()
		local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, 1, false)
		search_text = lines[1] or ""
		selected_idx = 1
		render_list()
	end)

	-- Close on buffer leave
	input_popup:on(event.BufLeave, function()
		vim.defer_fn(close, 100)
	end)

	-- Start in insert mode
	vim.cmd("startinsert!")

	return {
		close = close,
		layout = layout,
	}
end

return M
