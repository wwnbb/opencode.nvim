-- opencode.nvim - Command Palette UI
-- Fuzzy-searchable command picker with categories and frecency

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event
local hl_ns = vim.api.nvim_create_namespace("opencode_palette")

-- Configuration
local config = {
	width = 70,
	height = 20,
	border = "rounded",
	frecency = true,
	show_keybinds = true,
	show_icons = true,
	frecency_file = vim.fn.stdpath("data") .. "/opencode_palette_frecency.json",
	max_frecency_entries = 100,
}

-- Command registry
local commands = {}

-- Frecency data: { [command_id] = { count = number, last_used = timestamp } }
local frecency_data = {}

-- Categories with icons and order
local categories = {
	{ id = "session", name = "Session", icon = "󰍡" },
	{ id = "model", name = "Model", icon = "󰢚" },
	{ id = "agent", name = "Agent", icon = "󰧱" },
	{ id = "actions", name = "Actions", icon = "󰜨" },
	{ id = "prompt", name = "Prompt", icon = "󰯂" },
	{ id = "mcp", name = "MCP", icon = "󰡨" },
	{ id = "files", name = "Files", icon = "󰈙" },
	{ id = "navigation", name = "Navigation", icon = "󰆋" },
	{ id = "system", name = "System", icon = "󰣖" },
}

-- Category lookup
local category_order = {}
for i, cat in ipairs(categories) do
	category_order[cat.id] = i
end

-- Load user configuration
local function load_config()
	local cfg = require("opencode.config")
	if cfg.defaults and cfg.defaults.palette then
		config = vim.tbl_deep_extend("force", config, cfg.defaults.palette)
	end
end

-- Load frecency data from file
local function load_frecency()
	if not config.frecency then
		return
	end

	local file = io.open(config.frecency_file, "r")
	if file then
		local content = file:read("*all")
		file:close()
		local ok, data = pcall(vim.json.decode, content)
		if ok and type(data) == "table" then
			frecency_data = data
		end
	end
end

-- Save frecency data to file
local function save_frecency()
	if not config.frecency then
		return
	end

	local dir = vim.fn.fnamemodify(config.frecency_file, ":h")
	vim.fn.mkdir(dir, "p")

	-- Trim old entries
	local entries = {}
	for id, data in pairs(frecency_data) do
		table.insert(entries, { id = id, count = data.count, last_used = data.last_used })
	end

	-- Sort by last used, keep only recent ones
	table.sort(entries, function(a, b)
		return a.last_used > b.last_used
	end)

	local trimmed = {}
	for i, entry in ipairs(entries) do
		if i > config.max_frecency_entries then
			break
		end
		trimmed[entry.id] = { count = entry.count, last_used = entry.last_used }
	end

	frecency_data = trimmed

	local file = io.open(config.frecency_file, "w")
	if file then
		file:write(vim.json.encode(frecency_data))
		file:close()
	end
end

-- Track command usage
local function track_command_usage(cmd_id)
	if not config.frecency or not cmd_id then
		return
	end

	local now = os.time()
	if not frecency_data[cmd_id] then
		frecency_data[cmd_id] = { count = 0, last_used = now }
	end

	frecency_data[cmd_id].count = frecency_data[cmd_id].count + 1
	frecency_data[cmd_id].last_used = now

	-- Save asynchronously
	vim.defer_fn(save_frecency, 100)
end

-- Get frecency score for a command
local function get_frecency_score(cmd_id)
	if not config.frecency or not frecency_data[cmd_id] then
		return 0
	end

	local data = frecency_data[cmd_id]
	local now = os.time()
	local age_days = (now - data.last_used) / 86400

	-- Score decays with age: count * (0.9 ^ age_days)
	local score = data.count * math.pow(0.9, age_days)
	return score
end

-- Register a command
---@param cmd table { id, title, description?, category, keybind?, action, enabled?, suggested? }
function M.register(cmd)
	if not cmd.id or not cmd.title or not cmd.category or not cmd.action then
		error("Command must have id, title, category, and action")
	end
	commands[cmd.id] = {
		id = cmd.id,
		title = cmd.title,
		description = cmd.description or "",
		category = cmd.category,
		keybind = cmd.keybind,
		action = cmd.action,
		enabled = cmd.enabled,
		suggested = cmd.suggested or false,
	}
end

-- Unregister a command
---@param id string Command ID
function M.unregister(id)
	commands[id] = nil
end

-- Get all registered commands
---@return table
function M.get_commands()
	return vim.deepcopy(commands)
end

-- Check if command is enabled
local function is_enabled(cmd)
	if cmd.enabled == nil then
		return true
	end
	if type(cmd.enabled) == "function" then
		local ok, result = pcall(cmd.enabled)
		return ok and result
	end
	return cmd.enabled
end

-- Simple fuzzy match function
local function fuzzy_match(pattern, text)
	if not pattern or pattern == "" then
		return true, 0
	end

	pattern = pattern:lower()
	text = text:lower()

	-- Exact substring match gets highest score
	if text:find(pattern, 1, true) then
		return true, 100 - text:find(pattern, 1, true)
	end

	-- Fuzzy match: all characters in pattern must appear in order
	local pi = 1
	local score = 0
	local last_match = 0

	for ti = 1, #text do
		if pi > #pattern then
			break
		end

		if text:sub(ti, ti) == pattern:sub(pi, pi) then
			-- Bonus for consecutive matches
			if ti == last_match + 1 then
				score = score + 2
			else
				score = score + 1
			end
			last_match = ti
			pi = pi + 1
		end
	end

	if pi > #pattern then
		return true, score
	end

	return false, 0
end

-- Filter and sort commands by search query
local function filter_commands(query)
	local results = {}

	for _, cmd in pairs(commands) do
		if is_enabled(cmd) then
			-- Match against title, description, and category
			local match_title, score_title = fuzzy_match(query, cmd.title)
			local match_desc, score_desc = fuzzy_match(query, cmd.description)
			local match_cat, score_cat = fuzzy_match(query, cmd.category)

			if match_title or match_desc or match_cat then
				local score = math.max(
					match_title and score_title * 3 or 0,
					match_desc and score_desc * 2 or 0,
					match_cat and score_cat or 0
				)

				-- Boost suggested commands
				if cmd.suggested then
					score = score + 50
				end

				-- Add frecency score
				local frecency = get_frecency_score(cmd.id)
				score = score + (frecency * 10)

				table.insert(results, {
					cmd = cmd,
					score = score,
				})
			end
		end
	end

	-- Sort by score (descending), then by category order, then by title
	table.sort(results, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		local cat_a = category_order[a.cmd.category] or 999
		local cat_b = category_order[b.cmd.category] or 999
		if cat_a ~= cat_b then
			return cat_a < cat_b
		end
		return a.cmd.title < b.cmd.title
	end)

	return results
end

-- Get category display info
local function get_category_info(category_id)
	for _, cat in ipairs(categories) do
		if cat.id == category_id then
			return cat
		end
	end
	return { id = category_id, name = category_id, icon = "" }
end

-- Format keybind for display
local function format_keybind(keybind)
	if not keybind or not config.show_keybinds then
		return ""
	end
	-- Replace common key names for better display
	local display = keybind
	display = display:gsub("<leader>", "SPC ")
	display = display:gsub("<C%-", "C-")
	display = display:gsub("<M%-", "M-")
	display = display:gsub("<S%-", "S-")
	display = display:gsub("<CR>", "↵")
	display = display:gsub("<Esc>", "Esc")
	display = display:gsub(">", "")
	return display
end

-- Highlight groups
local highlights = {
	PaletteNormal = { link = "Normal" },
	PaletteTitle = { link = "Title" },
	PaletteCategory = { link = "Type" },
	PaletteKeybind = { link = "Comment" },
	PaletteMatch = { link = "Search" },
	PaletteSelected = { link = "CursorLine" },
	PalettePrompt = { link = "Question" },
	PaletteIcon = { link = "Special" },
}

-- Setup highlights
local function setup_highlights()
	for name, opts in pairs(highlights) do
		vim.api.nvim_set_hl(0, "OpenCode" .. name, opts)
	end
end

-- State
local state = {
	popup = nil,
	input_popup = nil,
	query = "",
	selected = 1,
	results = {},
	prev_win = nil,
}

local PALETTE_ZINDEX = 80

-- Resolve chat window context for palette placement.
-- Mirrors input widget behavior:
-- - float chat => editor-relative absolute coordinates
-- - split chat => window-relative coordinates
local function resolve_palette_target()
	local target_win = nil
	local float_dims = nil

	local chat_ok, chat = pcall(require, "opencode.ui.chat")
	if chat_ok then
		if type(chat.get_winid) == "function" then
			local chat_winid = chat.get_winid()
			if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
				target_win = chat_winid
			end
		end
		if type(chat.get_float_dims) == "function" then
			float_dims = chat.get_float_dims()
		end
	end

	if not target_win then
		local current = vim.api.nvim_get_current_win()
		if current and vim.api.nvim_win_is_valid(current) then
			target_win = current
		end
	end

	return target_win, float_dims
end

local function focus_chat_if_visible()
	local chat_ok, chat = pcall(require, "opencode.ui.chat")
	if not chat_ok then
		return false
	end

	local is_visible = true
	if type(chat.is_visible) == "function" then
		is_visible = chat.is_visible()
	elseif type(chat.get_winid) == "function" then
		local winid = chat.get_winid()
		is_visible = winid and vim.api.nvim_win_is_valid(winid) or false
	end
	if not is_visible then
		return false
	end
	if type(chat.focus) ~= "function" then
		return false
	end

	return pcall(chat.focus)
end

-- Render the command list
local function render_list()
	if not state.popup or not vim.api.nvim_buf_is_valid(state.popup.bufnr) then
		return
	end

	local buf = state.popup.bufnr
	vim.bo[buf].modifiable = true

	local lines = {}
	local highlights_to_apply = {}
	local max_width = state.popup.win_config.width - 2

	local current_category = nil

	for i, result in ipairs(state.results) do
		local cmd = result.cmd
		local cat_info = get_category_info(cmd.category)

		-- Add category header if changed
		if cmd.category ~= current_category then
			current_category = cmd.category
			if #lines > 0 then
				table.insert(lines, "")
			end
			local icon = config.show_icons and cat_info.icon or ""
			local header = string.format(" %s %s", icon, cat_info.name)
			table.insert(lines, header)
			table.insert(highlights_to_apply, { #lines, "OpenCodePaletteCategory", 0, -1 })
		end

		-- Format command line
		local keybind_str = format_keybind(cmd.keybind)
		local keybind_len = #keybind_str
		local available = max_width - keybind_len - 6 -- padding

		local title = cmd.title
		if #title > available then
			title = title:sub(1, available - 3) .. "..."
		end

		local padding = max_width - #title - keybind_len - 4
		local line = string.format("  %s%s%s", title, string.rep(" ", math.max(1, padding)), keybind_str)

		table.insert(lines, line)

		-- Track line index for this command
		result.line = #lines

		-- Apply highlights
		if i == state.selected then
			table.insert(highlights_to_apply, { #lines, "OpenCodePaletteSelected", 0, -1 })
		end
		if keybind_len > 0 then
			table.insert(highlights_to_apply, { #lines, "OpenCodePaletteKeybind", #line - keybind_len, -1 })
		end
	end

	if #lines == 0 then
		table.insert(lines, "")
		table.insert(lines, "  No matching commands")
		table.insert(highlights_to_apply, { 2, "Comment", 0, -1 })
	end

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Apply highlights
	for _, hl in ipairs(highlights_to_apply) do
		local line_idx, hl_group, col_start, col_end = hl[1], hl[2], hl[3], hl[4]
		if col_end == -1 then
			local l = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1]
			col_end = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(buf, hl_ns, line_idx - 1, col_start, { end_col = col_end, hl_group = hl_group })
	end

	vim.bo[buf].modifiable = false

	-- Scroll to selected
	if state.popup.winid and vim.api.nvim_win_is_valid(state.popup.winid) then
		local selected_result = state.results[state.selected]
		if selected_result and selected_result.line then
			vim.api.nvim_win_set_cursor(state.popup.winid, { selected_result.line, 0 })
		end
	end
end

-- Update search results
local function update_results()
	state.results = filter_commands(state.query)
	state.selected = math.min(state.selected, math.max(1, #state.results))
	render_list()
end

-- Execute selected command
local function execute_selected()
	local result = state.results[state.selected]
	if result and result.cmd and result.cmd.action then
		-- Track usage before hiding
		track_command_usage(result.cmd.id)

		M.hide()
		vim.schedule(function()
			local ok, err = pcall(result.cmd.action)
			if not ok then
				vim.notify("Command error: " .. tostring(err), vim.log.levels.ERROR)
			end
		end)
	end
end

-- Move selection
local function move_selection(delta)
	if #state.results == 0 then
		return
	end

	state.selected = state.selected + delta

	-- Wrap around
	if state.selected < 1 then
		state.selected = #state.results
	elseif state.selected > #state.results then
		state.selected = 1
	end

	render_list()
end

-- Close the palette
function M.hide()
	local prev_win = state.prev_win
	if state.input_popup then
		pcall(function()
			state.input_popup:unmount()
		end)
		state.input_popup = nil
	end
	if state.popup then
		pcall(function()
			state.popup:unmount()
		end)
		state.popup = nil
	end
	state.query = ""
	state.selected = 1
	state.results = {}
	state.prev_win = nil

	-- Prefer returning focus to chat while it is visible.
	if focus_chat_if_visible() then
		return
	end

	-- Fallback to the previously active window (e.g. when chat is not visible).
	if prev_win and vim.api.nvim_win_is_valid(prev_win) then
		vim.api.nvim_set_current_win(prev_win)
	end
end

-- Show the command palette
function M.show()
	-- Close if already open
	if state.popup then
		M.hide()
		return
	end

	load_config()
	setup_highlights()

	-- Save current window to restore focus on close
	state.prev_win = vim.api.nvim_get_current_win()

	-- Calculate dimensions
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }
	local target_win, float_dims = resolve_palette_target()

	local width, height, row, col
	local relative
	local input_zindex = PALETTE_ZINDEX + 1
	local popup_zindex = PALETTE_ZINDEX

	local has_float_dims = type(float_dims) == "table"
		and type(float_dims.row) == "number"
		and type(float_dims.col) == "number"
		and type(float_dims.width) == "number"
		and type(float_dims.height) == "number"
		and float_dims.width >= 20
		and float_dims.height >= 8

	if has_float_dims then
		-- Float mode (same strategy as input.show): editor-relative absolute placement.
		local anchor_row = float_dims.row + 1
		local anchor_col = float_dims.col + 1
		local anchor_width = math.max(20, float_dims.width - 2)
		local anchor_height = math.max(8, float_dims.height - 2)

		local max_width = math.max(20, math.min(anchor_width - 4, ui.width - 10))
		local max_height = math.max(6, math.min(anchor_height - 6, ui.height - 8))
		width = math.min(config.width, max_width)
		height = math.min(config.height, max_height)
		row = anchor_row + math.floor((anchor_height - height - 3) / 2)
		col = anchor_col + math.floor((anchor_width - width) / 2)

		-- Clamp absolute editor-relative position to current screen bounds.
		row = math.max(0, math.min(row, math.max(0, ui.height - (height + 3))))
		col = math.max(0, math.min(col, math.max(0, ui.width - width)))

		relative = "editor"
		input_zindex = PALETTE_ZINDEX + 1
		popup_zindex = PALETTE_ZINDEX
	else
		-- Split mode: window-relative placement inside chat window.
		local win_width = ui.width
		local win_height = ui.height
		if target_win and vim.api.nvim_win_is_valid(target_win) then
			win_width = vim.api.nvim_win_get_width(target_win)
			win_height = vim.api.nvim_win_get_height(target_win)
			relative = { type = "win", winid = target_win }
		else
			relative = "editor"
		end

		local max_width = math.max(20, win_width - 4)
		local max_height = math.max(6, win_height - 6)
		width = math.min(config.width, max_width)
		height = math.min(config.height, max_height)
		row = math.max(0, math.floor((win_height - height - 3) / 2))
		col = math.max(0, math.floor((win_width - width) / 2))
	end

	-- Create input popup at top
	state.input_popup = Popup({
		enter = true,
		focusable = true,
		relative = relative,
		zindex = input_zindex,
		border = {
			style = config.border,
			text = {
				top = " 󰘳 Command Palette ",
				top_align = "center",
			},
		},
		position = { row = row, col = col },
		size = { width = width, height = 1 },
	})

	-- Create results popup below
	state.popup = Popup({
		enter = false,
		focusable = false,
		relative = relative,
		zindex = popup_zindex,
		border = {
			style = config.border,
		},
		position = { row = row + 3, col = col },
		size = { width = width, height = height },
	})

	state.input_popup:mount()
	state.popup:mount()

	local input_buf = state.input_popup.bufnr
	local input_win = state.input_popup.winid
	local popup_buf = state.popup.bufnr

	-- Set input buffer options
	vim.bo[input_buf].buftype = "prompt"
	vim.bo[input_buf].filetype = "opencode_palette"
	vim.bo[popup_buf].filetype = "opencode_palette"
	vim.fn.prompt_setprompt(input_buf, " > ")

	-- Start insert mode
	vim.cmd("startinsert!")

	-- Initial results
	update_results()

	-- Setup input handling
	vim.api.nvim_create_autocmd("TextChangedI", {
		buffer = input_buf,
		callback = function()
			local lines = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)
			local line = lines[1] or ""
			-- Remove prompt prefix
			state.query = line:gsub("^ > ", ""):gsub("^> ", "")
			state.selected = 1
			update_results()
		end,
	})

	-- Keymaps for input
	local opts = { buffer = input_buf, noremap = true, silent = true }

	-- Navigation
	vim.keymap.set({ "i", "n" }, "<C-j>", function()
		move_selection(1)
	end, opts)

	vim.keymap.set({ "i", "n" }, "<C-k>", function()
		move_selection(-1)
	end, opts)

	vim.keymap.set({ "i", "n" }, "<Down>", function()
		move_selection(1)
	end, opts)

	vim.keymap.set({ "i", "n" }, "<Up>", function()
		move_selection(-1)
	end, opts)

	vim.keymap.set({ "i", "n" }, "<C-n>", function()
		move_selection(1)
	end, opts)

	vim.keymap.set({ "i", "n" }, "<C-p>", function()
		move_selection(-1)
	end, opts)

	-- Execute
	vim.keymap.set({ "i", "n" }, "<CR>", function()
		execute_selected()
	end, opts)

	-- Close
	vim.keymap.set({ "i", "n" }, "<Esc>", function()
		M.hide()
	end, opts)

	vim.keymap.set({ "i", "n" }, "<C-c>", function()
		M.hide()
	end, opts)

	-- Handle window close
	state.input_popup:on(event.BufLeave, function()
		vim.schedule(function()
			M.hide()
		end)
	end)
end

-- Toggle the command palette
function M.toggle()
	if state.popup then
		M.hide()
	else
		M.show()
	end
end

function M.is_visible()
	return state.popup ~= nil and state.input_popup ~= nil
end

---@return number[]
function M.get_winids()
	local wins = {}

	if state.input_popup and state.input_popup.winid and vim.api.nvim_win_is_valid(state.input_popup.winid) then
		table.insert(wins, state.input_popup.winid)
	end

	if state.popup and state.popup.winid and vim.api.nvim_win_is_valid(state.popup.winid) then
		table.insert(wins, state.popup.winid)
	end

	return wins
end

-- Trigger a command by ID
function M.trigger(id)
	local cmd = commands[id]
	if cmd and is_enabled(cmd) and cmd.action then
		track_command_usage(id)
		local ok, err = pcall(cmd.action)
		if not ok then
			vim.notify("Command error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

-- Register default commands
local default_command_modules = {
	function()
		return require("opencode.ui.palette.session")
	end,
	function()
		return require("opencode.ui.palette.model")
	end,
	function()
		return require("opencode.ui.palette.agent")
	end,
	function()
		return require("opencode.ui.palette.actions")
	end,
	function()
		return require("opencode.ui.palette.prompt")
	end,
	function()
		return require("opencode.ui.palette.mcp")
	end,
	function()
		return require("opencode.ui.palette.system")
	end,
}

local function register_defaults()
	for _, load_module in ipairs(default_command_modules) do
		load_module().register(M)
	end
end

-- Setup function
function M.setup()
	load_config()
	load_frecency()
	setup_highlights()
	register_defaults()
end

return M
