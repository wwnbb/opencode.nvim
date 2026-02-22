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
	visible = false,
	on_send = nil,
	on_cancel = nil,
	config = nil,
	layout = nil,
}

-- History management
local history = {
	entries = {},
	index = 0,
	max_entries = 100,
	stashed = nil,
}

-- Default configuration
local defaults = {
	min_height = 3,
	max_height = 20,
	prompt = "> ",
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

-- Resize the input window based on content (grows upward, shrinks downward)
local function resize_input()
	if not state.visible or not state.popup or not state.bufnr or not state.winid then
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
			display_lines = display_lines + math.ceil(line_width / win_width)
		end
	end

	local new_height = math.max(cfg.min_height, math.min(display_lines, cfg.max_height))

	if new_height == layout.current_height then
		return
	end

	layout.current_height = new_height

	-- Bottom-anchored: recalculate row so the bottom edge stays fixed
	local total_height = new_height + layout.padding_rows + layout.info_height
	local new_row = layout.chat_row + layout.chat_height - total_height

	state.popup:update_layout({
		position = { row = new_row, col = layout.col },
		size = { width = layout.content_width, height = new_height },
	})
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
	if not state.visible or not state.info_popup then
		return
	end
	local info_bufnr = state.info_popup.bufnr
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
			if state.on_send then
				state.on_send(text)
			end
			M.close()
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
-- Positions itself relative to the current (chat) window
function M.show(opts)
	opts = opts or {}

	if state.visible then
		return
	end

	setup_highlights()

	-- Load config
	local config = require("opencode.config")
	local user_config = config.defaults or {}
	local cfg = vim.tbl_deep_extend("force", defaults, user_config.input or {})
	state.config = cfg

	-- Set callbacks
	state.on_send = opts.on_send
	state.on_cancel = opts.on_cancel or function() end

	-- Load history on first show
	if #history.entries == 0 then
		load_history()
		history.index = #history.entries + 1
	end

	-- Get the chat window position/size to anchor the input relative to it
	local chat_winid = vim.api.nvim_get_current_win()
	local chat_pos = vim.api.nvim_win_get_position(chat_winid) -- [row, col] (0-indexed)
	local chat_win_width = vim.api.nvim_win_get_width(chat_winid)
	local chat_win_height = vim.api.nvim_win_get_height(chat_winid)

	local height = cfg.min_height
	local info_height = 1
	local padding = 1
	local padding_rows = padding * 2 -- top + bottom
	local padding_cols = padding * 2 -- left + right
	local total_height = height + padding_rows + info_height
	local width = chat_win_width

	-- Position at the bottom of the chat window
	local row = chat_pos[1] + chat_win_height - total_height
	local col = chat_pos[2]

	-- Store layout parameters for resize calculations
	state.layout = {
		chat_row = chat_pos[1],
		chat_height = chat_win_height,
		col = col,
		content_width = width - 1 - padding_cols,
		padding_rows = padding_rows,
		info_height = info_height,
		current_height = height,
	}

	-- Left-only border: only the left side has a visible character.
	-- nui border style order: top-left, top, top-right, right, bottom-right, bottom, bottom-left, left
	-- Empty strings "" = no border on that side (no space consumed)
	local border = { "┃", "", "", "", "", "", "┃", "┃" }

	-- Create textarea popup with colored left border
	state.popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = border,
			padding = { top = padding, bottom = padding, left = padding, right = padding },
		},
		position = { row = row, col = col },
		size = { width = width - 1 - padding_cols, height = height },
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
		},
	})

	-- Create info bar popup (below textarea)
	state.info_popup = Popup({
		enter = false,
		focusable = false,
		border = {
			style = border,
			padding = { left = padding, right = 0, top = padding, bottom = padding },
		},
		position = { row = row + height, col = col },
		size = { width = width - 2, height = info_height },
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

	-- Mount popups
	state.popup:mount()
	state.info_popup:mount()

	state.bufnr = state.popup.bufnr
	state.winid = state.popup.winid
	state.visible = true

	vim.api.nvim_buf_set_var(state.bufnr, "completion", false)

	-- Setup auto-resize on text change
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = state.bufnr,
		callback = function()
			resize_input()
		end,
	})

	-- Set info bar content: "Agent model provider [dot] variant" (matching TUI layout)
	-- TUI format from prompt/index.tsx:953-970:
	--   <agent> <model> <provider> [dot] <variant>
	local agent, model, provider, variant = get_info_parts()

	-- Get dynamic per-agent highlight and set border color before render
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

	-- Use state.info_popup.bufnr to ensure correct buffer reference
	local info_buf = state.info_popup.bufnr
	vim.api.nvim_buf_set_lines(info_buf, 0, -1, false, { info_display })

	-- Info bar highlights: agent (per-agent color), model (normal), provider (muted), dot (muted), variant (warning/bold)
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

	-- Setup keymaps
	setup_keymaps(state.bufnr, cfg)

	-- Handle unmount
	state.popup:on(event.BufLeave, function()
		M.close()
	end)

	-- Start in insert mode
	vim.cmd("startinsert!")
end

-- Close input
function M.close()
	if not state.visible then
		return
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
	state.layout = nil

	-- Return to normal mode
	vim.cmd("stopinsert")
end

-- Check if visible
function M.is_visible()
	return state.visible
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
