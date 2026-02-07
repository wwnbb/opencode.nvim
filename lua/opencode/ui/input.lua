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
	padding_top = 1,
	padding_left = 2,
	padding_right = 2,
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
		model_cycle = "<C-m>", -- ctrl+m: cycle recent models
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
	vim.api.nvim_set_hl(0, "OpenCodeInputProvider", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputVariant", { link = "WarningMsg", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputDot", { link = "Comment", default = true })
end

-- Setup buffer

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


-- Get input text (excluding padding lines)
-- Get input text (excluding padding lines and left padding)
local function get_input_text()
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	-- Skip padding lines at the top
	local padding = state.config and state.config.padding_top or 0
	local left_padding = state.config and state.config.padding_left or 0
	local content_lines = {}
	for i = padding + 1, #lines do
		local line = lines[i]
		-- Strip left padding spaces
		if left_padding > 0 then
			line = line:sub(left_padding + 1)
		end
		table.insert(content_lines, line)
	end
	return table.concat(content_lines, "\n")
end

-- Calculate required height based on content
local function calculate_content_height()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.config.min_height
	end

	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local line_count = #lines

	-- Account for wrapped lines if window exists
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local win_width = vim.api.nvim_win_get_width(state.winid)
		local wrapped_count = 0
		for _, line in ipairs(lines) do
			-- Calculate how many screen lines this line takes
			local display_width = vim.fn.strdisplaywidth(line)
			if display_width > win_width then
				wrapped_count = wrapped_count + math.ceil(display_width / win_width) - 1
			end
		end
		line_count = line_count + wrapped_count
	end

	-- line_count already includes the padding lines in the buffer
	-- Clamp between min and max
	return math.max(state.config.min_height, math.min(line_count, state.config.max_height))
end


-- Resize the input window based on content
local function resize_input()
	if not state.visible or not state.popup or not state.info_popup then
		return
	end

	local new_height = calculate_content_height()
	local current_height = vim.api.nvim_win_get_height(state.winid)

	if new_height == current_height then
		return
	end

	-- Get chat window dimensions for repositioning
	local chat = require("opencode.ui.chat")
	local chat_winid = chat.get_winid and chat.get_winid()
	if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
		-- Fallback: try to find the chat window
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			local buf = vim.api.nvim_win_get_buf(win)
			local ft = vim.bo[buf].filetype
			if ft == "opencode" or ft == "opencode_chat" then
				chat_winid = win
				break
			end
		end
	end

	if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
		return
	end

	local chat_pos = vim.api.nvim_win_get_position(chat_winid)
	local chat_win_height = vim.api.nvim_win_get_height(chat_winid)

	local info_height = 1
	local total_height = new_height + info_height

	-- Calculate new row position (input stays at bottom of chat window)
	local new_row = chat_pos[1] + chat_win_height - total_height

	-- Update input popup size and position
	vim.api.nvim_win_set_height(state.winid, new_height)
	vim.api.nvim_win_set_config(state.popup.winid, {
		relative = "editor",
		row = new_row,
		col = chat_pos[2],
	})

	-- Update info bar position (below input)
	vim.api.nvim_win_set_config(state.info_popup.winid, {
		relative = "editor",
		row = new_row + new_height,
		col = chat_pos[2],
	})
end


-- Navigate history
local function history_prev()
	if history.index > 1 then
		history.index = history.index - 1
		local text = history.entries[history.index]
		local padding = state.config and state.config.padding_top or 0
		local left_padding = state.config and state.config.padding_left or 0
		local left_spaces = left_padding > 0 and string.rep(" ", left_padding) or ""
		-- Preserve padding lines and set content after them
		local padding_lines = {}
		for _ = 1, padding do
			table.insert(padding_lines, left_spaces)
		end
		local content_lines = vim.split(text, "\n")
		for _, line in ipairs(content_lines) do
			table.insert(padding_lines, left_spaces .. line)
		end
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, padding_lines)
		vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), left_padding })
		resize_input()
	end
end


local function history_next()
	local padding = state.config and state.config.padding_top or 0
	local left_padding = state.config and state.config.padding_left or 0
	local left_spaces = left_padding > 0 and string.rep(" ", left_padding) or ""
	local padding_lines = {}
	for _ = 1, padding do
		table.insert(padding_lines, left_spaces)
	end

	if history.index < #history.entries then
		history.index = history.index + 1
		local text = history.entries[history.index]
		local content_lines = vim.split(text, "\n")
		for _, line in ipairs(content_lines) do
			table.insert(padding_lines, left_spaces .. line)
		end
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, padding_lines)
		vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), left_padding })
		resize_input()
	elseif history.index == #history.entries then
		history.index = history.index + 1
		table.insert(padding_lines, left_spaces)
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, padding_lines)
		vim.api.nvim_win_set_cursor(state.winid, { padding + 1, left_padding })
		resize_input()
	end
end


-- Stash current input
local function stash_input()
	local text = get_input_text()
	if text ~= "" then
		history.stashed = text
		local padding = state.config and state.config.padding_top or 0
		local left_padding = state.config and state.config.padding_left or 0
		local left_spaces = left_padding > 0 and string.rep(" ", left_padding) or ""
		local padding_lines = {}
		for _ = 1, padding do
			table.insert(padding_lines, left_spaces)
		end
		table.insert(padding_lines, left_spaces)
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, padding_lines)
		vim.api.nvim_win_set_cursor(state.winid, { padding + 1, left_padding })
		resize_input()
		vim.notify("Input stashed (restore with <C-r>)", vim.log.levels.INFO)
	end
end


-- Restore stashed input
local function restore_input()
	if history.stashed then
		local padding = state.config and state.config.padding_top or 0
		local left_padding = state.config and state.config.padding_left or 0
		local left_spaces = left_padding > 0 and string.rep(" ", left_padding) or ""
		local padding_lines = {}
		for _ = 1, padding do
			table.insert(padding_lines, left_spaces)
		end
		local content_lines = vim.split(history.stashed, "\n")
		for _, line in ipairs(content_lines) do
			table.insert(padding_lines, left_spaces .. line)
		end
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, padding_lines)
		vim.api.nvim_win_set_cursor(state.winid, { vim.api.nvim_buf_line_count(state.bufnr), left_padding })
		history.stashed = nil
		resize_input()
	else
		vim.notify("No stashed input", vim.log.levels.WARN)
	end
end


local function setup_buffer()
	local bufnr = vim.api.nvim_create_buf(false, true)

	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "wipe"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode_input"
	vim.api.nvim_buf_set_var(bufnr, "completion", false)
	return bufnr
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
	vim.api.nvim_buf_add_highlight(info_bufnr, NS_INFO, "OpenCodeInputAgent", 0, col_offset, col_offset + #agent_part)
	col_offset = col_offset + #agent_part
	if model_part ~= "" then
		vim.api.nvim_buf_add_highlight(
			info_bufnr,
			NS_INFO,
			"OpenCodeInputModel",
			0,
			col_offset,
			col_offset + #model_part
		)
		col_offset = col_offset + #model_part
	end
	if provider_part ~= "" then
		vim.api.nvim_buf_add_highlight(
			info_bufnr,
			NS_INFO,
			"OpenCodeInputProvider",
			0,
			col_offset,
			col_offset + #provider_part
		)
		col_offset = col_offset + #provider_part
	end
	if dot_part ~= "" then
		vim.api.nvim_buf_add_highlight(info_bufnr, NS_INFO, "OpenCodeInputDot", 0, col_offset, col_offset + #dot_part)
		col_offset = col_offset + #dot_part
	end
	if variant_part ~= "" then
		vim.api.nvim_buf_add_highlight(
			info_bufnr,
			NS_INFO,
			"OpenCodeInputVariant",
			0,
			col_offset,
			col_offset + #variant_part
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
	local total_height = height + info_height
	local width = chat_win_width

	-- Position at the bottom of the chat window
	local row = chat_pos[1] + chat_win_height - total_height
	local col = chat_pos[2]

	-- Left-only border: only the left side has a visible character.
	-- nui border style order: top-left, top, top-right, right, bottom-right, bottom, bottom-left, left
	-- Empty strings "" = no border on that side (no space consumed)
	local left_border = { "", "", "", "", "", "", "", "┃" }

	-- Create textarea popup with colored left border
	state.bufnr = setup_buffer()
	state.popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = left_border,
		},
		position = { row = row, col = col },
		size = { width = width - 1, height = height },
		bufnr = state.bufnr,
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg,FloatBorder:OpenCodeInputBorder",
			cursorline = false,
			wrap = true,
			linebreak = true,
			signcolumn = "no",
			number = false,
			relativenumber = false,
		},
	})

	-- Create info bar popup (below textarea)
	local info_bufnr = vim.api.nvim_create_buf(false, true)
	vim.bo[info_bufnr].buftype = "nofile"
	vim.bo[info_bufnr].bufhidden = "wipe"

	state.info_popup = Popup({
		enter = false,
		focusable = false,
		border = {
			style = { "", "", "", "", "", "", "", "┃" },
		},
		position = { row = row + height, col = col },
		size = { width = width - 1, height = info_height },
		bufnr = info_bufnr,
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputInfo,FloatBorder:OpenCodeInputBorder",
			signcolumn = "no",
			number = false,
			relativenumber = false,
		},
	})

	-- Mount popups
	state.popup:mount()
	state.info_popup:mount()

	state.winid = state.popup.winid
	state.visible = true

	-- Add top padding by inserting empty lines at the start
	if cfg.padding_top > 0 or cfg.padding_left > 0 then
		local padding_lines = {}
		local left_spaces = cfg.padding_left > 0 and string.rep(" ", cfg.padding_left) or ""
		for _ = 1, cfg.padding_top do
			table.insert(padding_lines, left_spaces)
		end
		-- Add content line with left padding
		table.insert(padding_lines, left_spaces)
		vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, padding_lines)
		-- Move cursor to after the padding
		vim.api.nvim_win_set_cursor(state.winid, { cfg.padding_top + 1, cfg.padding_left })
	end

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

	-- Info bar highlights: agent (accent), model (normal), provider (muted), dot (muted), variant (warning/bold)
	local col_offset = 0
	vim.api.nvim_buf_add_highlight(info_bufnr, NS_INFO, "OpenCodeInputAgent", 0, col_offset, col_offset + #agent_part)
	col_offset = col_offset + #agent_part
	if model_part ~= "" then
		vim.api.nvim_buf_add_highlight(
			info_bufnr,
			NS_INFO,
			"OpenCodeInputModel",
			0,
			col_offset,
			col_offset + #model_part
		)
		col_offset = col_offset + #model_part
	end
	if provider_part ~= "" then
		vim.api.nvim_buf_add_highlight(
			info_bufnr,
			NS_INFO,
			"OpenCodeInputProvider",
			0,
			col_offset,
			col_offset + #provider_part
		)
		col_offset = col_offset + #provider_part
	end
	if dot_part ~= "" then
		vim.api.nvim_buf_add_highlight(info_bufnr, NS_INFO, "OpenCodeInputDot", 0, col_offset, col_offset + #dot_part)
		col_offset = col_offset + #dot_part
	end
	if variant_part ~= "" then
		vim.api.nvim_buf_add_highlight(
			info_bufnr,
			NS_INFO,
			"OpenCodeInputVariant",
			0,
			col_offset,
			col_offset + #variant_part
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
