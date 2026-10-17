local M = {}

local NuiLine = require("nui.line")
local cs = require("opencode.ui.chat.state")
local selectors = require("opencode.selectors")

local namespace = vim.api.nvim_create_namespace("opencode_workspace_bar")
local bufnr, winid
local targets = {}
local applied_keys

local function manager()
	return require("opencode.ui.chat.workspace")
end

local function tabs_config()
	local config = require("opencode.state").get_config() or {}
	local view = cs.workspace.last_view
	return vim.tbl_deep_extend("force", {}, require("opencode.config").defaults.chat.session_tabs,
		(config.chat or {}).session_tabs or {}, (view and view.config or {}).session_tabs or {})
end

function M.winid()
	return winid and vim.api.nvim_win_is_valid(winid) and winid or nil
end

local function select_layout(id)
	manager().select(id)
	local layout = manager().current()
	if layout and layout.last_view then require("opencode.ui.chat").focus_view(layout.last_view) end
end

local function select_column(column)
	for _, target in ipairs(targets) do
		if column >= target.first and column <= target.last then
			select_layout(target.id)
			return
		end
	end
end

local function setup_buffer()
	local exists = bufnr and vim.api.nvim_buf_is_valid(bufnr)
	local keymaps = require("opencode.util.keymap")
	local keys = { keymaps.get("session_tabs"), keymaps.get("chat"), keymaps.get("menu") }
	if exists and vim.deep_equal(keys, applied_keys) then return end
	if not exists then
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(bufnr, "opencode [tabs]")
		vim.bo[bufnr].bufhidden = "hide"
		vim.bo[bufnr].filetype = "opencode_tabs"
		vim.bo[bufnr].swapfile = false
		vim.bo[bufnr].modifiable = false
	end
	local map, apply = keymaps.mapper("session_tabs", bufnr)
	local opts = { silent = true, nowait = true }
	local chat_opts = { silent = true, nowait = true, scope = "chat" }
	map("n", "select", function()
		local mouse = vim.fn.getmousepos()
		if mouse.winid == M.winid() then select_column(mouse.wincol) end
	end, opts)
	map("n", "select", function()
		select_column(vim.fn.virtcol("."))
	end, { scope = "menu", silent = true, nowait = true })
	map("n", "next_session", function()
		if vim.v.count > 0 then
			local target = manager().list()[vim.v.count]
			if target then select_layout(target.id) end
		else manager().cycle(1) end
	end, chat_opts)
	map("n", "prev_session", function() manager().cycle(-math.max(1, vim.v.count)) end, chat_opts)
	map("n", "close_session", function() manager().close_current() end, chat_opts)
	map("n", "close", function()
		local current = manager().current()
		if current and current.last_view then require("opencode.ui.chat").focus_view(current.last_view) end
	end, chat_opts)
	apply()
	applied_keys = keys
	local mouse_keys = {}
	for _, key in ipairs(keymaps.keys(keys[1].select)) do
		if key:lower():match("mouse>$") then mouse_keys[keymaps.code(key)] = true end
	end
	-- The first click is dispatched in the source buffer before the bar gains focus.
	vim.on_key(function(key)
		if not mouse_keys[key] then return end
		vim.schedule(function()
			local window = M.winid()
			if window and vim.api.nvim_get_current_win() == window then
				local mouse = vim.fn.getmousepos()
				if mouse.winid == window then select_column(mouse.wincol) end
			end
		end)
	end, namespace)
end

function M.remove()
	vim.on_key(nil, namespace)
	local window = M.winid()
	winid, targets = nil, {}
	if window then pcall(vim.api.nvim_win_close, window, true) end
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then pcall(vim.api.nvim_buf_delete, bufnr, { force = true }) end
	bufnr = nil
end

function M.ensure()
	if tabs_config().enabled == false then M.remove(); return end
	if cs.workspace.tabpage ~= vim.api.nvim_get_current_tabpage() then return end
	if M.winid() and vim.api.nvim_win_get_tabpage(winid) ~= cs.workspace.tabpage then M.remove() end
	if M.winid() then M.update(); return winid end
	setup_buffer()
	local previous = vim.api.nvim_get_current_win()
	vim.cmd("noautocmd topleft 1split")
	winid = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(winid, bufnr)
	local wo = vim.wo[winid]
	wo.winfixheight = true
	wo.number, wo.relativenumber = false, false
	wo.signcolumn, wo.foldcolumn = "no", "0"
	wo.wrap, wo.list, wo.spell = false, false, false
	wo.cursorline, wo.cursorcolumn = false, false
	wo.scrolloff, wo.sidescrolloff = 0, 0
	wo.colorcolumn, wo.winbar, wo.statusline = "", "", " "
	wo.fillchars = "eob: "
	wo.winhighlight = "Normal:OpenCodeWinbar,EndOfBuffer:OpenCodeWinbar,StatusLine:OpenCodeWinbar,StatusLineNC:OpenCodeWinbar,WinSeparator:OpenCodeWinbarSeparator"
	pcall(function() wo.statuscolumn = "" end)
	vim.api.nvim_win_set_height(winid, 1)
	if vim.api.nvim_win_is_valid(previous) then vim.api.nvim_set_current_win(previous) end
	M.update()
	return winid
end

local function session_label(layout, icons)
	local id = layout.session_id or (layout.last_view and cs.session(layout.last_view).id)
	local session = id and selectors.get_session_view(id, { session_id = id })
	local title = session and session:title() or id or "New session"
	title = tostring(title):gsub("[%c]", " ")
	title = require("opencode.util.text").truncate(title, 18, "...")
	local status, unread = "Idle", false
	if session then
		if session:is_waiting() then status = "Waiting"
		elseif session:is_busy() then status = "Running"
		elseif session:is_error() then status = "Error"
		elseif session:is_unread() then status, unread = "Waiting", true end
	end
	local icon = ({ Running = icons.running or "●", Waiting = icons.waiting or "◈", Error = icons.error or "✕", Idle = icons.idle or "○" })[status]
	if unread then icon = icons.unread or "◆" end
	return title, icon, status
end

function M.update()
	if not M.winid() then return end
	setup_buffer()
	local config = tabs_config()
	if config.enabled == false then M.remove(); return end
	local session_tabs = require("opencode.ui.chat.session_tabs")
	if session_tabs.ensure_highlights then session_tabs.ensure_highlights(config) end
	local layouts, current = manager().list(), manager().current()
	local current_index = 1
	for index, layout in ipairs(layouts) do if current and layout.id == current.id then current_index = index; break end end
	local width, labels = vim.api.nvim_win_get_width(winid), {}
	for index, layout in ipairs(layouts) do
		local title, icon, status = session_label(layout, config.icons or {})
		labels[index] = { title = title, icon = icon, status = status, text = " " .. icon .. " " .. title .. " " }
	end
	local separator = config.separator or " │ "
	local max_tabs = math.max(1, math.floor(tonumber(config.max_tabs) or 3))
	if config.auto_fit or config.max_tabs == "auto" then max_tabs = #layouts end
	max_tabs = math.max(1, math.min(max_tabs, #layouts, width))
	local first, last
	while true do
		first = math.max(1, math.min(current_index - math.floor(max_tabs / 2), #layouts - max_tabs + 1))
		last = math.min(#layouts, first + max_tabs - 1)
		local parts = {}
		if first > 1 then parts[#parts + 1] = "‹" end
		for index = first, last do parts[#parts + 1] = labels[index].text end
		if last < #layouts then parts[#parts + 1] = "›" end
		if max_tabs == 1 or vim.fn.strdisplaywidth(table.concat(parts, separator)) <= width then break end
		max_tabs = max_tabs - 1
	end
	-- On very narrow screens give the active label priority over overflow arrows.
	local left, right = first > 1, last < #layouts
	local arrow_width = 1 + vim.fn.strdisplaywidth(separator)
	if max_tabs == 1 and (left and arrow_width or 0) + (right and arrow_width or 0) + 6 > width then
		left, right = false, false
	end
	local line, column = NuiLine(), 0
	targets = {}
	local function append(text, highlight)
		line:append(text, highlight)
		column = column + vim.fn.strdisplaywidth(text)
	end
	local function label(id, text, highlight)
		if column > 0 then append(separator, "OpenCodeWinbar") end
		local start = column + 1
		append(text, highlight)
		targets[#targets + 1] = { first = start, last = column, id = id }
	end
	if left then label(layouts[first - 1].id, "‹", "OpenCodeWinbar") end
	for index = first, last do
		local layout = layouts[index]
		local title, icon, status = labels[index].title, labels[index].icon, labels[index].status
		local active = current and layout.id == current.id
		if column > 0 then append(separator, "OpenCodeWinbar") end
		local start = column + 1
		local available = width - column - (right and arrow_width or 0)
		local truncate = require("opencode.util.text").truncate
		local prefix = truncate(" " .. icon, available)
		append(prefix, "OpenCodeWinbar" .. (active and "Current" or "") .. status)
		append(truncate(" " .. title .. " ", available - vim.fn.strdisplaywidth(prefix), "..."),
			active and "OpenCodeWinbarCurrent" or "OpenCodeWinbar")
		targets[#targets + 1] = { first = start, last = column, id = layout.id }
	end
	if right then label(layouts[last + 1].id, "›", "OpenCodeWinbar") end
	vim.bo[bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line:content() })
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	line:highlight(bufnr, namespace, 1)
	vim.bo[bufnr].modifiable = false
end

return M
