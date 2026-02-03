-- opencode.nvim - Input area module
-- Multi-line input with prompt history
-- Styled to match OpenCode TUI prompt component

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

-- Highlight group for the input area background
local NS = vim.api.nvim_create_namespace("opencode_input")

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
	height = 8,
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
	},
}

-- Setup highlight groups
local function setup_highlights()
	-- Input area background (subtle elevation from chat bg)
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "NormalFloat", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBorder", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputInfo", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputAgent", { link = "Special", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputModel", { link = "Normal", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputHint", { link = "Comment", default = true })
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

-- Navigate history
local function history_prev()
	if history.index > 1 then
		history.index = history.index - 1
		local text = history.entries[history.index]
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, vim.split(text, "\n"))
		vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
	end
end

local function history_next()
	if history.index < #history.entries then
		history.index = history.index + 1
		local text = history.entries[history.index]
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, vim.split(text, "\n"))
		vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
	elseif history.index == #history.entries then
		history.index = history.index + 1
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "" })
	end
end

-- Stash current input
local function stash_input()
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local text = table.concat(lines, "\n")
	if text ~= "" then
		history.stashed = text
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { "" })
		vim.notify("Input stashed (restore with <C-r>)", vim.log.levels.INFO)
	end
end

-- Restore stashed input
local function restore_input()
	if history.stashed then
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, vim.split(history.stashed, "\n"))
		vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
		history.stashed = nil
	else
		vim.notify("No stashed input", vim.log.levels.WARN)
	end
end

-- Get input text
local function get_input_text()
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	return table.concat(lines, "\n")
end

-- Setup buffer
local function setup_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode_input"

	return bufnr
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

	-- Cancel
	vim.keymap.set({ "i", "n" }, cfg.keymaps.cancel, function()
		if state.on_cancel then
			state.on_cancel()
		end
		M.close()
	end, opts)

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
end

-- Get the info line text (agent + model + hints)
local function get_info_line()
	local app_state = require("opencode.state")
	local session = app_state.get_session()
	local agent = session.agent or "Code"
	local model = session.model or ""

	-- Build info: "Agent  model_name  provider"
	-- Fallback to simple display
	local parts = {}
	table.insert(parts, agent)
	if model ~= "" then
		table.insert(parts, " " .. model)
	end
	return table.concat(parts, "")
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

	local height = cfg.height
	local info_height = 1
	local total_height = height + info_height
	local width = chat_win_width

	-- Position at the bottom of the chat window
	local row = chat_pos[1] + chat_win_height - total_height
	local col = chat_pos[2]

	-- Define sign for left accent bar
	vim.fn.sign_define("OpenCodeAccent", { text = "┃", texthl = "OpenCodeInputBorder" })
	vim.fn.sign_define("OpenCodeAccentEnd", { text = "╹", texthl = "OpenCodeInputBorder" })

	-- Create textarea popup (borderless, use signcolumn for left accent)
	state.bufnr = setup_buffer()
	state.popup = Popup({
		enter = true,
		focusable = true,
		border = "none",
		position = { row = row, col = col },
		size = { width = width, height = height },
		bufnr = state.bufnr,
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,SignColumn:OpenCodeInputBg",
			cursorline = false,
			wrap = true,
			linebreak = true,
			signcolumn = "yes:1",
			number = false,
			relativenumber = false,
		},
	})

	-- Create info bar popup (directly below textarea, borderless)
	local info_bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[info_bufnr].buftype = "nofile"
	vim.bo[info_bufnr].bufhidden = "wipe"

	state.info_popup = Popup({
		enter = false,
		focusable = false,
		border = "none",
		position = { row = row + height, col = col },
		size = { width = width, height = info_height },
		bufnr = info_bufnr,
		win_options = {
			winhighlight = "Normal:OpenCodeInputInfo,SignColumn:OpenCodeInputInfo",
			signcolumn = "yes:1",
			number = false,
			relativenumber = false,
		},
	})

	-- Mount both popups
	state.popup:mount()
	state.info_popup:mount()

	state.winid = state.popup.winid
	state.visible = true

	-- Fill the buffer with empty lines so signs cover the full height,
	-- then place accent signs on every line
	local fill_lines = {}
	for i = 1, height do
		fill_lines[i] = ""
	end
	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, fill_lines)
	for i = 1, height do
		vim.fn.sign_place(0, "opencode_input", "OpenCodeAccent", state.bufnr, { lnum = i })
	end

	-- Place bottom-cap sign on info bar
	vim.fn.sign_place(0, "opencode_input", "OpenCodeAccentEnd", info_bufnr, { lnum = 1 })

	-- Set info bar content
	local info_text = get_info_line()
	local hints = "<C-g> send  <Esc> cancel  ↑↓ history  <C-s> stash  <C-r> restore"
	local available = width - 2 -- account for signcolumn
	local info_display = info_text
	local remaining = available - #info_text - #hints
	if remaining > 0 then
		info_display = info_text .. string.rep(" ", remaining) .. hints
	else
		info_display = info_text .. hints
	end
	vim.api.nvim_buf_set_lines(info_bufnr, 0, -1, false, { info_display })

	-- Apply highlights to info bar
	vim.api.nvim_buf_add_highlight(info_bufnr, NS, "OpenCodeInputAgent", 0, 0, #info_text)
	local hints_start = #info_display - #hints
	if hints_start >= 0 then
		vim.api.nvim_buf_add_highlight(info_bufnr, NS, "OpenCodeInputHint", 0, hints_start, #info_display)
	end

	-- Keep accent signs covering all buffer lines as user types
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = state.bufnr,
		callback = function()
			if not state.visible then
				return true -- remove autocmd
			end
			vim.fn.sign_unplace("opencode_input", { buffer = state.bufnr })
			local line_count = vim.api.nvim_buf_line_count(state.bufnr)
			for i = 1, line_count do
				vim.fn.sign_place(0, "opencode_input", "OpenCodeAccent", state.bufnr, { lnum = i })
			end
		end,
	})

	-- Setup keymaps
	setup_keymaps(state.bufnr, cfg)

	-- Handle unmount
	state.popup:on(event.BufLeave, function()
		M.close()
	end)

	-- Move cursor to line 1 and start in insert mode
	vim.api.nvim_win_set_cursor(state.winid, { 1, 0 })
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

return M
