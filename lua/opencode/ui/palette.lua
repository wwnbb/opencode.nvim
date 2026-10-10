-- opencode.nvim - Command Palette UI
-- Fuzzy-searchable command picker with categories and frecency

local M = {}

local Popup = require("opencode.ui.popup")
local app_state = require("opencode.state")
local command_registry = require("opencode.command_registry")
local float_context = require("opencode.ui.float_context")
local hl_ns = vim.api.nvim_create_namespace("opencode_palette")

-- Configuration
local config = vim.deepcopy(require("opencode.config").defaults.palette)

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

-- Load user configuration
local function load_config()
	local cfg = require("opencode.config")
	local full_config = app_state.get_config() or {}
	local defaults = cfg.defaults and cfg.defaults.palette or {}
	local user_palette = type(full_config.palette) == "table" and full_config.palette or {}

	-- Merge into a new table so neither defaults nor state config can be mutated.
	config = vim.tbl_deep_extend("force", {}, defaults, user_palette)

	-- Configured categories define the preferred order. Keep other registered
	-- categories visible after them instead of silently filtering commands.
	category_order = {}
	local seen = {}
	local next_order = 1
	if type(config.categories) == "table" then
		for _, category_id in ipairs(config.categories) do
			if type(category_id) == "string" and not seen[category_id] then
				category_order[category_id] = next_order
				seen[category_id] = true
				next_order = next_order + 1
			end
		end
	end
	for _, cat in ipairs(categories) do
		if not seen[cat.id] then
			category_order[cat.id] = next_order
			seen[cat.id] = true
			next_order = next_order + 1
		end
	end
end

-- Load frecency data from file
local function nonnegative_number(value)
	return type(value) == "number" and value >= 0 and value < math.huge
end

local function load_frecency()
	frecency_data = {}
	if not config.frecency then
		return
	end

	local data = require("opencode.util.json_file").read(config.frecency_file)
	if type(data) == "table" then
		for id, value in pairs(data) do
			if type(id) == "string" and type(value) == "table"
				and nonnegative_number(value.count) and value.count % 1 == 0
				and nonnegative_number(value.last_used) then
				frecency_data[id] = { count = value.count, last_used = value.last_used }
			end
		end
	end
end

-- Save frecency data to file
local function save_frecency()
	if not config.frecency then
		return
	end

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

	require("opencode.util.json_file").write(config.frecency_file, frecency_data)
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

	save_frecency()
end

-- Get frecency score for a command
local function get_frecency_score(cmd_id)
	if not config.frecency or not frecency_data[cmd_id] then
		return 0
	end

	local data = frecency_data[cmd_id]
	local now = os.time()
	local age_days = math.max(0, (now - data.last_used) / 86400)

	-- Score decays with age: count * (0.9 ^ age_days)
	local score = data.count * math.pow(0.9, age_days)
	return score
end

-- Compatibility adapter for palette.register({ action = function() ... end }).
-- Built-ins and new callers use the same canonical registry record.
---@param cmd table { id, title, description?, category, keybind?, action?, run?, enabled?, suggested?, slash?, on_select? }
function M.register(cmd)
	if not cmd.id or not cmd.title or not cmd.category or not (cmd.run or cmd.action) then
		error("Command must have id, title, category, and run or action")
	end
	local record = vim.tbl_extend("force", {}, cmd)
	record.run = cmd.run or cmd.action
	record.action = nil
	return command_registry.register(record)
end

-- Simple fuzzy match function
local function fuzzy_match(pattern, text)
	if not pattern or pattern == "" then
		return true, 0
	end

	pattern = vim.fn.tolower(pattern)
	text = vim.fn.tolower(text)

	-- Exact substring match gets highest score.
	local exact = text:find(pattern, 1, true)
	if exact then return true, 100 - exact end

	-- Compare Unicode codepoints; unrelated UTF-8 bytes are not a match.
	local characters = vim.fn.str2list(pattern)
	local pi, score, last_match = 1, 0, 0
	for ti, character in ipairs(vim.fn.str2list(text)) do
		if character == characters[pi] then
			score = score + (ti == last_match + 1 and 2 or 1)
			last_match = ti
			pi = pi + 1
			if pi > #characters then return true, score end
		end
	end

	return false, 0
end

-- Filter and sort commands by search query
local function filter_commands(query)
	local results = {}

	for _, cmd in ipairs(command_registry.all()) do
		if cmd.palette ~= false and command_registry.enabled(cmd, { source = "palette" }) then
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

	local grouped, order = {}, {}
	for _, result in ipairs(results) do
		local category = result.cmd.category
		if not grouped[category] then
			grouped[category] = {}
			table.insert(order, category)
		end
		table.insert(grouped[category], result)
	end
	if not query or query == "" then
		table.sort(order, function(a, b)
			local left, right = category_order[a] or 999, category_order[b] or 999
			return left == right and a < b or left < right
		end)
	end

	local rows = {}
	if not query or query == "" then
		for _, result in ipairs(results) do
			if result.cmd.suggested then
				table.insert(rows, { cmd = result.cmd, category = "suggested" })
			end
		end
	end
	for _, category in ipairs(order) do
		for _, result in ipairs(grouped[category]) do
			table.insert(rows, result)
		end
	end
	return rows
end

-- Get category display info
local function get_category_info(category_id)
	if category_id == "suggested" then
		return { name = "Suggested", icon = "" }
	end
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

-- Truncate text without splitting a multibyte character and fit it by display width.
local truncate_display_width = require("opencode.util.text").truncate

local function truncate_with_ellipsis(text, max_width)
	return truncate_display_width(text, max_width, "...")
end

-- Keep the existing theme colors; only the dialog layout changes.
local function setup_highlights()
	local highlights = {
		Normal = "NormalFloat",
		Title = "Title",
		Category = "Type",
		Keybind = "Comment",
		Match = "Search",
		Selected = "CursorLine",
		Prompt = "Question",
		Icon = "Special",
	}
	for name, link in pairs(highlights) do
		vim.api.nvim_set_hl(0, "OpenCodePalette" .. name, { link = link, default = true })
	end
end

require("opencode.ui.highlights").register("opencode.ui.palette", setup_highlights)

-- State
local state = {
	view = nil,
	frame = nil,
	max_list_height = 20,
	popup = nil,
	input_popup = nil,
	query = "",
	selected = 1,
	results = {},
}

local PALETTE_ZINDEX = 80

-- Navigation changes only the selected mark and the native viewport.
local function render_selection()
	if not state.popup or not vim.api.nvim_buf_is_valid(state.popup.bufnr) then return end
	local result = state.results[state.selected]
	if not result or not result.line then return end
	vim.api.nvim_buf_set_extmark(state.popup.bufnr, hl_ns, result.line - 1, 0, {
		id = 1, end_col = result.end_col, hl_group = "OpenCodePaletteSelected",
	})
	if state.popup.winid and vim.api.nvim_win_is_valid(state.popup.winid) then
		vim.api.nvim_win_set_cursor(state.popup.winid, { result.line, 0 })
		if state.selected == 1 then
			vim.api.nvim_win_call(state.popup.winid, function() vim.fn.winrestview({ topline = 1 }) end)
		end
	end
end

-- Render the command list
local function render_list()
	if not state.popup or not vim.api.nvim_buf_is_valid(state.popup.bufnr) then
		return
	end

	local buf = state.popup.bufnr
	vim.api.nvim_buf_clear_namespace(buf, hl_ns, 0, -1)
	vim.bo[buf].modifiable = true

	local lines = {}
	local highlights_to_apply = {}
	local max_width = state.popup.win_config.width
	local content_width = math.max(0, max_width - 6)

	local current_category = nil

	for _, result in ipairs(state.results) do
		local cmd = result.cmd
		local category = result.category or cmd.category
		local cat_info = get_category_info(category)

		-- Add category header if changed
		if category ~= current_category then
			current_category = category
			if #lines > 0 then
				table.insert(lines, "")
			end
			local icon = config.show_icons and cat_info.icon or ""
			local header = "   " .. (icon ~= "" and (icon .. " ") or "") .. cat_info.name
			header = truncate_display_width(header, max_width)
			table.insert(lines, header)
			table.insert(highlights_to_apply, { #lines, "OpenCodePaletteCategory", 0, -1 })
		end

		-- Format command line
		local keybind_str = format_keybind(cmd.keybind)
		-- Leave room for a readable title even with a long custom mapping.
		keybind_str = truncate_display_width(keybind_str, math.max(0, content_width - 8))
		local keybind_width = vim.fn.strdisplaywidth(keybind_str)
		local available = math.max(0, content_width - keybind_width - (keybind_width > 0 and 2 or 0))
		local title = truncate_with_ellipsis(cmd.title, available)
		local title_width = vim.fn.strdisplaywidth(title)
		local padding = math.max(0, content_width - title_width - keybind_width)
		local line = "   " .. title .. string.rep(" ", padding) .. keybind_str .. "   "

		table.insert(lines, line)

		-- Track line index for this command
		result.line, result.end_col = #lines, #line

		-- Apply highlights
		if keybind_width > 0 then
			-- Extmark columns are byte offsets even though layout uses display width.
			table.insert(highlights_to_apply, { #lines, "OpenCodePaletteKeybind", #line - #keybind_str - 3, #line - 3 })
		end
	end

	if #lines == 0 then
		table.insert(lines, "")
		table.insert(lines, truncate_display_width("   No results found", max_width))
		table.insert(highlights_to_apply, { 2, "OpenCodePaletteKeybind", 0, -1 })
	end

	-- Like DialogSelect, shrink the surface when filtering leaves fewer rows.
	local list_height = math.min(state.max_list_height, #lines)
	if state.popup.win_config.height ~= list_height or state.frame.win_config.height ~= list_height + 7 then
		state.view:resize({
			content = { size = { width = max_width, height = list_height } },
			frame = { size = { width = state.frame.win_config.width, height = list_height + 7 } },
		})
	end
	local frame_width = state.frame.win_config.width
	local title = truncate_display_width("Commands", math.max(0, frame_width - 12))
	local header = truncate_display_width("    " .. title
		.. string.rep(" ", math.max(0, frame_width - #title - 11)) .. "esc    ", frame_width)
	state.view:render({ "", header }, {
		{ line = 1, col = 4, end_col = 4 + #title, hl_group = "OpenCodePaletteTitle" },
		{ line = 1, col = #header - 7, end_col = #header - 4, hl_group = "OpenCodePaletteKeybind" },
	}, "frame")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Apply highlights
	for index, hl in ipairs(highlights_to_apply) do
		local line_idx, hl_group, col_start, col_end = hl[1], hl[2], hl[3], hl[4]
		if col_end == -1 then
			local l = vim.api.nvim_buf_get_lines(buf, line_idx - 1, line_idx, false)[1]
			col_end = l and #l or 0
		end
		vim.api.nvim_buf_set_extmark(buf, hl_ns, line_idx - 1, col_start, { id = index + 1, end_col = col_end, hl_group = hl_group })
	end

	vim.bo[buf].modifiable = false

	render_selection()
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
	if result and result.cmd then
		local command = command_registry.get(result.cmd.id)
		if not command or command.palette == false or not command_registry.enabled(command, { source = "palette" }) then
			return
		end
		-- Track usage before hiding
		track_command_usage(command.id)

		M.hide()
		vim.schedule(function()
			command_registry.run(command.id, { source = "palette" })
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

	render_selection()
end

-- Close the palette
function M.hide()
	if state.view then state.view:close() end
end

-- Show the command palette
function M.show()
	-- Close if already open
	if state.popup then
		M.hide()
		return
	end

	load_config()
	load_frecency()
	setup_highlights()

	-- One surface: title at row 1, search at row 3, list at row 5.
	-- The inner windows share the frame background and have no borders.
	local target_win, float_dims = float_context.get_chat_context()
	local screen_width, screen_height = vim.o.columns, vim.o.lines - vim.o.cmdheight
	local anchor_row, anchor_col = 0, 0
	local anchor_width, anchor_height = screen_width, screen_height
	local relative = "editor"
	if
		type(float_dims) == "table"
		and type(float_dims.width) == "number"
		and type(float_dims.height) == "number"
		and type(float_dims.row) == "number"
		and type(float_dims.col) == "number"
	then
		anchor_row, anchor_col = float_dims.row + 1, float_dims.col + 1
		anchor_width, anchor_height = float_dims.width - 2, float_dims.height - 2
	elseif target_win and vim.api.nvim_win_is_valid(target_win) then
		anchor_width = vim.api.nvim_win_get_width(target_win)
		anchor_height = vim.api.nvim_win_get_height(target_win)
		relative = { type = "win", winid = target_win }
	end
	-- Tiny splits cannot hold the header and search; use the editor in that case.
	if anchor_width < 22 or anchor_height < 12 then
		anchor_row, anchor_col = 0, 0
		anchor_width, anchor_height = screen_width, screen_height
		relative = "editor"
	end
	local border = config.border or "none"
	local border_size = border == "none" and 0 or 2
	local width = math.max(10, math.min(config.width, anchor_width - 2, screen_width - 2 - border_size))
	local height = math.max(1, math.min(config.height, anchor_height - 9, screen_height - 9 - border_size))
	state.max_list_height = height
	local frame_height = height + 7
	local row = math.max(0, anchor_row + math.floor((anchor_height - frame_height - border_size) / 2))
	local col = math.max(0, anchor_col + math.floor((anchor_width - width - border_size) / 2))
	if relative == "editor" then
		row = math.min(row, math.max(0, screen_height - frame_height - border_size))
		col = math.min(col, math.max(0, screen_width - width - border_size))
	end
	local window_options = {
		winhighlight = "Normal:OpenCodePaletteNormal,NormalNC:OpenCodePaletteNormal,FloatBorder:OpenCodePaletteNormal,EndOfBuffer:OpenCodePaletteNormal",
		winblend = 0,
		wrap = false,
		cursorline = false,
		scrolloff = 0,
	}
	state.view = Popup.new({
		outer_border_style = border,
		frame = {
			enter = false, focusable = false, relative = relative, zindex = PALETTE_ZINDEX,
			position = { row = row, col = col }, size = { width = width, height = frame_height },
			win_options = window_options, buf_options = { modifiable = false },
		},
		content = {
			enter = false, focusable = false, zindex = PALETTE_ZINDEX + 1,
			position = { row = 5, col = 1 }, size = { width = width - 2, height = height },
			win_options = window_options,
		},
		input = {
			kind = "popup", enter = true, focusable = true, zindex = PALETTE_ZINDEX + 2,
			position = { row = 3, col = 4 }, size = { width = math.max(1, width - 8), height = 1 },
			win_options = window_options,
		},
		focus_restore = "chat",
		close_on_leave = true,
		on_close = function(current)
			if state.view ~= current then return end
			state.view, state.frame, state.popup, state.input_popup = nil, nil, nil, nil
			state.query, state.selected, state.results = "", 1, {}
		end,
		on_resize = function(current)
			current:resize({ frame = { size = { width = width, height = frame_height } } })
			local next_width = current.frame.win_config.width
			state.max_list_height = math.max(1, current.frame.win_config.height - 7)
			current:resize({
				content = { size = { width = math.max(1, next_width - 2) } },
				input = { size = { width = math.max(1, next_width - 8) } },
			})
			render_list()
		end,
	})
	state.frame, state.popup, state.input_popup = state.view.frame, state.view.content, state.view.input
	state.view:mount()

	local input_buf = state.input_popup.bufnr
	local popup_buf = state.popup.bufnr
	vim.bo[input_buf].buftype = "prompt"
	vim.bo[input_buf].filetype = "opencode_palette"
	vim.bo[popup_buf].filetype = "opencode_palette"
	vim.fn.prompt_setprompt(input_buf, "")

	local function update_placeholder()
		vim.api.nvim_buf_clear_namespace(input_buf, hl_ns, 0, -1)
		if state.query == "" then
			vim.api.nvim_buf_set_extmark(input_buf, hl_ns, 0, 0, {
				virt_text = { { "Search", "OpenCodePalettePrompt" } },
				virt_text_pos = "overlay",
			})
		end
	end
	update_placeholder()

	-- Start insert mode
	vim.cmd("startinsert!")

	-- Initial results
	update_results()

	-- Setup input handling
	vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
		buffer = input_buf,
		callback = function()
			local lines = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)
			local line = lines[1] or ""
			state.query = line
			update_placeholder()
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
	return state.view ~= nil and not state.view.closed
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

	if state.frame and state.frame.winid and vim.api.nvim_win_is_valid(state.frame.winid) then
		table.insert(wins, state.frame.winid)
	end
	return wins
end

-- Trigger a command by ID
function M.trigger(id)
	local cmd = command_registry.get(id)
	if cmd and cmd.palette ~= false and command_registry.enabled(cmd, { source = "palette" }) then
		track_command_usage(id)
		command_registry.run(id, { source = "palette" })
	end
end

-- Register default commands
local default_command_modules = {
	"opencode.ui.palette.session",
	"opencode.ui.palette.family",
	"opencode.ui.palette.model",
	"opencode.ui.palette.agent",
	"opencode.ui.palette.actions",
	"opencode.ui.palette.prompt",
	"opencode.ui.palette.mcp",
	"opencode.ui.palette.system",
	"opencode.ui.palette.plugins",
	"opencode.ui.palette.pairing",
	"opencode.ui.terminals",
}

function M.register_defaults()
	for _, module_name in ipairs(default_command_modules) do
		require(module_name).register(M)
	end
end

-- Setup function
function M.setup()
	load_config()
	load_frecency()
	setup_highlights()
	M.register_defaults()
end

return M
