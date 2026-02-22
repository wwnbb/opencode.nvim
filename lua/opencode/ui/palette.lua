-- opencode.nvim - Command Palette UI
-- Fuzzy-searchable command picker with categories and frecency

local M = {}

local Popup = require("nui.popup")
local NuiText = require("nui.text")
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
}

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

	-- Calculate dimensions
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }

	local width = math.min(config.width, ui.width - 10)
	local height = math.min(config.height, ui.height - 8)
	local row = math.floor((ui.height - height - 3) / 2)
	local col = math.floor((ui.width - width) / 2)

	-- Create input popup at top
	state.input_popup = Popup({
		enter = true,
		focusable = true,
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

	-- Set input buffer options
	vim.bo[input_buf].buftype = "prompt"
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

-- Helper: Connect provider with specific auth method
-- This handles API key input or OAuth flow
---@param provider table Provider info
---@param method table Auth method { type, label }
---@param method_index number 0-indexed method index for API
function M._connect_provider_with_method(provider, method, method_index)
	local client = require("opencode.client")
	local state = require("opencode.state")
	local float = require("opencode.ui.float")

	-- Ensure we're focused on the chat window before showing input
	local chat = require("opencode.ui.chat")
	if chat.focus then
		chat.focus()
	end

	if method.type == "api" then
		-- API key authentication - prompt for key
		float.create_input_popup({
			title = " " .. (method.label or "API Key") .. " ",
			prompt = "Enter API key for " .. (provider.name or provider.id) .. ":",
			on_submit = function(api_key)
				if not api_key or api_key == "" then
					vim.notify("API key cannot be empty", vim.log.levels.WARN)
					return
				end

				client.set_provider_auth(provider.id, { type = "api", key = api_key }, function(err)
					vim.schedule(function()
						if err then
							vim.notify("Failed to set API key: " .. tostring(err.message or err), vim.log.levels.ERROR)
							return
						end

						-- Dispose and reconnect to refresh provider list
						client.dispose(function()
							vim.notify("Connected to " .. (provider.name or provider.id), vim.log.levels.INFO)

							-- Now show model selection for this provider
							M._show_provider_models(provider)
						end)
					end)
				end)
			end,
		})
	elseif method.type == "oauth" then
		-- OAuth authentication - initiate OAuth flow
		client.oauth_authorize(provider.id, method_index, function(err, authorization)
			vim.schedule(function()
				if err then
					vim.notify("Failed to start OAuth: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end

				if not authorization then
					vim.notify("No authorization response", vim.log.levels.ERROR)
					return
				end

				if authorization.method == "code" then
					-- Code-based OAuth: open URL and prompt for code
					if authorization.url then
						vim.ui.open(authorization.url)
					end

					float.create_input_popup({
						title = " " .. (method.label or "OAuth") .. " ",
						prompt = authorization.instructions or "Enter authorization code:",
						on_submit = function(code)
							if not code or code == "" then
								vim.notify("Authorization code cannot be empty", vim.log.levels.WARN)
								return
							end

							client.oauth_callback(provider.id, method_index, code, function(cb_err)
								vim.schedule(function()
									if cb_err then
										vim.notify(
											"OAuth failed: " .. tostring(cb_err.message or cb_err),
											vim.log.levels.ERROR
										)
										return
									end

									client.dispose(function()
										vim.notify(
											"Connected to " .. (provider.name or provider.id),
											vim.log.levels.INFO
										)
										M._show_provider_models(provider)
									end)
								end)
							end)
						end,
					})
				elseif authorization.method == "auto" then
					-- Auto OAuth: show dialog with URL and device code, then wait for callback
					-- Extract device code from instructions (format like "XXXX-XXXX" or "XXXX-XXXXX")
					local device_code = nil
					if authorization.instructions then
						device_code = authorization.instructions:match(
							"[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]%-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]?"
						)
					end

					-- Show the authorization dialog
					M._show_oauth_auto_dialog({
						provider = provider,
						method = method,
						method_index = method_index,
						authorization = authorization,
						device_code = device_code,
					})
				end
			end)
		end)
	else
		vim.notify("Unknown auth method: " .. tostring(method.type), vim.log.levels.ERROR)
	end
end

-- Helper: Show model selection for a specific provider after connection
---@param provider table Provider info
function M._show_provider_models(provider)
	local client = require("opencode.client")
	local state = require("opencode.state")
	local float = require("opencode.ui.float")

	-- Ensure we're focused on the chat window
	local chat = require("opencode.ui.chat")
	if chat.focus then
		chat.focus()
	end

	-- Refresh provider list to get updated models
	client.list_providers(function(err, response)
		vim.schedule(function()
			if err then
				vim.notify("Failed to refresh providers", vim.log.levels.WARN)
				return
			end

			-- Find the provider in the refreshed list
			local updated_provider = nil
			for _, p in ipairs(response.all or {}) do
				if p.id == provider.id then
					updated_provider = p
					break
				end
			end

			if not updated_provider or not updated_provider.models then
				vim.notify("Provider has no models available", vim.log.levels.WARN)
				return
			end

			-- Build model items
			local items = {}
			for model_id, model in pairs(updated_provider.models) do
				-- Only show "Free" for opencode provider models with zero cost
				local is_free = provider.id == "opencode" and model.cost and model.cost.input == 0
				table.insert(items, {
					label = model.name or model_id,
					value = model_id,
					model = model,
					description = is_free and "Free" or nil,
				})
			end

			-- Sort alphabetically
			table.sort(items, function(a, b)
				return a.label < b.label
			end)

			float.create_searchable_menu(items, function(item)
				-- Use local.lua module for model selection (like TUI's local.tsx)
				local lc_ok, lc = pcall(require, "opencode.local")
				if lc_ok then
					lc.model.set({
						providerID = provider.id,
						modelID = item.value,
					}, { recent = true })
				end
				-- Also update old state for backward compatibility
				state.set_model(item.value, item.model.name, provider.id)
				-- Update input info bar if visible
				local input_ok, input = pcall(require, "opencode.ui.input")
				if input_ok and input.is_visible and input.is_visible() then
					input.update_info_bar()
				end
			end, { title = " Select model from " .. (provider.name or provider.id) .. " ", width = 50 })
		end)
	end)
end

-- Helper: Show OAuth auto dialog for device code flow (GitHub Copilot, etc.)
-- Shows URL, device code, and waits for user to complete auth in browser
---@param opts table { provider, method, method_index, authorization, device_code }
function M._show_oauth_auto_dialog(opts)
	local client = require("opencode.client")
	local float = require("opencode.ui.float")
	local Popup = require("nui.popup")
	local event = require("nui.utils.autocmd").event

	-- Ensure we're focused on the chat window
	local chat = require("opencode.ui.chat")
	if chat.focus then
		chat.focus()
	end

	local provider = opts.provider
	local method = opts.method
	local method_index = opts.method_index
	local authorization = opts.authorization
	local device_code = opts.device_code

	-- Get the chat window for positioning
	local target_win = vim.api.nvim_get_current_win()

	-- Calculate popup size relative to chat window
	-- Account for border (2 chars total width for border)
	local width = 55
	local height = 10

	local win_width = vim.api.nvim_win_get_width(target_win)
	local win_height = vim.api.nvim_win_get_height(target_win)
	local total_width = width + 2 -- border adds 2 to total width
	local row = math.floor((win_height - height) / 2)
	local col = math.max(0, math.floor((win_width - total_width) / 2))

	-- Create popup relative to chat window
	local popup = Popup({
		relative = { type = "win", winid = target_win },
		enter = true,
		focusable = true,
		border = {
			style = "rounded",
			text = {
				top = " " .. (method.label or "OAuth") .. " ",
				top_align = "center",
			},
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
		win_options = {
			winhighlight = "Normal:Normal,FloatBorder:FloatBorder",
		},
	})

	popup:mount()

	local bufnr = popup.bufnr
	local is_closed = false

	-- Build content lines
	local lines = {
		"",
		"  Open the following URL in your browser:",
		"",
		"  " .. (authorization.url or ""),
		"",
	}

	if device_code then
		table.insert(lines, "  Enter this code: " .. device_code)
		table.insert(lines, "")
	end

	if authorization.instructions and not device_code then
		table.insert(lines, "  " .. authorization.instructions)
		table.insert(lines, "")
	end

	table.insert(lines, "  Waiting for authorization...")
	table.insert(lines, "")
	table.insert(lines, "  Press 'o' to open URL | 'c' to copy code | 'q' to cancel")

	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

	-- Apply highlights
	local function hl_line(line_nr, hl_group)
		local lt = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)[1] or ""
		vim.api.nvim_buf_set_extmark(bufnr, hl_ns, line_nr, 0, { end_col = #lt, hl_group = hl_group })
	end
	hl_line(1, "Comment") -- "Open the following..."
	hl_line(3, "String") -- URL
	if device_code then
		hl_line(5, "WarningMsg") -- Device code line
	end

	vim.bo[bufnr].modifiable = false

	-- Close function
	local function close()
		if is_closed then
			return
		end
		is_closed = true
		pcall(function()
			popup:unmount()
		end)
	end

	-- Setup keymaps
	local keymap_opts = { buffer = bufnr, noremap = true, silent = true }

	-- Open URL
	vim.keymap.set("n", "o", function()
		if authorization.url then
			vim.ui.open(authorization.url)
		end
	end, keymap_opts)

	-- Copy code
	vim.keymap.set("n", "c", function()
		local code_to_copy = device_code or authorization.url or ""
		vim.fn.setreg("+", code_to_copy)
		vim.fn.setreg("*", code_to_copy)
		vim.notify("Copied to clipboard: " .. code_to_copy, vim.log.levels.INFO)
	end, keymap_opts)

	-- Cancel
	vim.keymap.set("n", "q", close, keymap_opts)
	vim.keymap.set("n", "<Esc>", close, keymap_opts)

	-- Auto-open URL in browser
	if authorization.url then
		vim.ui.open(authorization.url)
	end

	-- Start polling for OAuth completion in the background
	client.oauth_callback(provider.id, method_index, nil, function(cb_err)
		vim.schedule(function()
			if is_closed then
				return
			end

			close()

			if cb_err then
				vim.notify("OAuth failed: " .. tostring(cb_err.message or cb_err), vim.log.levels.ERROR)
				return
			end

			client.dispose(function()
				vim.notify("Connected to " .. (provider.name or provider.id), vim.log.levels.INFO)
				M._show_provider_models(provider)
			end)
		end)
	end)

	-- Close on buffer leave
	popup:on(event.BufLeave, function()
		vim.defer_fn(close, 100)
	end)

	return {
		close = close,
		popup = popup,
	}
end

-- Register default commands
local function register_defaults()
	local opencode = require("opencode")
	local state = require("opencode.state")
	local client = require("opencode.client")
	local lifecycle = require("opencode.lifecycle")
	local changes = require("opencode.artifact.changes")

	-- Session commands
	M.register({
		id = "session.new",
		title = "New Session",
		description = "Create a new chat session (same as Clear Chat)",
		category = "session",
		keybind = "<leader>on",
		action = function()
			-- Use the main clear() function which handles everything
			opencode.clear()
		end,
	})

	M.register({
		id = "session.list",
		title = "Switch Session",
		description = "Switch to another session",
		category = "session",
		keybind = "<leader>os",
		action = function()
			lifecycle.ensure_connected(function()
				client.list_sessions(function(err, sessions)
					if err then
						vim.schedule(function()
							vim.notify(
								"Failed to list sessions: " .. tostring(err.message or err),
								vim.log.levels.ERROR
							)
						end)
						return
					end
					vim.schedule(function()
						if not sessions or #sessions == 0 then
							vim.notify("No sessions found", vim.log.levels.INFO)
							return
						end

						local float = require("opencode.ui.float")
						local sync = require("opencode.sync")
						local current = state.get_session()

						-- Sort sessions by update time (most recent first, like TUI)
						table.sort(sessions, function(a, b)
							local a_time = a.time and a.time.updated or 0
							local b_time = b.time and b.time.updated or 0
							return a_time > b_time
						end)

						-- Format relative time helper
						local function format_relative_time(timestamp)
							if not timestamp then
								return ""
							end
							local now = os.time()
							local diff = now - timestamp
							if diff < 60 then
								return "just now"
							elseif diff < 3600 then
								return math.floor(diff / 60) .. "m ago"
							elseif diff < 7200 then
								return "1h ago"
							elseif diff < 86400 then
								return math.floor(diff / 3600) .. "h ago"
							elseif diff < 172800 then
								return "Yesterday"
							else
								return os.date("%b %d", timestamp)
							end
						end

						-- Build items for searchable menu (same as model switch)
						local items = {}
						for _, session in ipairs(sessions) do
							local is_current = current.id == session.id
							local title = session.title or "Untitled"
							local msg_count = session.messageCount or 0
							local time_str = format_relative_time(session.time and session.time.updated)
							local msg_str = msg_count > 0 and ("(" .. msg_count .. " msgs)") or ""
							local current_marker = is_current and "● " or "  "

							table.insert(items, {
								label = current_marker .. title .. " " .. msg_str,
								value = session.id,
								session = session,
								description = time_str,
								priority = is_current and 1 or 0,
							})
						end

						-- Use searchable menu like model switch (with filter input)
						float.create_searchable_menu(items, function(item)
							local session = item.session

							-- Don't switch if already on this session
							if current.id == session.id then
								vim.notify("Already on session: " .. (session.title or session.id), vim.log.levels.INFO)
								return
							end

							-- Show loading indicator
							vim.notify(
								"Loading session: " .. (session.title or session.id) .. "...",
								vim.log.levels.INFO
							)

							-- Load session messages before switching (like TUI)
							client.get_messages(session.id, {}, function(msg_err, messages)
								vim.schedule(function()
									if msg_err then
										vim.notify(
											"Failed to load session messages: " .. tostring(msg_err.message or msg_err),
											vim.log.levels.WARN
										)
									end

									-- Clear current session data from sync store
									if current.id then
										sync.clear_session(current.id)
									end

									-- Update sync store with loaded messages
									if messages then
										for _, msg in ipairs(messages) do
											sync.handle_message_updated(msg)
										end
									end

									-- Set new session
									state.set_session(session.id, session.title)

									-- Emit session switch event (like TUI's SessionSelect)
									local events = require("opencode.events")
									events.emit("session.selected", {
										sessionID = session.id,
										sessionTitle = session.title,
										previousSessionID = current.id,
									})

									-- Clear chat UI and render from sync store
									local chat = require("opencode.ui.chat")
									chat.clear()
									chat.render()

									vim.notify(
										"Switched to session: " .. (session.title or session.id),
										vim.log.levels.INFO
									)
								end)
							end)
						end, { title = " Switch Session ", width = 70 })
					end)
				end)
			end)
		end,
	})

	M.register({
		id = "session.fork",
		title = "Fork Session",
		description = "Fork current session",
		category = "session",
		keybind = "<leader>of",
		action = function()
			local current = state.get_session()
			if not current.id then
				vim.notify("No active session to fork", vim.log.levels.WARN)
				return
			end

			lifecycle.ensure_connected(function()
				client.fork_session(current.id, {}, function(err, session)
					if err then
						vim.schedule(function()
							vim.notify("Failed to fork session: " .. tostring(err.message or err), vim.log.levels.ERROR)
						end)
						return
					end
					vim.schedule(function()
						state.set_session(session.id, session.title or "Forked Session")
						vim.notify("Forked session: " .. (session.title or session.id), vim.log.levels.INFO)
					end)
				end)
			end)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})

	M.register({
		id = "session.delete",
		title = "Delete Session",
		description = "Delete current session",
		category = "session",
		action = function()
			local session = state.get_session()
			if not session.id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end

			vim.ui.select({ "Yes", "No" }, {
				prompt = "Delete session '" .. (session.name or session.id) .. "'?",
			}, function(choice)
				if choice == "Yes" then
					lifecycle.ensure_connected(function()
						client.delete_session(session.id, function(err)
							if err then
								vim.schedule(function()
									vim.notify(
										"Failed to delete session: " .. tostring(err.message or err),
										vim.log.levels.ERROR
									)
								end)
								return
							end
							vim.schedule(function()
								state.set_session(nil, nil)
								vim.notify("Session deleted", vim.log.levels.INFO)
								local chat = require("opencode.ui.chat")
								chat.clear()
							end)
						end)
					end)
				end
			end)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})

	M.register({
		id = "session.archive",
		title = "Archive Session",
		description = "Archive current session",
		category = "session",
		action = function()
			-- Note: This is a placeholder - actual archive functionality
			-- depends on server API support
			vim.notify("Archive session - not yet implemented in server API", vim.log.levels.WARN)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})

	-- Model commands
	M.register({
		id = "model.switch",
		title = "Switch Model",
		description = "Change the AI model",
		category = "model",
		keybind = "<leader>om",
		action = function()
			lifecycle.ensure_connected(function()
				-- Use /config/providers (like TUI) to get providers with models
				client.get_config_providers(function(err, response)
					if err then
						vim.schedule(function()
							vim.notify(
								"Failed to list providers: " .. tostring(err.message or err),
								vim.log.levels.ERROR
							)
						end)
						return
					end
					vim.schedule(function()
						-- Response is { providers: Provider[], default: { providerID: modelID } }
						local provider_list = response and response.providers or {}
						if #provider_list == 0 then
							vim.notify("No providers available. Connect a provider first.", vim.log.levels.WARN)
							return
						end

						-- Update sync store so is_model_valid works correctly
						local sync = require("opencode.sync")
						sync.handle_providers(provider_list)
						if response.default then
							sync.handle_provider_defaults(response.default)
						end

						-- All providers from /config/providers are connected
						local connected_set = {}
						for _, p in ipairs(provider_list) do
							connected_set[p.id] = true
						end

						-- Flatten models from all providers
						-- provider.models is a map {model_id: model}, not an array
						-- Connected providers' models get higher priority
						local items = {}

						-- Get favorites to mark them with stars
						local lc_ok, lc = pcall(require, "opencode.local")
						local favorites_set = {}
						if lc_ok then
							local favorites = lc.model.favorite()
							for _, fav in ipairs(favorites) do
								favorites_set[fav.providerID .. "/" .. fav.modelID] = true
							end
						end

						for _, provider in ipairs(provider_list) do
							if provider.models then
								local is_connected = connected_set[provider.id] or false
								for model_id, model in pairs(provider.models) do
									local is_favorite = favorites_set[provider.id .. "/" .. model_id]
									table.insert(items, {
										label = string.format(
											"%s[%s] %s",
											is_favorite and "★ " or "",
											provider.id,
											model.name or model_id
										),
										value = model_id,
										provider = provider.id,
										model = model,
										description = is_connected and "Connected" or nil,
										priority = (is_favorite and 2 or 0) + (is_connected and 1 or 0),
										is_favorite = is_favorite,
									})
								end
							end
						end

						if #items == 0 then
							vim.notify("No models available", vim.log.levels.WARN)
							return
						end

						local float = require("opencode.ui.float")
						float.create_searchable_menu(items, function(item)
							-- Use local.lua module for model selection (like TUI's local.tsx)
							local lc_ok, lc = pcall(require, "opencode.local")
							if lc_ok then
								lc.model.set({
									providerID = item.provider,
									modelID = item.value,
								}, { recent = true })
							end
							-- Also update old state for backward compatibility
							state.set_model(item.value, item.model.name, item.provider)
							-- Update input info bar if visible
							local input_ok, input = pcall(require, "opencode.ui.input")
							if input_ok and input.is_visible and input.is_visible() then
								input.update_info_bar()
							end
						end, {
							title = " Switch Model ",
							width = 60,
							on_key = function(key, item)
								if key == "f" and lc_ok then
									lc.model.toggle_favorite({
										providerID = item.provider,
										modelID = item.value,
									})
									-- Update item state
									item.is_favorite = not item.is_favorite
									item.label = string.format(
										"%s[%s] %s",
										item.is_favorite and "★ " or "",
										item.provider,
										item.model.name or item.value
									)
									item.priority = (item.is_favorite and 2 or 0)
										+ (item.description == "Connected" and 1 or 0)
									vim.notify(
										item.is_favorite and "Added to favorites" or "Removed from favorites",
										vim.log.levels.INFO
									)
									return true -- Keep menu open
								end
								return false
							end,
						})
					end)
				end)
			end)
		end,
	})

	M.register({
		id = "provider.connect",
		title = "Connect Provider",
		description = "Connect a new AI provider",
		category = "model",
		keybind = "<leader>op",
		action = function()
			lifecycle.ensure_connected(function()
				-- Fetch both providers and auth methods
				client.list_providers(function(err, response)
					if err then
						vim.schedule(function()
							vim.notify(
								"Failed to list providers: " .. tostring(err.message or err),
								vim.log.levels.ERROR
							)
						end)
						return
					end

					client.get_provider_auth(function(auth_err, auth_methods)
						vim.schedule(function()
							-- Response is { all: [...], default: {...}, connected: [...] }
							local provider_list = response and response.all or {}
							if #provider_list == 0 then
								vim.notify("No providers available", vim.log.levels.WARN)
								return
							end

							-- Auth methods is a map { provider_id: [{type, label}] }
							auth_methods = auth_methods or {}

							-- Build connected lookup set
							local connected_set = {}
							if response.connected then
								for _, cid in ipairs(response.connected) do
									connected_set[cid] = true
								end
							end

							-- Provider priority for sorting (like TUI)
							local provider_priority = {
								opencode = 0,
								anthropic = 1,
								["github-copilot"] = 2,
								openai = 3,
								google = 4,
							}

							-- Build items with priority for popular providers
							local items = {}
							for _, provider in ipairs(provider_list) do
								local is_connected = connected_set[provider.id] or false
								local priority = provider_priority[provider.id] or 99

								-- Add descriptions for popular providers (like TUI)
								local description = nil
								if provider.id == "opencode" then
									description = "(Recommended)"
								elseif provider.id == "anthropic" then
									description = "(Claude Max or API key)"
								elseif provider.id == "openai" then
									description = "(ChatGPT Plus/Pro or API key)"
								elseif is_connected then
									description = "Connected"
								end

								table.insert(items, {
									label = provider.name or provider.id,
									value = provider.id,
									provider = provider,
									description = description,
									priority = 100 - priority, -- Higher = better
									auth_methods = auth_methods[provider.id] or { { type = "api", label = "API key" } },
								})
							end

							-- Sort by priority
							table.sort(items, function(a, b)
								return a.priority > b.priority
							end)

							local float = require("opencode.ui.float")
							float.create_searchable_menu(items, function(item)
								-- Start provider connection flow
								local methods = item.auth_methods
								if #methods == 1 then
									-- Single auth method, go directly
									M._connect_provider_with_method(item.provider, methods[1], 0)
								else
									-- Multiple auth methods, let user choose
									local method_items = {}
									for i, method in ipairs(methods) do
										table.insert(method_items, {
											label = method.label or method.type,
											value = i - 1, -- 0-indexed for API
											method = method,
										})
									end

									float.create_menu(method_items, function(method_item)
										M._connect_provider_with_method(
											item.provider,
											method_item.method,
											method_item.value
										)
									end, { title = " Select auth method " })
								end
							end, { title = " Connect a provider ", width = 55 })
						end)
					end)
				end)
			end)
		end,
	})

	M.register({
		id = "provider.disconnect",
		title = "Disconnect Provider",
		description = "Remove authentication from a provider",
		category = "model",
		action = function()
			lifecycle.ensure_connected(function()
				client.list_providers(function(err, response)
					if err then
						vim.schedule(function()
							vim.notify(
								"Failed to list providers: " .. tostring(err.message or err),
								vim.log.levels.ERROR
							)
						end)
						return
					end
					vim.schedule(function()
						-- Only show connected providers
						local connected_set = {}
						if response.connected then
							for _, cid in ipairs(response.connected) do
								connected_set[cid] = true
							end
						end

						local provider_list = response and response.all or {}
						local items = {}

						for _, provider in ipairs(provider_list) do
							if connected_set[provider.id] then
								table.insert(items, {
									label = provider.name or provider.id,
									value = provider.id,
									provider = provider,
									description = "Connected",
								})
							end
						end

						if #items == 0 then
							vim.notify("No connected providers to disconnect", vim.log.levels.INFO)
							return
						end

						local float = require("opencode.ui.float")
						float.create_searchable_menu(items, function(item)
							vim.ui.select({ "Yes", "No" }, {
								prompt = "Disconnect from " .. (item.provider.name or item.provider.id) .. "?",
							}, function(choice)
								if choice == "Yes" then
									client.remove_provider_auth(item.provider.id, function(remove_err)
										vim.schedule(function()
											if remove_err then
												vim.notify(
													"Failed to disconnect: "
														.. tostring(remove_err.message or remove_err),
													vim.log.levels.ERROR
												)
												return
											end

											-- Remove all models from this provider from recent/favorite lists
											local lc_ok, lc = pcall(require, "opencode.local")
											if lc_ok then
												lc.model.remove_provider_models(item.provider.id)
											end

											-- Dispose to refresh state
											client.dispose(function()
												vim.notify(
													"Disconnected from " .. (item.provider.name or item.provider.id),
													vim.log.levels.INFO
												)
											end)
										end)
									end)
								end
							end)
						end, { title = " Disconnect Provider ", width = 50 })
					end)
				end)
			end)
		end,
		enabled = function()
			-- Only enable if there are connected providers
			-- This is a simple check - could be made more accurate with async check
			return true
		end,
	})

	-- Agent commands
	M.register({
		id = "agent.switch",
		title = "Switch Agent",
		description = "Change the AI agent",
		category = "agent",
		keybind = "<leader>oa",
		action = function()
			lifecycle.ensure_connected(function()
				client.list_agents(function(err, agents)
					if err then
						vim.schedule(function()
							vim.notify("Failed to list agents: " .. tostring(err.message or err), vim.log.levels.ERROR)
						end)
						return
					end
					vim.schedule(function()
						if not agents or #agents == 0 then
							vim.notify("No agents available", vim.log.levels.WARN)
							return
						end

						local items = {}
						for _, agent in ipairs(agents) do
							table.insert(items, {
								label = (agent.name or agent.id)
									.. (agent.description and (" - " .. agent.description) or ""),
								value = agent.id,
								agent = agent,
							})
						end

						local float = require("opencode.ui.float")
						float.create_searchable_menu(items, function(item)
							-- Use local.lua module for agent selection (like TUI's local.tsx)
							local lc_ok, lc = pcall(require, "opencode.local")
							if lc_ok then
								lc.agent.set(item.agent.name)
							end
							-- Also update old state for backward compatibility
							state.set_agent(item.agent.id, item.agent.name)
							-- Update input info bar if visible
							local input_ok, input = pcall(require, "opencode.ui.input")
							if input_ok and input.is_visible and input.is_visible() then
								input.update_info_bar()
							end
						end, { title = " Switch Agent ", width = 60 })
					end)
				end)
			end)
		end,
	})

	-- Action commands
	M.register({
		id = "action.abort",
		title = "Abort Request",
		description = "Stop the current AI request",
		category = "actions",
		keybind = "<leader>ox",
		action = function()
			opencode.abort()
		end,
		enabled = function()
			return state.is_streaming() or state.is_thinking()
		end,
		suggested = true,
	})

	M.register({
		id = "action.clear",
		title = "Clear Chat / New Session",
		description = "Start a new session (like TUI's /clear or /new)",
		category = "actions",
		keybind = "<leader>oc",
		action = function()
			opencode.clear()
		end,
	})

	M.register({
		id = "action.compact",
		title = "Compact Session",
		description = "Compact session messages",
		category = "actions",
		action = function()
			-- Note: This is a placeholder - actual compact functionality
			-- depends on server API support (session compaction)
			vim.notify("Compact session - not yet implemented in server API", vim.log.levels.WARN)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})

	M.register({
		id = "action.revert",
		title = "Revert Changes",
		description = "Revert all pending changes",
		category = "actions",
		action = function()
			local all_changes = changes.get_all()
			if #all_changes == 0 then
				vim.notify("No pending changes to revert", vim.log.levels.INFO)
				return
			end

			vim.ui.select({ "Yes", "No" }, {
				prompt = "Revert all " .. #all_changes .. " pending changes?",
			}, function(choice)
				if choice == "Yes" then
					for _, change in ipairs(all_changes) do
						changes.reject_change(change.id)
					end
					vim.notify("Reverted all changes", vim.log.levels.INFO)
				end
			end)
		end,
		enabled = function()
			return #changes.get_all() > 0
		end,
	})

	M.register({
		id = "action.status",
		title = "Show Status",
		description = "Show current session and connection status",
		category = "actions",
		keybind = "<leader>oS",
		action = function()
			-- Fetch full status from server (combines multiple endpoints)
			client.get_status(function(err, server_status)
				vim.schedule(function()
					local lines = {}
					local highlights = {}

					-- Helper to add a line with optional highlight
					local function add_line(text, hl_group)
						table.insert(lines, text)
						if hl_group then
							table.insert(highlights, { line = #lines, group = hl_group })
						end
					end

					-- Helper to add a section header
					local function add_section(title, count)
						if #lines > 0 then
							add_line("")
						end
						local header = count and string.format("%d %s", count, title) or title
						add_line(header, "Title")
					end

					-- Version
					if server_status and server_status.version then
						add_line("OpenCode v" .. server_status.version, "Type")
					elseif not err then
						add_line("OpenCode", "Type")
					else
						add_line("OpenCode (disconnected)", "ErrorMsg")
					end

					-- MCP Servers: Record<string, {status: "connected"|"disabled"|"failed"|...}>
					if server_status and server_status.mcp then
						local mcp_list = {}
						for name, info in pairs(server_status.mcp) do
							table.insert(mcp_list, { name = name, info = info })
						end
						table.sort(mcp_list, function(a, b)
							return a.name < b.name
						end)

						if #mcp_list > 0 then
							add_section("MCP Servers", #mcp_list)
							for _, mcp in ipairs(mcp_list) do
								local status_text = type(mcp.info) == "table" and mcp.info.status or "unknown"
								-- Capitalize first letter
								local display_status = status_text:sub(1, 1):upper() .. status_text:sub(2)
								local status_hl = status_text == "connected" and "DiagnosticOk" or "DiagnosticWarn"
								add_line("• " .. mcp.name .. " " .. display_status, status_hl)
							end
						end
					end

					-- LSP Servers: [{id, name, root, status}]
					if server_status and server_status.lsp and #server_status.lsp > 0 then
						add_section("LSP Servers", #server_status.lsp)
						for _, lsp in ipairs(server_status.lsp) do
							local name = lsp.name or lsp.id or "unknown"
							local status_hl = lsp.status == "connected" and "DiagnosticOk" or "DiagnosticWarn"
							add_line("• " .. name, status_hl)
						end
					end

					-- Formatters: [{name, extensions, enabled}]
					if server_status and server_status.formatters then
						-- Filter to only enabled formatters
						local enabled_formatters = {}
						for _, fmt in ipairs(server_status.formatters) do
							if fmt.enabled ~= false then
								table.insert(enabled_formatters, fmt)
							end
						end

						if #enabled_formatters > 0 then
							add_section("Formatters", #enabled_formatters)
							for _, fmt in ipairs(enabled_formatters) do
								add_line("• " .. (fmt.name or "unknown"))
							end
						end
					end

					-- Plugins: ["name@version", "file:///path/to/plugin", ...]
					if server_status and server_status.plugins and #server_status.plugins > 0 then
						add_section("Plugins", #server_status.plugins)
						for _, plugin_str in ipairs(server_status.plugins) do
							local name, version
							if plugin_str:match("^file://") then
								-- Extract name from file path
								name = plugin_str:match("([^/]+)$") or plugin_str
								version = nil
							elseif plugin_str:find("@") then
								-- Split name@version
								name, version = plugin_str:match("^(.+)@(.+)$")
							else
								name = plugin_str
								version = "latest"
							end
							local display = version and (name .. " @" .. version) or name
							add_line("• " .. display)
						end
					end

					-- If server didn't return any data, show local state
					if err or not server_status or (not server_status.version and not server_status.mcp) then
						local summary = state.get_status_summary()
						if #lines == 0 or (err and #lines <= 1) then
							add_line("")
						end

						local conn_icon = summary.connected and "●" or "○"
						local conn_status = summary.connected and "connected" or summary.connection_state
						local conn_hl = summary.connected and "DiagnosticOk" or "DiagnosticError"
						add_line("Connection: " .. conn_icon .. " " .. conn_status, conn_hl)

						if err then
							add_line("")
							add_line("(Could not fetch full status from server)", "Comment")
						end
					end

					-- Create floating window
					local float = require("opencode.ui.float")
					local width = 45
					local height = math.min(#lines + 2, 25)

					local popup, bufnr = float.create_centered_popup({
						width = width,
						height = height,
						title = "Status",
						border = "rounded",
					})

					popup:mount()

					vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

					for _, hl in ipairs(highlights) do
						local lt = vim.api.nvim_buf_get_lines(bufnr, hl.line - 1, hl.line, false)[1] or ""
						vim.api.nvim_buf_set_extmark(
							bufnr,
							hl_ns,
							hl.line - 1,
							0,
							{ end_col = #lt, hl_group = hl.group }
						)
					end

					vim.bo[bufnr].modifiable = false
					vim.bo[bufnr].buftype = "nofile"

					local close_fn = function()
						popup:unmount()
					end
					float.setup_close_keymaps(bufnr, close_fn)
				end)
			end)
		end,
		suggested = true,
	})

	-- MCP commands
	M.register({
		id = "mcp.status",
		title = "MCP Servers",
		description = "Show MCP server status",
		category = "mcp",
		keybind = "<leader>oS",
		action = function()
			client.get_mcp_status(function(err, status)
				if err then
					vim.schedule(function()
						vim.notify("Failed to get MCP status: " .. tostring(err.message or err), vim.log.levels.ERROR)
					end)
					return
				end
				vim.schedule(function()
					if not status or vim.tbl_isempty(status) then
						vim.notify("No MCP servers configured", vim.log.levels.INFO)
						return
					end

					local lines = { "MCP Server Status:", "" }
					for name, server in pairs(status) do
						local status_icon = server.status == "connected" and "●" or "○"
						table.insert(lines, string.format("  %s %s: %s", status_icon, name, server.status))
					end

					vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
				end)
			end)
		end,
	})

	M.register({
		id = "mcp.tools",
		title = "MCP Tools",
		description = "List available MCP tools",
		category = "mcp",
		action = function()
			client.get_mcp_status(function(err, status)
				if err then
					vim.schedule(function()
						vim.notify("Failed to get MCP status: " .. tostring(err.message or err), vim.log.levels.ERROR)
					end)
					return
				end
				vim.schedule(function()
					if not status then
						vim.notify("No MCP servers configured", vim.log.levels.INFO)
						return
					end

					-- Collect all tools from all servers
					local all_tools = {}
					for server_name, server in pairs(status) do
						if server.tools then
							for _, tool in ipairs(server.tools) do
								table.insert(all_tools, {
									name = tool.name,
									description = tool.description,
									server = server_name,
								})
							end
						end
					end

					if #all_tools == 0 then
						vim.notify("No MCP tools available", vim.log.levels.INFO)
						return
					end

					-- Show tools in a menu
					local items = {}
					for _, tool in ipairs(all_tools) do
						table.insert(items, {
							label = string.format("%s: %s", tool.server, tool.name),
							tool = tool,
						})
					end

					local float = require("opencode.ui.float")
					float.create_menu(items, function(item)
						vim.notify(
							string.format("Tool: %s - %s", item.tool.name, item.tool.description or "No description"),
							vim.log.levels.INFO
						)
					end, { title = " MCP Tools (" .. #all_tools .. ") " })
				end)
			end)
		end,
	})

	M.register({
		id = "mcp.refresh",
		title = "Refresh MCP",
		description = "Refresh MCP server connections",
		category = "mcp",
		action = function()
			-- Note: This is a placeholder - actual refresh functionality
			-- depends on server API support
			vim.notify("Refresh MCP - not yet implemented in server API", vim.log.levels.WARN)
		end,
	})

	-- Files commands
	-- System commands
	M.register({
		id = "system.restart",
		title = "Restart Server",
		description = "Restart the OpenCode server",
		category = "system",
		action = function()
			opencode.restart()
		end,
	})

	M.register({
		id = "system.disconnect",
		title = "Disconnect",
		description = "Disconnect from server (keep running)",
		category = "system",
		action = function()
			opencode.disconnect()
			vim.notify("Disconnected from OpenCode server", vim.log.levels.INFO)
		end,
		enabled = function()
			return state.is_connected()
		end,
	})

	M.register({
		id = "system.reconnect",
		title = "Reconnect",
		description = "Reconnect to the OpenCode server",
		category = "system",
		action = function()
			lifecycle.ensure_connected(function()
				vim.notify("Reconnected to OpenCode server", vim.log.levels.INFO)
			end)
		end,
		enabled = function()
			return not state.is_connected()
		end,
	})

	M.register({
		id = "system.logs",
		title = "View Logs",
		description = "Open the log viewer",
		category = "system",
		action = function()
			opencode.toggle_logs()
		end,
	})

	M.register({
		id = "system.help",
		title = "Help",
		description = "Show keybinding help",
		category = "system",
		keybind = "?",
		action = function()
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.show_help then
				chat.show_help()
			else
				-- Fallback: show basic help
				local lines = {
					" OpenCode Keymaps ",
					"",
					" <leader>oo - Toggle chat",
					" <leader>op - Command palette",
					" <leader>od - Show diff",
					" <leader>ox - Abort request",
					"",
					" In chat:",
					"   i - Focus input",
					"   q - Close chat",
					"   ? - This help",
					"",
					" In input:",
					"   <C-g> - Send",
					"   <Esc> - Cancel",
					"   ↑/↓ - History",
				}
				vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
			end
		end,
	})
end

-- Setup function
function M.setup()
	load_config()
	load_frecency()
	setup_highlights()
	register_defaults()
end

return M
