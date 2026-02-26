-- opencode.nvim - Log Viewer UI module
-- Split window for viewing plugin logs using nui.nvim components

local M = {}

local NuiSplit = require("nui.split")
local NuiLine = require("nui.line")
local NuiText = require("nui.text")

local hl_ns = vim.api.nvim_create_namespace("opencode_log_viewer")

-- Default configuration
local defaults = {
	position = "bottom", -- "bottom" | "top" | "left" | "right"
	width = 80, -- for left/right splits
	height = 15, -- for top/bottom splits
	level_highlights = {
		DEBUG = "Comment",
		INFO = "Normal",
		WARN = "WarningMsg",
		ERROR = "ErrorMsg",
	},
}

-- State
local state = {
	split = nil, -- NuiSplit instance
	visible = false,
	auto_scroll = true,
	config = nil,
	-- Data layer: flat list of entries (message.part.updated replaces in-place)
	entries = {}, -- log entry objects
	entries_log_count = 0, -- raw log count consumed into entries
	header_line_count = 0,
}

---------------------------------------------------------------
-- Rendering helpers
---------------------------------------------------------------

-- Build NuiLines for a single log entry (raw JSON output)
local function build_entry_lines(entry, cfg)
	local lines = {}

	-- Header: timestamp [LEVEL] message
	local header = NuiLine()
	header:append(NuiText(entry.timestamp .. " ", "Comment"))
	local level_hl = cfg.level_highlights[entry.level] or "Normal"
	header:append(NuiText("[" .. entry.level .. "] ", level_hl))
	header:append(NuiText(entry.message))
	table.insert(lines, header)

	-- Raw JSON data (always shown, no folding)
	if entry.data then
		local ok, json_str = pcall(vim.json.encode, entry.data)
		if not ok then
			json_str = vim.inspect(entry.data)
		end
		for line in json_str:gmatch("[^\n]+") do
			local data_line = NuiLine()
			data_line:append(NuiText("  " .. line, "Comment"))
			table.insert(lines, data_line)
		end
	end

	-- Separator
	table.insert(lines, NuiLine())

	return lines
end

---------------------------------------------------------------
-- Data layer
---------------------------------------------------------------

-- Check if entry is a message.part.updated SSE event.
-- Returns messageID string or nil.
local function get_part_message_id(entry)
	local d = entry.data and entry.data.data
	if type(d) == "table" and d.part and d.part.messageID then
		return d.part.messageID
	end
	return nil
end

-- Search state.entries backwards (up to 100) for an entry with matching messageID.
-- Returns entry index or nil.
local function find_entry_by_message_id(message_id)
	for i = #state.entries, math.max(1, #state.entries - 99), -1 do
		local mid = get_part_message_id(state.entries[i])
		if mid == message_id then
			return i
		end
	end
	return nil
end

-- Rebuild state.entries from raw logs (full rebuild)
local function rebuild_entries()
	local logger = require("opencode.logger")
	local logs, log_start = logger.get_logs()
	state.entries = {}

	for i = log_start, #logs do
		local entry = logs[i]
		local mid = get_part_message_id(entry)
		local target = mid and find_entry_by_message_id(mid)

		if target then
			-- Replace existing entry with same messageID
			state.entries[target] = entry
		else
			table.insert(state.entries, entry)
		end
	end

	state.entries_log_count = #logs
end

-- Ingest a single entry into state.entries incrementally.
-- Returns: action ("replace"|"append"), entry_index
local function ingest_entry(entry)
	local mid = get_part_message_id(entry)

	if mid then
		local target = find_entry_by_message_id(mid)
		if target then
			-- Replace existing entry in-place
			state.entries[target] = entry
			return "replace", target
		end
	end

	table.insert(state.entries, entry)
	return "append", #state.entries
end

---------------------------------------------------------------
-- Config (preserved)
---------------------------------------------------------------

-- Get merged config
local function get_config()
	if state.config then
		return state.config
	end

	-- Try to get config from main module
	local ok, config_module = pcall(require, "opencode.config")
	if ok and config_module.defaults and config_module.defaults.logs then
		return vim.tbl_deep_extend("force", defaults, config_module.defaults.logs)
	end

	return defaults
end

---------------------------------------------------------------
-- Helpers
---------------------------------------------------------------

local function get_win_width()
	if state.split and state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
		return vim.api.nvim_win_get_width(state.split.winid)
	end
	return 80
end

local function build_header_lines(log_count)
	local lines = {}
	local win_width = get_win_width()

	-- Title
	local title = NuiLine()
	title:append(NuiText(string.format(" OpenCode Logs (%d entries) ", log_count), "Title"))
	table.insert(lines, title)

	-- Separator
	local sep = NuiLine()
	sep:append(NuiText(string.rep("═", win_width - 2), "Comment"))
	table.insert(lines, sep)

	-- Empty line
	table.insert(lines, NuiLine())

	-- Auto-scroll indicator
	local indicator = NuiLine()
	if state.auto_scroll then
		indicator:append(NuiText(" [Auto-scroll ON - press 'a' to toggle] ", "Comment"))
	else
		indicator:append(NuiText(" [Auto-scroll OFF - press 'a' to toggle] ", "Comment"))
	end
	table.insert(lines, indicator)

	-- Empty line
	table.insert(lines, NuiLine())

	return lines
end

local function is_valid_win(winid)
	return type(winid) == "number" and vim.api.nvim_win_is_valid(winid)
end

local function is_valid_buf(bufnr)
	return type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)
end

local function split_has_window(split)
	return split ~= nil and is_valid_win(split.winid)
end

local function split_has_buffer(split)
	return split ~= nil and is_valid_buf(split.bufnr)
end

local function get_fallback_win()
	local ok, current = pcall(vim.api.nvim_get_current_win)
	if ok and is_valid_win(current) then
		return current
	end

	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if is_valid_win(winid) then
			return winid
		end
	end

	return nil
end

local function ensure_current_win()
	local winid = get_fallback_win()
	if not winid then
		return false
	end

	pcall(vim.api.nvim_set_current_win, winid)
	return true
end

local function reset_split_state()
	if not state.split then
		return
	end

	pcall(function()
		state.split:unmount()
	end)
	state.split = nil
end

local function focus_split()
	if split_has_window(state.split) then
		pcall(vim.api.nvim_set_current_win, state.split.winid)
	end
end

local function try_show_split(split)
	if not split then
		return false
	end

	local ok = pcall(function()
		split:show()
	end)
	if not ok then
		return false
	end

	return split_has_window(split)
end

---------------------------------------------------------------
-- NuiSplit creation
---------------------------------------------------------------

local function create_split(cfg)
	local position = cfg.position or "bottom"
	local is_vertical = position == "left" or position == "right"
	local size
	if is_vertical then
		size = { width = cfg.width or 80 }
	else
		size = { height = cfg.height or 15 }
	end

	local split = NuiSplit({
		relative = "editor",
		position = position,
		size = size,
		enter = false,
		buf_options = {
			buftype = "nofile",
			bufhidden = "hide",
			swapfile = false,
			filetype = "opencode_logs",
			modifiable = false,
		},
		win_options = {
			winhighlight = "Cursor:OpenCodeHiddenCursor,lCursor:OpenCodeHiddenCursor,CursorLine:OpenCodeHiddenCursor,CursorColumn:OpenCodeHiddenCursor",
			cursorline = false,
			cursorcolumn = false,
			number = false,
			relativenumber = false,
			signcolumn = "no",
			wrap = false,
			winfixwidth = is_vertical,
			winfixheight = not is_vertical,
		},
	})

	return split
end

---------------------------------------------------------------
-- Keymap setup
---------------------------------------------------------------

local function setup_keymaps(split)
	local opts = { noremap = true, silent = true }

	-- Close
	split:map("n", "q", function()
		M.close()
	end, opts)
	split:map("n", "<Esc>", function()
		M.close()
	end, opts)

	-- Clear
	split:map("n", "C", function()
		M.clear_logs()
	end, opts)

	-- Auto-scroll toggle
	split:map("n", "a", function()
		M.toggle_auto_scroll()
	end, opts)

	-- Refresh
	split:map("n", "r", function()
		M.refresh()
	end, opts)

	-- Help
	split:map("n", "?", function()
		M.show_help()
	end, opts)
end

local function try_mount_split(cfg)
	state.split = create_split(cfg)
	setup_keymaps(state.split)

	local ok, err = pcall(function()
		state.split:mount()
	end)
	if not ok then
		return false, err
	end

	if not split_has_window(state.split) then
		return false, "split did not create a valid window"
	end

	return true, nil
end

---------------------------------------------------------------
-- Full render
---------------------------------------------------------------

function M.refresh()
	if not state.split or not state.split.bufnr or not vim.api.nvim_buf_is_valid(state.split.bufnr) then
		return
	end

	local cfg = get_config()
	local bufnr = state.split.bufnr

	-- Rebuild data layer from raw logs
	rebuild_entries()

	-- Build header
	local visible_count = state.entries_log_count
	local header_lines = build_header_lines(visible_count)
	state.header_line_count = #header_lines

	-- Collect all content strings and NuiLine references
	local all_content = {}
	local all_nui_lines = {}

	for _, nui_line in ipairs(header_lines) do
		table.insert(all_content, nui_line:content())
		table.insert(all_nui_lines, nui_line)
	end

	for _, entry in ipairs(state.entries) do
		for _, nui_line in ipairs(build_entry_lines(entry, cfg)) do
			table.insert(all_content, nui_line:content())
			table.insert(all_nui_lines, nui_line)
		end
	end

	-- Write buffer in one shot
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, -1)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, all_content)

	-- Apply highlights
	for i, nui_line in ipairs(all_nui_lines) do
		nui_line:highlight(bufnr, hl_ns, i)
	end

	vim.bo[bufnr].modifiable = false

	-- Auto-scroll to bottom
	if state.auto_scroll and state.visible and state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(bufnr)
		vim.api.nvim_win_set_cursor(state.split.winid, { buf_lines, 0 })
	end

	vim.cmd("redraw")
end

---------------------------------------------------------------
-- Incremental render
---------------------------------------------------------------

-- Render a single entry incrementally (for live updates)
function M.render_entry(entry)
	if not state.split or not state.split.bufnr or not vim.api.nvim_buf_is_valid(state.split.bufnr) then
		return
	end

	local logger = require("opencode.logger")
	local logs = logger.get_logs()

	-- Fall back to full refresh if incremental state is invalid
	if state.entries_log_count == 0 or #logs ~= state.entries_log_count + 1 then
		M.refresh()
		return
	end

	local cfg = get_config()
	local bufnr = state.split.bufnr

	-- Ingest into data layer
	local action, _ = ingest_entry(entry)
	state.entries_log_count = #logs

	if action == "replace" then
		-- Data changed in-place, just do full refresh
		M.refresh()
		return
	end

	-- New entry: append to buffer
	vim.bo[bufnr].modifiable = true

	local entry_lines = build_entry_lines(state.entries[#state.entries], cfg)
	local buf_end = vim.api.nvim_buf_line_count(bufnr)

	local content_lines = {}
	for _, nui_line in ipairs(entry_lines) do
		table.insert(content_lines, nui_line:content())
	end
	vim.api.nvim_buf_set_lines(bufnr, buf_end, buf_end, false, content_lines)

	for i, nui_line in ipairs(entry_lines) do
		nui_line:highlight(bufnr, hl_ns, buf_end + i)
	end

	-- Update header count
	local header_text = string.format(" OpenCode Logs (%d entries) ", #logs)
	vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { header_text })
	vim.api.nvim_buf_clear_namespace(bufnr, hl_ns, 0, 1)
	vim.api.nvim_buf_set_extmark(bufnr, hl_ns, 0, 0, { end_col = #header_text, hl_group = "Title" })

	vim.bo[bufnr].modifiable = false

	-- Auto-scroll to bottom
	if state.auto_scroll and state.visible and state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(bufnr)
		vim.api.nvim_win_set_cursor(state.split.winid, { buf_lines, 0 })
	end

	vim.cmd("redraw")
end

---------------------------------------------------------------
-- Public API
---------------------------------------------------------------

-- Open log viewer in a split
function M.open(opts)
	opts = opts or {}

	if state.visible and split_has_window(state.split) then
		focus_split()
		return
	end

	if state.visible and not split_has_window(state.split) then
		state.visible = false
	end

	-- Merge config with any provided options
	local cfg = get_config()
	if opts.position then
		cfg.position = opts.position
	end
	if opts.width then
		cfg.width = opts.width
	end
	if opts.height then
		cfg.height = opts.height
	end
	state.config = cfg

	local opened = false
	local open_err = nil

	if state.split and split_has_buffer(state.split) then
		ensure_current_win()
		opened = try_show_split(state.split)
		if not opened then
			reset_split_state()
		end
	elseif state.split then
		reset_split_state()
	end

	if not opened then
		ensure_current_win()
		local ok, err = try_mount_split(cfg)
		if not ok then
			open_err = tostring(err)
			reset_split_state()

			-- Retry once, forcing a valid current window before mounting.
			ensure_current_win()
			ok, err = try_mount_split(cfg)
			if not ok then
				open_err = tostring(err)
				reset_split_state()
				state.visible = false
				vim.notify("Failed to open OpenCode log viewer: " .. open_err, vim.log.levels.ERROR)
				return
			end
		end
	end

	state.visible = true
	focus_split()

	-- Initial render
	M.refresh()

	-- Auto-scroll to bottom
	if state.auto_scroll and split_has_window(state.split) and split_has_buffer(state.split) then
		local buf_lines = vim.api.nvim_buf_line_count(state.split.bufnr)
		if buf_lines > 0 then
			vim.api.nvim_win_set_cursor(state.split.winid, { buf_lines, 0 })
		end
	end
end

-- Close log viewer
function M.close()
	if not state.visible then
		return
	end

	if state.split then
		pcall(function()
			state.split:hide()
		end)
	end

	state.visible = false
end

-- Toggle visibility
function M.toggle(opts)
	if state.visible then
		M.close()
	else
		M.open(opts)
	end
end

-- Check if visible
function M.is_visible()
	return state.visible and split_has_window(state.split)
end

-- Clear logs
function M.clear_logs()
	local logger = require("opencode.logger")
	logger.clear()
	state.entries = {}
	state.entries_log_count = 0
	M.refresh()
	vim.notify("Logs cleared", vim.log.levels.INFO)
end

-- Toggle auto-scroll
function M.toggle_auto_scroll()
	state.auto_scroll = not state.auto_scroll
	M.refresh()
	vim.notify(string.format("Auto-scroll %s", state.auto_scroll and "enabled" or "disabled"), vim.log.levels.INFO)
end

-- Show help (preserved - already uses nui.popup)
function M.show_help()
	local lines = {
		" Log Viewer Keymaps ",
		"",
		" q / <Esc>  - Close viewer",
		" j / k      - Scroll line by line",
		" <C-u>      - Scroll up half page",
		" <C-d>      - Scroll down half page",
		" gg         - Go to top",
		" G          - Go to bottom",
		" C          - Clear all logs",
		" a          - Toggle auto-scroll",
		" r          - Refresh",
		" ?          - Show this help",
		"",
		" Press any key to close",
	}

	local width = 38
	local height = #lines
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

	local Popup = require("nui.popup")
	local popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = { top = " Help ", top_align = "center" },
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
	})

	popup:mount()
	vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
	vim.bo[popup.bufnr].modifiable = false

	-- Close on any key
	local close_keys = { "q", "<Esc>", "<CR>", "<Space>" }
	for _, key in ipairs(close_keys) do
		vim.keymap.set("n", key, function()
			popup:unmount()
		end, { buffer = popup.bufnr, noremap = true, silent = true })
	end

	for i = 32, 126 do
		local char = string.char(i)
		if not char:match("[qQ]") then
			pcall(function()
				vim.keymap.set("n", char, function()
					popup:unmount()
				end, { buffer = popup.bufnr, noremap = true, silent = true, nowait = true })
			end)
		end
	end
end

-- Setup with user config
function M.setup(opts)
	state.config = vim.tbl_deep_extend("force", defaults, opts or {})
end

return M
