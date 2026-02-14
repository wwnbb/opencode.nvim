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
	-- UI layer
	components = {}, -- LogLine[]
	selected_idx = 0, -- 0 = none selected
	header_line_count = 0,
}

---------------------------------------------------------------
-- Setup highlights
---------------------------------------------------------------

local function setup_highlights()
	vim.api.nvim_set_hl(0, "OpenCodeLogSelected", { link = "CursorLine", default = true })
end

---------------------------------------------------------------
-- LogLine class
---------------------------------------------------------------

local LogLine = {}
LogLine.__index = LogLine

function LogLine.new(opts)
	local self = setmetatable({}, LogLine)
	self.entry = opts.entry
	self.entry_index = opts.entry_index
	self.config = opts.config
	self.win_width = opts.win_width or 80
	self.folded = opts.folded ~= false -- default true
	self.selected = false
	self._lines = {} -- NuiLine[]
	self._buf_start = 0 -- 1-indexed
	self._line_count = 0
	self:_build_lines()
	return self
end

function LogLine:fold()
	self.folded = true
	self:_build_lines()
end

function LogLine:unfold()
	self.folded = false
	self:_build_lines()
end

function LogLine:update(entry)
	self.entry = entry
	self:_build_lines()
end

function LogLine:hover(is_selected)
	self.selected = is_selected
	self:_build_lines()
end

function LogLine:line_count()
	return self._line_count
end

function LogLine:is_foldable()
	return self.entry.data ~= nil
end

function LogLine:_build_lines()
	local lines = {}
	local entry = self.entry
	local cfg = self.config

	-- Header line
	local header = NuiLine()

	-- Selected indicator prefix
	if self.selected then
		header:append(NuiText("▸ ", "OpenCodeLogSelected"))
	else
		header:append(NuiText("  "))
	end

	-- Fold icon
	if entry.data then
		header:append(NuiText(self.folded and "▶ " or "▼ ", "Special"))
	else
		header:append(NuiText("  "))
	end

	header:append(NuiText(entry.timestamp .. " ", "Comment"))

	local level_hl = cfg.level_highlights[entry.level] or "Normal"
	header:append(NuiText("[" .. entry.level .. "] ", level_hl))
	header:append(NuiText(entry.message))

	table.insert(lines, header)

	-- Data lines
	if entry.data then
		if self.folded then
			-- Collapsed preview
			local data_str = vim.inspect(entry.data)
			local first_line = data_str:match("^[^\n]+") or "{...}"
			local preview = first_line:sub(1, 60)
			if #first_line > 60 then
				preview = preview .. "..."
			end
			local preview_line = NuiLine()
			preview_line:append(NuiText("    " .. preview, "Comment"))
			table.insert(lines, preview_line)
		else
			-- Full data
			local data_str = vim.inspect(entry.data)
			local max_line_length = self.win_width - 6
			for line in data_str:gmatch("[^\n]+") do
				local content = line
				if #content > max_line_length then
					content = content:sub(1, max_line_length - 3) .. "..."
				end
				local data_line = NuiLine()
				data_line:append(NuiText("    " .. content, "Comment"))
				table.insert(lines, data_line)
			end
		end
	end

	-- Empty separator line
	table.insert(lines, NuiLine())

	self._lines = lines
	self._line_count = #lines
end

-- Re-render this component in place (replaces its existing buffer region).
-- Only safe when line count has NOT changed (e.g. hover toggle).
function LogLine:rerender(bufnr, ns_id)
	if self._buf_start == 0 then
		return
	end

	local content_lines = {}
	for _, nui_line in ipairs(self._lines) do
		table.insert(content_lines, nui_line:content())
	end

	-- Clear extmarks and replace lines
	vim.api.nvim_buf_clear_namespace(bufnr, ns_id, self._buf_start - 1, self._buf_start - 1 + self._line_count)
	vim.api.nvim_buf_set_lines(bufnr, self._buf_start - 1, self._buf_start - 1 + self._line_count, false, content_lines)

	-- Apply highlights
	for i, nui_line in ipairs(self._lines) do
		nui_line:highlight(bufnr, ns_id, self._buf_start + i - 1)
	end
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
		enter = true,
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

	-- Navigation (virtual cursor)
	split:map("n", "j", function()
		M.move_selection(1)
	end, opts)
	split:map("n", "k", function()
		M.move_selection(-1)
	end, opts)

	-- Scroll
	split:map("n", "<C-u>", function()
		M.scroll_half_page(-1)
	end, opts)
	split:map("n", "<C-d>", function()
		M.scroll_half_page(1)
	end, opts)
	split:map("n", "gg", function()
		M.goto_top()
	end, opts)
	split:map("n", "G", function()
		M.goto_bottom()
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

	-- Fold toggle
	split:map("n", "<CR>", function()
		M.toggle_fold_selected()
	end, opts)
	split:map("n", "o", function()
		M.toggle_fold_selected()
	end, opts)
	split:map("n", "<Tab>", function()
		M.toggle_fold_selected()
	end, opts)

	-- Fold all / unfold all
	split:map("n", "f", function()
		M.fold_all()
	end, opts)
	split:map("n", "zM", function()
		M.fold_all()
	end, opts)
	split:map("n", "F", function()
		M.unfold_all()
	end, opts)
	split:map("n", "zR", function()
		M.unfold_all()
	end, opts)
end

---------------------------------------------------------------
-- Virtual cursor navigation
---------------------------------------------------------------

function M.move_selection(delta)
	local components = state.components
	if #components == 0 then
		return
	end

	local bufnr = state.split and state.split.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	local old_idx = state.selected_idx
	local new_idx = old_idx + delta

	-- Clamp
	if new_idx < 1 then
		new_idx = 1
	end
	if new_idx > #components then
		new_idx = #components
	end
	if new_idx == old_idx then
		return
	end

	vim.bo[bufnr].modifiable = true

	-- Unhover old
	if old_idx >= 1 and old_idx <= #components then
		local old_comp = components[old_idx]
		old_comp:hover(false)
		old_comp:rerender(bufnr, hl_ns)
	end

	-- Hover new
	local new_comp = components[new_idx]
	new_comp:hover(true)
	new_comp:rerender(bufnr, hl_ns)

	vim.bo[bufnr].modifiable = false
	state.selected_idx = new_idx

	-- Scroll to keep selected visible
	if state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
		vim.api.nvim_win_set_cursor(state.split.winid, { new_comp._buf_start, 0 })
	end
end

function M.scroll_half_page(direction)
	if not state.split or not state.split.winid or not vim.api.nvim_win_is_valid(state.split.winid) then
		return
	end
	local win_height = vim.api.nvim_win_get_height(state.split.winid)
	local half = math.floor(win_height / 2)

	-- Move selection by approximately half page worth of components
	local moved = 0
	local lines_moved = 0
	while lines_moved < half do
		local next_idx = state.selected_idx + (direction * (moved + 1))
		if next_idx < 1 or next_idx > #state.components then
			break
		end
		moved = moved + 1
		lines_moved = lines_moved + state.components[next_idx]:line_count()
	end
	if moved > 0 then
		M.move_selection(direction * moved)
	end
end

function M.goto_top()
	if #state.components == 0 or state.selected_idx == 1 then
		return
	end

	local bufnr = state.split and state.split.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.bo[bufnr].modifiable = true

	-- Unhover old
	if state.selected_idx >= 1 and state.selected_idx <= #state.components then
		local old = state.components[state.selected_idx]
		old:hover(false)
		old:rerender(bufnr, hl_ns)
	end

	-- Hover first
	state.selected_idx = 1
	local new_comp = state.components[1]
	new_comp:hover(true)
	new_comp:rerender(bufnr, hl_ns)

	vim.bo[bufnr].modifiable = false

	if state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
		vim.api.nvim_win_set_cursor(state.split.winid, { new_comp._buf_start, 0 })
	end
end

function M.goto_bottom()
	if #state.components == 0 or state.selected_idx == #state.components then
		return
	end

	local bufnr = state.split and state.split.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	vim.bo[bufnr].modifiable = true

	-- Unhover old
	if state.selected_idx >= 1 and state.selected_idx <= #state.components then
		local old = state.components[state.selected_idx]
		old:hover(false)
		old:rerender(bufnr, hl_ns)
	end

	-- Hover last
	state.selected_idx = #state.components
	local new_comp = state.components[state.selected_idx]
	new_comp:hover(true)
	new_comp:rerender(bufnr, hl_ns)

	vim.bo[bufnr].modifiable = false

	if state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
		vim.api.nvim_win_set_cursor(state.split.winid, { new_comp._buf_start, 0 })
	end
end

---------------------------------------------------------------
-- Fold operations
---------------------------------------------------------------

function M.toggle_fold_selected()
	if state.selected_idx < 1 or state.selected_idx > #state.components then
		return
	end

	local comp = state.components[state.selected_idx]
	if not comp:is_foldable() then
		return
	end

	if comp.folded then
		comp:unfold()
	else
		comp:fold()
	end

	-- Line count changed, need full refresh
	M.refresh()
end

function M.fold_all()
	for _, comp in ipairs(state.components) do
		if comp:is_foldable() then
			comp:fold()
		end
	end
	M.refresh()
end

function M.unfold_all()
	for _, comp in ipairs(state.components) do
		if comp:is_foldable() then
			comp:unfold()
		end
	end
	M.refresh()
end

---------------------------------------------------------------
-- Full render
---------------------------------------------------------------

function M.refresh()
	if not state.split or not state.split.bufnr or not vim.api.nvim_buf_is_valid(state.split.bufnr) then
		return
	end

	local cfg = get_config()
	local win_width = get_win_width()
	local bufnr = state.split.bufnr

	-- Rebuild data layer from raw logs
	rebuild_entries()

	-- Build header
	local visible_count = state.entries_log_count
	local header_lines = build_header_lines(visible_count)
	state.header_line_count = #header_lines

	-- Preserve fold state from old components
	local old_fold_state = {}
	for _, comp in ipairs(state.components) do
		old_fold_state[comp.entry_index] = comp.folded
	end

	-- Create new LogLine components from state.entries
	state.components = {}
	for entry_index, entry in ipairs(state.entries) do
		local comp = LogLine.new({
			entry = entry,
			entry_index = entry_index,
			config = cfg,
			win_width = win_width,
			folded = old_fold_state[entry_index],
		})
		table.insert(state.components, comp)
	end

	-- Determine selected_idx
	if state.auto_scroll and #state.components > 0 then
		state.selected_idx = #state.components
	elseif #state.components == 0 then
		state.selected_idx = 0
	elseif state.selected_idx < 1 then
		state.selected_idx = 1
	elseif state.selected_idx > #state.components then
		state.selected_idx = #state.components
	end

	-- Apply hover to selected component
	if state.selected_idx >= 1 and state.selected_idx <= #state.components then
		state.components[state.selected_idx]:hover(true)
	end

	-- Collect all content strings and NuiLine references
	local all_content = {}
	local all_nui_lines = {}

	for _, nui_line in ipairs(header_lines) do
		table.insert(all_content, nui_line:content())
		table.insert(all_nui_lines, nui_line)
	end

	local current_line = state.header_line_count + 1 -- 1-indexed
	for _, comp in ipairs(state.components) do
		comp._buf_start = current_line
		for _, nui_line in ipairs(comp._lines) do
			table.insert(all_content, nui_line:content())
			table.insert(all_nui_lines, nui_line)
		end
		current_line = current_line + comp._line_count
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
	-- (first render, log trimming occurred, or multiple entries added at once)
	if state.entries_log_count == 0 or #logs ~= state.entries_log_count + 1 then
		M.refresh()
		return
	end

	local cfg = get_config()
	local win_width = get_win_width()
	local bufnr = state.split.bufnr

	-- Ingest into data layer
	local action, entry_idx = ingest_entry(entry)
	state.entries_log_count = #logs

	vim.bo[bufnr].modifiable = true

	if action == "replace" then
		-- Entry was replaced in-place; re-render its component
		local comp = state.components[entry_idx]
		if comp then
			local old_line_count = comp:line_count()
			comp:update(state.entries[entry_idx])
			local new_line_count = comp:line_count()

			if new_line_count == old_line_count then
				-- Same line count: replace in place
				comp:rerender(bufnr, hl_ns)
			else
				-- Line count changed: full refresh
				vim.bo[bufnr].modifiable = false
				M.refresh()
				return
			end
		else
			-- Component missing: full refresh
			vim.bo[bufnr].modifiable = false
			M.refresh()
			return
		end
	else
		-- New entry: create component and append to buffer
		local comp = LogLine.new({
			entry = state.entries[entry_idx],
			entry_index = entry_idx,
			config = cfg,
			win_width = win_width,
		})

		local buf_end = vim.api.nvim_buf_line_count(bufnr)
		comp._buf_start = buf_end + 1

		local content_lines = {}
		for _, nui_line in ipairs(comp._lines) do
			table.insert(content_lines, nui_line:content())
		end
		vim.api.nvim_buf_set_lines(bufnr, buf_end, buf_end, false, content_lines)

		for i, nui_line in ipairs(comp._lines) do
			nui_line:highlight(bufnr, hl_ns, comp._buf_start + i - 1)
		end

		table.insert(state.components, comp)
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

	-- Force redraw so changes are visible even without auto-scroll
	vim.cmd("redraw")
end

---------------------------------------------------------------
-- Public API
---------------------------------------------------------------

-- Open log viewer in a split
function M.open(opts)
	opts = opts or {}

	if state.visible then
		if state.split and state.split.winid and vim.api.nvim_win_is_valid(state.split.winid) then
			vim.api.nvim_set_current_win(state.split.winid)
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

	setup_highlights()

	if state.split then
		-- Reuse existing split (show preserves buffer)
		state.split:show()
	else
		-- Create new split
		state.split = create_split(cfg)
		setup_keymaps(state.split)
		state.split:mount()
	end

	state.visible = true

	-- Initial render
	M.refresh()

	-- Auto-scroll to bottom
	if state.auto_scroll and state.split.winid then
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
		state.split:hide()
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
	return state.visible
		and state.split ~= nil
		and state.split.winid ~= nil
		and vim.api.nvim_win_is_valid(state.split.winid)
end

-- Clear logs
function M.clear_logs()
	local logger = require("opencode.logger")
	logger.clear()
	state.entries = {}
	state.entries_log_count = 0
	state.components = {}
	state.selected_idx = 0
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
		" j / k      - Navigate entries",
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
