-- opencode.nvim - Log Viewer UI module
-- Split window for viewing plugin logs

local M = {}

local hl_ns = vim.api.nvim_create_namespace("opencode_log_viewer")

-- State
local state = {
	bufnr = nil,
	winid = nil,
	visible = false,
	auto_scroll = true,
	config = nil,
	folded = {}, -- Track folded entries by index: { [entry_index] = true }
	entry_lines = {}, -- Map line numbers to entry indices for fold toggling
}

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

-- Setup buffer options
local function setup_buffer(bufnr)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = "opencode_logs"
	vim.bo[bufnr].modifiable = false

	-- Buffer-local keymaps
	local opts = { buffer = bufnr, noremap = true, silent = true }

	-- Close
	vim.keymap.set("n", "q", function()
		M.close()
	end, opts)

	vim.keymap.set("n", "<Esc>", function()
		M.close()
	end, opts)

	-- Scroll
	vim.keymap.set("n", "<C-u>", "<C-u>", opts)
	vim.keymap.set("n", "<C-d>", "<C-d>", opts)
	vim.keymap.set("n", "gg", "gg", opts)
	vim.keymap.set("n", "G", "G", opts)

	-- Clear logs
	vim.keymap.set("n", "C", function()
		M.clear_logs()
	end, opts)

	-- Toggle auto-scroll
	vim.keymap.set("n", "a", function()
		M.toggle_auto_scroll()
	end, opts)

	-- Refresh
	vim.keymap.set("n", "r", function()
		M.refresh()
	end, opts)

	-- Help
	vim.keymap.set("n", "?", function()
		M.show_help()
	end, opts)

	-- Toggle fold on current line
	vim.keymap.set("n", "<CR>", function()
		M.toggle_fold_at_cursor()
	end, opts)

	vim.keymap.set("n", "o", function()
		M.toggle_fold_at_cursor()
	end, opts)

	vim.keymap.set("n", "<Tab>", function()
		M.toggle_fold_at_cursor()
	end, opts)

	-- Fold all / Unfold all
	vim.keymap.set("n", "zM", function()
		M.fold_all()
	end, opts)

	vim.keymap.set("n", "zR", function()
		M.unfold_all()
	end, opts)

	vim.keymap.set("n", "f", function()
		M.fold_all()
	end, opts)

	vim.keymap.set("n", "F", function()
		M.unfold_all()
	end, opts)
end

-- Create buffer
local function create_buffer()
	if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
		return state.bufnr
	end

	state.bufnr = vim.api.nvim_create_buf(false, true)
	setup_buffer(state.bufnr)
	return state.bufnr
end

-- Extract messageID from a log entry's data (checks common SSE event shapes)
local function extract_message_id(entry)
	if not entry.data then
		return nil
	end
	local d = entry.data.data
	if not d then
		return nil
	end
	-- message.part.updated: data.data.part.messageID
	if type(d) == "table" and d.part and d.part.messageID then
		return d.part.messageID
	end
	-- message.updated: data.data.info.id
	if type(d) == "table" and d.info and d.info.id then
		return d.info.id
	end
	-- message.removed / message.part.removed: data.data.messageID
	if type(d) == "table" and d.messageID then
		return d.messageID
	end
	return nil
end

-- Group consecutive log entries by messageID into squashed groups
-- Returns array of { message_id = string|nil, entries = {entry...} }
---@param logs table The log array
---@param start_index number 1-based index to start from
local function squash_logs(logs, start_index)
	local groups = {}
	local current_group = nil

	for i = start_index, #logs do
		local entry = logs[i]
		local mid = extract_message_id(entry)
		if mid and current_group and current_group.message_id == mid then
			table.insert(current_group.entries, entry)
		else
			current_group = {
				message_id = mid,
				entries = { entry },
			}
			table.insert(groups, current_group)
		end
	end

	return groups
end

-- Format a squashed group of log entries for display
---@param group table Squashed group { message_id, entries, original_indices }
---@param cfg table Config
---@param group_index number Index of group for fold tracking
---@param is_folded boolean Whether this group is folded
local function format_squashed_group(group, cfg, group_index, is_folded)
	local entries = group.entries
	local count = #entries
	local last_entry = entries[count]

	-- Single entry or no messageID — render normally
	if count == 1 or not group.message_id then
		return format_entry(last_entry, cfg, group_index, is_folded)
	end

	-- Squashed group: show summary header
	local lines = {}
	local highlights = {}

	local fold_icon = is_folded and "▶ " or "▼ "
	local short_id = group.message_id:sub(1, 8)
	local header = string.format(
		"%s%s [%s] [msg:%s] %s (%d events)",
		fold_icon,
		last_entry.timestamp,
		last_entry.level,
		short_id,
		last_entry.message,
		count
	)
	table.insert(lines, header)

	-- Highlight fold icon
	table.insert(highlights, {
		line = 0,
		col_start = 0,
		col_end = #fold_icon,
		hl_group = "Special",
	})

	-- Highlight the count badge
	local count_str = string.format("(%d events)", count)
	table.insert(highlights, {
		line = 0,
		col_start = #header - #count_str,
		col_end = #header,
		hl_group = "WarningMsg",
	})

	if is_folded then
		-- Show one-line preview of all event types
		local event_types = {}
		for _, entry in ipairs(entries) do
			local msg_short = entry.message:match("^(%S+)") or entry.message
			event_types[msg_short] = (event_types[msg_short] or 0) + 1
		end
		local parts = {}
		for ev, c in pairs(event_types) do
			table.insert(parts, string.format("%s×%d", ev, c))
		end
		local preview = "  " .. table.concat(parts, ", ")
		table.insert(lines, preview)
		table.insert(highlights, {
			line = 1,
			col_start = 0,
			col_end = #preview,
			hl_group = "Comment",
		})
	else
		-- Expanded: show each entry as a sub-line
		for j, entry in ipairs(entries) do
			local connector = j == count and "└" or "├"
			local level_hl = cfg.level_highlights[entry.level] or "Normal"
			local sub_line = string.format("  %s %s [%s] %s", connector, entry.timestamp, entry.level, entry.message)
			table.insert(lines, sub_line)
			table.insert(highlights, {
				line = #lines - 1,
				col_start = 0,
				col_end = #sub_line,
				hl_group = level_hl,
			})

			-- Show data for this sub-entry if present
			if entry.data then
				local data_str = vim.inspect(entry.data)
				local win_width = state.winid and vim.api.nvim_win_get_width(state.winid) or 80
				local max_line_length = win_width - 8
				local indent = "    "
				for line in data_str:gmatch("[^\n]+") do
					if #line > max_line_length then
						table.insert(lines, indent .. line:sub(1, max_line_length - 3) .. "...")
					else
						table.insert(lines, indent .. line)
					end
				end
			end
		end
	end

	-- Empty line separator
	table.insert(lines, "")

	return lines, highlights
end

-- Format log entry for display
---@param entry table Log entry
---@param cfg table Config
---@param entry_index number Index of entry for fold tracking
---@param is_folded boolean Whether this entry is folded
local function format_entry(entry, cfg, entry_index, is_folded)
	local lines = {}
	local highlights = {}

	-- Fold indicator
	local fold_icon = ""
	if entry.data then
		fold_icon = is_folded and "▶ " or "▼ "
	else
		fold_icon = "  "
	end

	-- Header line with timestamp and level
	local level_indicator = string.format("[%s]", entry.level)
	local header = string.format("%s%s %s %s", fold_icon, entry.timestamp, level_indicator, entry.message)
	table.insert(lines, header)

	-- Highlight for the fold icon
	if entry.data then
		table.insert(highlights, {
			line = 0,
			col_start = 0,
			col_end = #fold_icon,
			hl_group = "Special",
		})
	end

	-- Highlight for the level
	local hl_group = cfg.level_highlights[entry.level] or "Normal"
	table.insert(highlights, {
		line = 0,
		col_start = #fold_icon + 9, -- After fold icon and timestamp
		col_end = #fold_icon + 9 + #level_indicator,
		hl_group = hl_group,
	})

	-- Data if present and not folded
	if entry.data then
		if is_folded then
			-- Show collapsed preview
			local data_str = vim.inspect(entry.data)
			local first_line = data_str:match("^[^\n]+") or "{...}"
			local preview = "  " .. first_line:sub(1, 60)
			if #first_line > 60 then
				preview = preview .. "..."
			end
			table.insert(lines, preview)
			table.insert(highlights, {
				line = 1,
				col_start = 0,
				col_end = #preview,
				hl_group = "Comment",
			})
		else
			-- Show full data
			local data_str = vim.inspect(entry.data)
			-- Get window width for wrapping
			local win_width = state.winid and vim.api.nvim_win_get_width(state.winid) or 80
			local max_line_length = win_width - 4
			local indent = "  "

			for line in data_str:gmatch("[^\n]+") do
				if #line > max_line_length then
					-- Truncate long lines
					table.insert(lines, indent .. line:sub(1, max_line_length - 3) .. "...")
				else
					table.insert(lines, indent .. line)
				end
			end
		end
	end

	-- Empty line separator
	table.insert(lines, "")

	return lines, highlights
end

-- Open log viewer in a split
function M.open(opts)
	opts = opts or {}

	if state.visible then
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			vim.api.nvim_set_current_win(state.winid)
		end
		return
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

	create_buffer()

	-- Determine split command based on position
	local split_cmd
	if cfg.position == "bottom" then
		split_cmd = string.format("botright %dsplit", cfg.height)
	elseif cfg.position == "top" then
		split_cmd = string.format("topleft %dsplit", cfg.height)
	elseif cfg.position == "left" then
		split_cmd = string.format("topleft %dvsplit", cfg.width)
	else -- right
		split_cmd = string.format("botright %dvsplit", cfg.width)
	end

	-- Create split window
	vim.cmd(split_cmd)
	state.winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(state.winid, state.bufnr)

	-- Set window options
	if cfg.position == "left" or cfg.position == "right" then
		vim.wo[state.winid].winfixwidth = true
		vim.api.nvim_win_set_width(state.winid, cfg.width)
	else
		vim.wo[state.winid].winfixheight = true
		vim.api.nvim_win_set_height(state.winid, cfg.height)
	end

	-- Mark as scratch buffer
	vim.bo[state.bufnr].bufhidden = "hide"

	state.visible = true

	-- Initial render
	M.refresh()

	-- Auto-scroll to bottom
	if state.auto_scroll and state.winid then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
	end
end

-- Close log viewer
function M.close()
	if not state.visible then
		return
	end

	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_close(state.winid, true)
	end

	state.visible = false
	state.winid = nil
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
	return state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid)
end

-- Refresh all logs
function M.refresh()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local logger = require("opencode.logger")
	local logs, log_start = logger.get_logs(100)
	local cfg = get_config()

	local all_lines = {}
	local all_highlights = {}
	local current_line = 0

	-- Header
	local visible_count = #logs - log_start + 1
	local header_text = string.format(" OpenCode Logs (%d entries) ", visible_count)
	table.insert(all_lines, header_text)
	table.insert(all_highlights, { line = 0, col_start = 0, col_end = #header_text, hl_group = "Title" })

	-- Get window width for separator
	local win_width = state.winid and vim.api.nvim_win_get_width(state.winid) or 80
	table.insert(all_lines, string.rep("═", win_width - 2))
	table.insert(all_lines, "")
	current_line = 3

	-- Auto-scroll indicator
	if state.auto_scroll then
		table.insert(all_lines, " [Auto-scroll ON - press 'a' to toggle] ")
	else
		table.insert(all_lines, " [Auto-scroll OFF - press 'a' to toggle] ")
	end
	table.insert(all_highlights, { line = current_line, col_start = 0, col_end = 40, hl_group = "Comment" })
	table.insert(all_lines, "")
	current_line = current_line + 2

	-- Clear line-to-entry mapping
	state.entry_lines = {}

	-- Squash consecutive entries with the same messageID
	local groups = squash_logs(logs, log_start)

	-- Each squashed group
	for group_index, group in ipairs(groups) do
		local is_folded = state.folded[group_index] == true
		local lines, highlights

		if #group.entries > 1 and group.message_id then
			lines, highlights = format_squashed_group(group, cfg, group_index, is_folded)
		else
			lines, highlights = format_entry(group.entries[1], cfg, group_index, is_folded)
		end

		-- Map the header line to this group index for fold toggling
		state.entry_lines[current_line + 1] = group_index -- +1 because nvim lines are 1-indexed

		for _, line in ipairs(lines) do
			table.insert(all_lines, line)
		end

		for _, hl in ipairs(highlights) do
			hl.line = current_line + hl.line
			table.insert(all_highlights, hl)
		end

		current_line = current_line + #lines
	end

	-- Render to buffer
	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, all_lines)

	-- Apply highlights
	for _, hl in ipairs(all_highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(state.bufnr, hl.line, hl.line + 1, false)[1]
			end_col = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(state.bufnr, hl_ns, hl.line, hl.col_start, { end_col = end_col, hl_group = hl.hl_group })
	end

	vim.bo[state.bufnr].modifiable = false

	-- Auto-scroll to bottom if enabled
	if state.auto_scroll and state.visible and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		local buf_lines = vim.api.nvim_buf_line_count(state.bufnr)
		vim.api.nvim_win_set_cursor(state.winid, { buf_lines, 0 })
	end

	-- Force redraw to show updates immediately
	vim.cmd("redraw")
end

-- Render a single entry (for live updates)
function M.render_entry(entry)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	-- Just do a full refresh for simplicity and consistency
	M.refresh()
end

-- Clear logs
function M.clear_logs()
	local logger = require("opencode.logger")
	logger.clear()
	M.refresh()
	vim.notify("Logs cleared", vim.log.levels.INFO)
end

-- Toggle auto-scroll
function M.toggle_auto_scroll()
	state.auto_scroll = not state.auto_scroll
	M.refresh()
	vim.notify(string.format("Auto-scroll %s", state.auto_scroll and "enabled" or "disabled"), vim.log.levels.INFO)
end

-- Toggle fold at cursor position
function M.toggle_fold_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local line_num = cursor[1]

	-- Find the entry index for this line (search backwards to find header line)
	local entry_index = nil
	for l = line_num, 1, -1 do
		if state.entry_lines[l] then
			entry_index = state.entry_lines[l]
			break
		end
	end

	if entry_index then
		state.folded[entry_index] = not state.folded[entry_index]
		M.refresh()
	end
end

-- Fold all entries
function M.fold_all()
	local logger = require("opencode.logger")
	local logs, log_start = logger.get_logs(100)
	local groups = squash_logs(logs, log_start)
	for i, group in ipairs(groups) do
		-- Fold groups that have data or are multi-entry squashed groups
		local has_data = false
		for _, entry in ipairs(group.entries) do
			if entry.data then
				has_data = true
				break
			end
		end
		if has_data or #group.entries > 1 then
			state.folded[i] = true
		end
	end
	M.refresh()
end

-- Unfold all entries
function M.unfold_all()
	state.folded = {}
	M.refresh()
end

-- Show help
function M.show_help()
	local lines = {
		" Log Viewer Keymaps ",
		"",
		" q / <Esc>  - Close viewer",
		" <C-u>      - Scroll up",
		" <C-d>      - Scroll down",
		" gg         - Go to top",
		" G          - Go to bottom",
		" C          - Clear all logs",
		" a          - Toggle auto-scroll",
		" r          - Refresh",
		" ?          - Show this help",
		"",
		" Folding:",
		" <CR>/o/Tab - Toggle fold at cursor",
		" f / zM     - Fold all",
		" F / zR     - Unfold all",
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
