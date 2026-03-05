-- opencode.nvim - Input area module
-- Multi-line input with prompt history
-- Styled to match OpenCode TUI prompt component

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

-- Namespace for info bar text highlights
local NS_INFO = vim.api.nvim_create_namespace("opencode_input_info")

-- State
local state = {
	bufnr = nil,
	winid = nil,
	popup = nil,
	info_popup = nil,
	info_bufnr = nil, -- unified info buffer reference (set in both modes)
	visible = false,
	on_send = nil,
	on_cancel = nil,
	close_on_send = true,
	config = nil,
	layout = nil,
}

-- History management
local history = {
	entries = {},
	index = 0,
	max_entries = 100,
	stashed = nil,
	pending = nil, -- draft text persisted across open/close cycles
}

-- Default configuration
local defaults = {
	min_height = 1,
	max_height = 20,
	prompt = "┃ ",
	history_file = vim.fn.stdpath("data") .. "/opencode_input_history.json",
	keymaps = {
		send = "<C-g>",
		send_alt = "<C-x><C-s>",
		cancel = "<Esc>",
		history_prev = "<Up>",
		history_next = "<Down>",
		stash = "<C-s>",
		restore = "<C-r>",
		-- Agent/model/variant cycling (matching TUI keybinds)
		variant_cycle = "<C-t>", -- ctrl+t: cycle model variants (like TUI's variant_cycle)
		agent_cycle = "<C-a>", -- ctrl+a: cycle agents (like TUI's agent_cycle)
		model_cycle = "<C-e>", -- ctrl+e: cycle recent models
	},
}

-- Setup highlight groups
local function setup_highlights()
	-- Input area background (subtle elevation from chat bg)
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "NormalFloat", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBorder", { link = "Special", default = true })
	-- Agent border: starts as Special, updated dynamically per current agent
	vim.api.nvim_set_hl(0, "OpenCodeInputBorderAgent", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputInfo", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputAgent", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputModel", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputProvider", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputVariant", { link = "WarningMsg", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputDot", { link = "Comment", default = true })
end

-- Update the border highlight to match the current agent color
local function update_border_color(agent_name)
	local ok, lc = pcall(require, "opencode.local")
	if not ok then
		return
	end
	local agent_hl = lc.agent.color(agent_name)
	vim.api.nvim_set_hl(0, "OpenCodeInputBorderAgent", { link = agent_hl, default = false })
end

-- Load history from file
local function load_history()
	local file = io.open(defaults.history_file, "r")
	if file then
		local content = file:read("*all")
		file:close()
		local ok, entries = pcall(vim.json.decode, content)
		if ok and type(entries) == "table" then
			history.entries = entries
			history.index = #entries + 1
		end
	end
end

-- Save history to file
local function save_history()
	local dir = vim.fn.fnamemodify(defaults.history_file, ":h")
	vim.fn.mkdir(dir, "p")
	local file = io.open(defaults.history_file, "w")
	if file then
		file:write(vim.json.encode(history.entries))
		file:close()
	end
end

-- Add entry to history
local function add_to_history(text)
	if not text or text == "" then
		return
	end

	-- Don't add duplicates of the most recent entry
	if #history.entries > 0 and history.entries[#history.entries] == text then
		return
	end

	table.insert(history.entries, text)

	-- Trim to max size
	while #history.entries > history.max_entries do
		table.remove(history.entries, 1)
	end

	history.index = #history.entries + 1
	save_history()
end

-- Get input text
local function get_input_text()
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	return table.concat(lines, "\n")
end

-- Lock the input window so it cannot scroll (topline stays at 1).
-- Called after resize and via WinScrolled to prevent any scroll while the
-- window has not yet reached its maximum height.
local function lock_scroll()
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end
	local cfg = state.config
	local layout = state.layout
	if not cfg or not layout then
		return
	end
	if layout.current_height < cfg.max_height then
		local view = vim.api.nvim_win_call(state.winid, function()
			return vim.fn.winsaveview()
		end)
		if view.topline ~= 1 or view.leftcol ~= 0 then
			vim.api.nvim_win_call(state.winid, function()
				vim.fn.winrestview({ topline = 1, leftcol = 0 })
			end)
		end
	end
end

-- Resize the input window based on content (grows upward, shrinks downward)
local function resize_input()
	if not state.visible or not state.bufnr or not state.winid then
		return
	end
	if not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local cfg = state.config
	local layout = state.layout
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local win_width = vim.api.nvim_win_get_width(state.winid)

	-- Calculate display lines accounting for line wrapping
	local display_lines = 0
	for _, line in ipairs(lines) do
		local line_width = vim.fn.strdisplaywidth(line)
		if line_width == 0 then
			display_lines = display_lines + 1
		else
			display_lines = display_lines + math.ceil((line_width + 1) / win_width)
		end
	end
	local new_height = math.max(cfg.min_height, math.min(display_lines, cfg.max_height))
	if new_height == layout.current_height then
		lock_scroll()
		return
	end
	layout.current_height = new_height

	-- Keep the input anchored to the bottom edge of the chat window.
	-- Shift only by the effective popup growth (clamped height), not by the
	-- raw wrapped line count, otherwise large pasted blocks push the popup up.
	local vertical_shift = math.max(0, new_height - cfg.min_height)

	state.popup:update_layout({
		position = { row = layout.row - vertical_shift, col = layout.col },
		size = { width = layout.content_width, height = new_height },
	})
	lock_scroll()
end

-- Set input text in the active input buffer and keep cursor at the end.
local function set_input_text(text)
	local content = text or ""
	local lines = vim.split(content, "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end

	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
	vim.api.nvim_win_set_cursor(state.winid, { #lines, #lines[#lines] })
	resize_input()
end

-- Navigate history
local function history_prev()
	if history.index > 1 then
		history.index = history.index - 1
		local text = history.entries[history.index]
		local content_lines = vim.split(text, "\n")
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, content_lines)
		vim.api.nvim_win_set_cursor(state.winid, { #content_lines, vim.fn.col(".") - 1 })
		resize_input()
	end
end

local function history_next()
	if history.index < #history.entries then
		history.index = history.index + 1
		local text = history.entries[history.index]
		local content_lines = vim.split(text, "\n")
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, content_lines)
		vim.api.nvim_win_set_cursor(state.winid, { #content_lines, vim.fn.col(".") - 1 })
		resize_input()
	elseif history.index == #history.entries then
		history.index = history.index + 1
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "" })
		vim.api.nvim_win_set_cursor(state.winid, { 1, 0 })
		resize_input()
	end
end

-- Stash current input
local function stash_input()
	local text = get_input_text()
	if text ~= "" then
		history.stashed = text
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "" })
		vim.api.nvim_win_set_cursor(state.winid, { 1, 0 })
		resize_input()
		vim.notify("Input stashed (restore with <C-r>)", vim.log.levels.INFO)
	end
end

-- Restore stashed input
local function restore_input()
	if history.stashed then
		local content_lines = vim.split(history.stashed, "\n")
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, content_lines)
		vim.api.nvim_win_set_cursor(state.winid, { #content_lines, vim.fn.col(".") - 1 })
		history.stashed = nil
		resize_input()
	else
		vim.notify("No stashed input", vim.log.levels.WARN)
	end
end

-- Titlecase helper (like TUI's Locale.titlecase)
local function titlecase(str)
	if not str or str == "" then
		return str
	end
	return str:sub(1, 1):upper() .. str:sub(2)
end

-- Get the info line parts (agent, model, provider, variant) matching TUI layout
-- Uses the new local.lua module like TUI's local.tsx
local function get_info_parts()
	local ok, lc = pcall(require, "opencode.local")
	if not ok then
		-- Fallback to old state module
		local app_state = require("opencode.state")
		local agent_state = app_state.get_agent()
		local model_state = app_state.get_model()
		return agent_state.name or "Code", model_state.name or "", model_state.provider or "", nil
	end

	-- Use local module (mirrors TUI's local.tsx)
	local agent = lc.agent.current()
	local agent_name = agent and agent.name or "Code"

	local model_parsed = lc.model.parsed()
	local model_name = model_parsed and model_parsed.name or ""
	local provider_name = model_parsed and model_parsed.provider or ""

	local variant = lc.variant.current()

	return agent_name, model_name, provider_name, variant
end

-- Update the info bar display (call when agent/model/variant changes)
local function update_info_bar()
	if not state.visible then
		return
	end
	local info_bufnr = state.info_bufnr
	if not info_bufnr or not vim.api.nvim_buf_is_valid(info_bufnr) then
		return
	end

	local agent, model, provider, variant = get_info_parts()

	-- Get dynamic per-agent highlight and update border color
	local agent_hl = "OpenCodeInputAgent"
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		agent_hl = lc.agent.color(agent)
	end
	update_border_color(agent)

	local agent_part = titlecase(agent) .. " "
	local model_part = model ~= "" and model or ""
	local provider_part = provider ~= "" and (" " .. provider) or ""
	local dot_part = ""
	local variant_part = ""
	if variant and variant ~= "" then
		dot_part = " \194\183 " -- middle dot (U+00B7)
		variant_part = variant
	end

	local info_display = agent_part .. model_part .. provider_part .. dot_part .. variant_part

	vim.api.nvim_buf_set_lines(info_bufnr, 0, -1, false, { info_display })

	-- Clear old highlights
	vim.api.nvim_buf_clear_namespace(info_bufnr, NS_INFO, 0, -1)

	-- Info bar highlights
	local col_offset = 0
	vim.api.nvim_buf_set_extmark(
		info_bufnr,
		NS_INFO,
		0,
		col_offset,
		{ end_col = col_offset + #agent_part, hl_group = agent_hl }
	)
	col_offset = col_offset + #agent_part
	if model_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_bufnr,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #model_part, hl_group = "OpenCodeInputModel" }
		)
		col_offset = col_offset + #model_part
	end
	if provider_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_bufnr,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #provider_part, hl_group = "OpenCodeInputProvider" }
		)
		col_offset = col_offset + #provider_part
	end
	if dot_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_bufnr,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #dot_part, hl_group = "OpenCodeInputDot" }
		)
		col_offset = col_offset + #dot_part
	end
	if variant_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_bufnr,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #variant_part, hl_group = "OpenCodeInputVariant" }
		)
	end
end

-- Setup keymaps
local function setup_keymaps(bufnr, cfg)
	local opts = { buffer = bufnr, noremap = true, silent = true }

	local function send_message()
		local text = get_input_text()
		if text ~= "" then
			add_to_history(text)
			history.pending = nil
			vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "" })
			vim.api.nvim_win_set_cursor(state.winid, { 1, 0 })
			resize_input()
			if state.on_send then
				state.on_send(text)
			end
			if state.close_on_send then
				M.close(false)
			end
		end
	end

	-- Send message (multiple key options for compatibility)
	vim.keymap.set("i", cfg.keymaps.send, send_message, opts)
	vim.keymap.set("n", cfg.keymaps.send, send_message, opts)

	-- Alternative send binding
	if cfg.keymaps.send_alt then
		vim.keymap.set("i", cfg.keymaps.send_alt, send_message, opts)
		vim.keymap.set("n", cfg.keymaps.send_alt, send_message, opts)
	end

	-- Close input
	local function close_input()
		if state.on_cancel then
			state.on_cancel()
		end
		M.close()
	end
	vim.keymap.set("n", "q", close_input, opts)
	vim.keymap.set({ "i", "n" }, "<C-c>", close_input, opts)

	-- History navigation
	vim.keymap.set("i", cfg.keymaps.history_prev, function()
		history_prev()
	end, opts)

	vim.keymap.set("i", cfg.keymaps.history_next, function()
		history_next()
	end, opts)

	-- Stash/restore
	vim.keymap.set({ "i", "n" }, cfg.keymaps.stash, function()
		stash_input()
	end, opts)

	vim.keymap.set({ "i", "n" }, cfg.keymaps.restore, function()
		restore_input()
	end, opts)

	-- Variant cycling (ctrl+t like TUI)
	if cfg.keymaps.variant_cycle then
		vim.keymap.set({ "i", "n" }, cfg.keymaps.variant_cycle, function()
			local ok, lc = pcall(require, "opencode.local")
			if ok then
				lc.variant.cycle()
				update_info_bar()
			end
		end, opts)
	end

	-- Agent cycling (ctrl+a like TUI's agent_cycle)
	if cfg.keymaps.agent_cycle then
		vim.keymap.set({ "i", "n" }, cfg.keymaps.agent_cycle, function()
			local ok, lc = pcall(require, "opencode.local")
			if ok then
				lc.agent.move(1)
				update_info_bar()
			end
		end, opts)
	end

	-- Model cycling (ctrl+m for recent models)
	if cfg.keymaps.model_cycle then
		vim.keymap.set({ "i", "n" }, cfg.keymaps.model_cycle, function()
			local ok, lc = pcall(require, "opencode.local")
			if ok then
				lc.model.cycle(1)
				update_info_bar()
			end
		end, opts)
	end
end

-- Show input popup (TUI-style)
-- Positions itself relative to the chat window
function M.show(opts)
	opts = opts or {}

	if state.visible then
		return
	end

	setup_highlights()

	-- Load config
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}
	local cfg = vim.tbl_deep_extend(
		"force",
		defaults,
		full_config.input or {},
		(full_config.chat and full_config.chat.input) or {}
	)
	state.config = cfg

	-- Set callbacks
	state.on_send = opts.on_send
	state.on_cancel = opts.on_cancel or function() end
	state.close_on_send = opts.close_on_send ~= false

	-- Load history on first show
	if #history.entries == 0 then
		load_history()
		history.index = #history.entries + 1
	end

	-- Get the chat window
	local chat_winid = opts.winid
	if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
		chat_winid = vim.api.nvim_get_current_win()
	end

	-- When inside a floating chat window, use editor-relative NUI popups positioned via
	-- absolute screen coordinates. This avoids the NUI complex-border chain issue where
	-- the chat popup's border window causes misplacement for win-relative children.
	local float_dims = opts.float_dims

	local height = cfg.min_height
	local info_height = 1
	local border = { "┃", "", "", "", "", "", "┃", "┃" }
	local padding = { top = 1, bottom = 1, left = 1, right = 0 }

	local popup_relative
	local popup_position
	local popup_size
	local popup_zindex

	local info_relative
	local info_position
	local info_size
	local info_zindex

	if float_dims then
		local info_top_pad = 1
		local padding_rows = 1
		local float_col = float_dims.col + 1
		local float_content_width = float_dims.width - 3
		local row = float_dims.row + float_dims.height - height - padding_rows - info_height - info_top_pad

		state.layout = {
			is_float = true,
			float_dims = float_dims,
			col = float_col,
			row = float_dims.row + float_dims.height - height - padding_rows - info_height - info_top_pad,
			info_height = info_height + info_top_pad,
			padding_rows = padding_rows,
			current_height = height,
			content_width = float_content_width,
		}

		popup_relative = "editor"
		popup_position = {
			row = row,
			col = float_col,
		}
		popup_size = { width = float_content_width, height = height }
		popup_zindex = 51

		info_relative = "editor"
		info_position = {
			row = float_dims.row + float_dims.height - info_height - info_top_pad,
			col = float_col,
		}
		info_size = { width = float_content_width, height = info_height }
		info_zindex = 51
	else
		local chat_win_width = vim.api.nvim_win_get_width(chat_winid)
		local chat_win_height = vim.api.nvim_win_get_height(chat_winid)
		local padding_rows = 1
		local padding_cols = 1
		local total_height = height + padding_rows * 3 + info_height
		local width = chat_win_width - 2

		local row = chat_win_height - total_height
		local col = 1
		local content_width = width - 1 - padding_cols
		state.layout = {
			is_float = false,
			chat_row = 0,
			chat_height = chat_win_height,
			col = col,
			row = row,
			content_width = content_width,
			padding_rows = padding_rows,
			info_height = info_height,
			current_height = height,
		}

		popup_relative = { type = "win", winid = chat_winid }
		popup_position = { row = row, col = col }
		popup_size = { width = width - padding_cols * 2, height = height }

		info_relative = { type = "win", winid = chat_winid }
		info_position = { row = row + height + padding_rows, col = col }
		info_size = { width = width - 2, height = info_height }
	end

	state.popup = Popup({
		enter = true,
		focusable = true,
		relative = popup_relative,
		border = {
			style = border,
			padding = padding,
		},
		position = popup_position,
		size = popup_size,
		zindex = popup_zindex,
		buf_options = {
			buftype = "nofile",
			bufhidden = "wipe",
			swapfile = false,
			filetype = "opencode_input",
		},
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg,FloatBorder:OpenCodeInputBorderAgent",
			cursorline = false,
			wrap = true,
			linebreak = true,
			signcolumn = "no",
			number = false,
			relativenumber = false,
			scrolloff = 0,
		},
	})

	state.info_popup = Popup({
		enter = false,
		focusable = false,
		relative = info_relative,
		border = {
			style = border,
			padding = padding,
		},
		position = info_position,
		size = info_size,
		zindex = info_zindex,
		buf_options = {
			buftype = "nofile",
			bufhidden = "wipe",
		},
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputInfo,FloatBorder:OpenCodeInputBorderAgent",
			signcolumn = "no",
			number = false,
			relativenumber = false,
		},
	})

	state.popup:mount()
	state.info_popup:mount()

	state.bufnr = state.popup.bufnr
	state.winid = state.popup.winid
	state.info_bufnr = state.info_popup.bufnr
	state.visible = true

	vim.api.nvim_buf_set_var(state.bufnr, "completion", false)

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = state.bufnr,
		callback = function()
			resize_input()
		end,
	})

	-- Prevent scrolling while the window hasn't reached max height
	vim.api.nvim_create_autocmd("WinScrolled", {
		buffer = state.bufnr,
		callback = function()
			lock_scroll()
		end,
	})

	state.popup:on(event.BufLeave, function()
		vim.schedule(function()
			-- Don't close input when the user is entering the native diff tab
			local nd_ok, nd = pcall(require, "opencode.ui.native_diff")
			if nd_ok and nd.is_active and nd.is_active() then
				return
			end
			M.close()
		end)
	end)

	-- Common: populate info bar content
	-- Format: "<agent> <model> <provider> [dot] <variant>" (matching TUI layout)
	local agent, model, provider, variant = get_info_parts()

	local agent_hl_show = "OpenCodeInputAgent"
	local lc_ok, lc_mod = pcall(require, "opencode.local")
	if lc_ok then
		agent_hl_show = lc_mod.agent.color(agent)
	end
	update_border_color(agent)

	local agent_part = titlecase(agent) .. " "
	local model_part = model ~= "" and model or ""
	local provider_part = provider ~= "" and (" " .. provider) or ""
	local dot_part = ""
	local variant_part = ""
	if variant and variant ~= "" then
		dot_part = " \194\183 " -- middle dot (U+00B7)
		variant_part = variant
	end

	local info_display = agent_part .. model_part .. provider_part .. dot_part .. variant_part

	local info_buf = state.info_bufnr
	vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, { info_display })

	-- Info bar highlights: agent (per-agent color), model (normal), provider (muted), dot (muted), variant (warning)
	local col_offset = 0
	vim.api.nvim_buf_set_extmark(
		info_buf,
		NS_INFO,
		0,
		col_offset,
		{ end_col = col_offset + #agent_part, hl_group = agent_hl_show }
	)
	col_offset = col_offset + #agent_part
	if model_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_buf,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #model_part, hl_group = "OpenCodeInputModel" }
		)
		col_offset = col_offset + #model_part
	end
	if provider_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_buf,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #provider_part, hl_group = "OpenCodeInputProvider" }
		)
		col_offset = col_offset + #provider_part
	end
	if dot_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_buf,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #dot_part, hl_group = "OpenCodeInputDot" }
		)
		col_offset = col_offset + #dot_part
	end
	if variant_part ~= "" then
		vim.api.nvim_buf_set_extmark(
			info_buf,
			NS_INFO,
			0,
			col_offset,
			{ end_col = col_offset + #variant_part, hl_group = "OpenCodeInputVariant" }
		)
	end

	-- Setup keymaps (same for both modes)
	setup_keymaps(state.bufnr, cfg)

	-- Re-populate buffer with any unsent text from the previous open
	if history.pending then
		local lines = vim.split(history.pending, "\n")
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
		vim.schedule(resize_input)
	end

	-- Start in insert mode
	vim.cmd("startinsert!")
end

-- Close input
-- save_draft defaults to true; pass false when submitting so the draft is cleared
function M.close(save_draft)
	if not state.visible then
		return
	end

	if save_draft ~= false then
		if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
			local text = get_input_text()
			history.pending = text ~= "" and text or nil
		end
	end

	if state.info_popup then
		state.info_popup:unmount()
	end

	if state.popup then
		state.popup:unmount()
	end

	state.visible = false
	state.winid = nil
	state.bufnr = nil
	state.popup = nil
	state.info_popup = nil
	state.info_bufnr = nil
	state.layout = nil

	-- Return to normal mode
	vim.cmd("stopinsert")
end

-- Check if visible
function M.is_visible()
	return state.visible
end

---@return number[]
function M.get_winids()
	if not state.visible then
		return {}
	end

	local wins = {}
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		table.insert(wins, state.winid)
	end

	if state.info_popup and state.info_popup.winid and vim.api.nvim_win_is_valid(state.info_popup.winid) then
		table.insert(wins, state.info_popup.winid)
	end

	return wins
end

-- Clear history
function M.clear_history()
	history.entries = {}
	history.index = 1
	history.stashed = nil
	os.remove(defaults.history_file)
end

-- Get history for inspection
function M.get_history()
	return vim.deepcopy(history.entries)
end

--- Get pending input text without opening the input UI.
---@return string
function M.get_pending_text()
	if state.visible and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return get_input_text()
	end
	return history.pending or ""
end

--- Set pending input text without opening the input UI.
---@param text string
function M.set_pending_text(text)
	local content = text or ""
	if content == "" then
		history.pending = nil
	else
		history.pending = content
	end

	if not state.visible or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	set_input_text(content)
end

--- Append text to pending input without opening the input UI.
---@param text string
---@param opts? { separator?: string }
---@return string
function M.append_pending_text(text, opts)
	local extra = text or ""
	if extra == "" then
		return M.get_pending_text()
	end

	opts = opts or {}
	local separator = opts.separator or "\n"
	local current = M.get_pending_text()
	local next_text

	if current == "" then
		next_text = extra
	elseif separator == "" then
		next_text = current .. extra
	elseif current:sub(- #separator) == separator then
		next_text = current .. extra
	else
		next_text = current .. separator .. extra
	end

	M.set_pending_text(next_text)
	return next_text
end

-- Setup (called by main module)
function M.setup(opts)
	if opts and opts.history_file then
		defaults.history_file = opts.history_file
	end
	if opts and opts.max_history then
		defaults.max_entries = opts.max_history
	end
end

-- Update info bar (can be called from outside when data changes)
function M.update_info_bar()
	update_info_bar()
end

-- Cycle variant (convenience function to call from outside)
function M.cycle_variant()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		lc.variant.cycle()
		update_info_bar()
	end
end

-- Cycle agent (convenience function to call from outside)
function M.cycle_agent()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		lc.agent.move(1)
		update_info_bar()
	end
end

-- Cycle model (convenience function to call from outside)
function M.cycle_model()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		lc.model.cycle(1)
		update_info_bar()
	end
end

return M
