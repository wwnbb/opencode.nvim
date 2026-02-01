-- opencode.nvim - Input area module
-- Multi-line input with prompt history

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

-- State
local state = {
	bufnr = nil,
	winid = nil,
	popup = nil,
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
	height = 5,
	border = "single",
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

-- Show input popup
function M.show(opts)
	opts = opts or {}

	if state.visible then
		return
	end

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

	-- Get current window dimensions
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }

	local width = math.min(80, ui.width - 4)
	local height = cfg.height

	-- Position at bottom of screen
	local row = ui.height - height - 2
	local col = math.floor((ui.width - width) / 2)

	-- Create popup
	state.bufnr = setup_buffer()
	state.popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = cfg.border,
			text = {
				top = " Input ",
				top_align = "center",
				bottom = " <C-g> send | <Esc> cancel | ↑↓ history | <C-s> stash | <C-r> restore ",
				bottom_align = "center",
			},
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
		bufnr = state.bufnr,
	})

	-- Mount popup
	state.popup:mount()
	state.winid = state.popup.winid
	state.visible = true

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

	if state.popup then
		state.popup:unmount()
	end

	state.visible = false
	state.winid = nil
	state.bufnr = nil
	state.popup = nil

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
