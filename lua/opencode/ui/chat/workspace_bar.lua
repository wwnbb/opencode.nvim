local M = {}

local cs = require("opencode.ui.chat.state")
local selectors = require("opencode.selectors")
local tab_label = require("opencode.ui.chat.tab_label")

local saved_options

local function manager()
	return require("opencode.ui.chat.workspace")
end

local function tabs_config()
	local config = require("opencode.state").get_config() or {}
	local view = cs.workspace.last_view
	return vim.tbl_deep_extend("force", {}, require("opencode.config").defaults.chat.session_tabs,
		(config.chat or {}).session_tabs or {}, (view and view.config or {}).session_tabs or {})
end

function M.remove()
	if not saved_options then return end
	local errors = {}
	for _, option in ipairs({ "tabline", "showtabline" }) do
		local ok, err = pcall(vim.api.nvim_set_option_value, option, saved_options[option], { scope = "global" })
		if not ok then errors[#errors + 1] = tostring(err) end
	end
	if #errors > 0 then error(table.concat(errors, "\n"), 0) end
	saved_options = nil
	if not cs.workspace.switching then vim.cmd.redrawtabline() end
end

local function session_label(layout, icons)
	local id = layout.session_id or (layout.last_view and cs.session(layout.last_view).id)
	local session = id and selectors.get_session_view(id, { session_id = id })
	local title = tab_label.title(session and session:title() or id or "New session")
	local sessions, seen = {}, {}
	local function add(session_id)
		if not session_id or seen[session_id] then return end
		seen[session_id] = true
		local item = session_id == id and session or selectors.get_session_view(session_id, { session_id = session_id })
		if item then sessions[#sessions + 1] = item end
	end
	add(id)
	for _, view in ipairs(cs.all()) do
		if view.workspace_id == layout.id then add(cs.session(view).id) end
	end
	local icon, status = tab_label.icon(tab_label.status(sessions), icons)
	return title, icon, status
end

function M.update()
	local config = tabs_config()
	if config.enabled == false or cs.workspace.tabpage ~= vim.api.nvim_get_current_tabpage() then M.remove(); return end
	local layouts, current = manager().list(), manager().current()
	if not current or #layouts == 0 then M.remove(); return end
	local session_tabs = require("opencode.ui.chat.session_tabs")
	if session_tabs.ensure_highlights then session_tabs.ensure_highlights(config) end
	local current_index = 1
	for index, layout in ipairs(layouts) do if current and layout.id == current.id then current_index = index; break end end
	local width, labels = vim.o.columns, {}
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
		if max_tabs == 1 or vim.fn.strwidth(table.concat(parts, separator)) <= width then break end
		max_tabs = max_tabs - 1
	end
	-- On very narrow screens give the active label priority over overflow arrows.
	local left, right = first > 1, last < #layouts
	local arrow_width = 1 + vim.fn.strwidth(separator)
	if max_tabs == 1 and (left and arrow_width or 0) + (right and arrow_width or 0) + 6 > width then
		left, right = false, false
	end
	local parts, text, column = {}, "", 0
	local function target(id)
		parts[#parts + 1] = string.format("%%%d@v:lua.__opencode_workspace_tab_click@", id)
	end
	local function append(text, highlight)
		parts[#parts + 1] = "%#" .. highlight .. "#" .. text:gsub("%%", "%%%%")
	end
	local function content(value, highlight)
		append(value, highlight)
		text = text .. value
		column = vim.fn.strwidth(text)
	end
	local function separate()
		if column == 0 then return end
		if vim.fn.strwidth(text .. separator) < column + vim.fn.strwidth(separator) then
			-- Keep combining separators attached across native statusline item boundaries.
			parts[#parts] = parts[#parts] .. separator:gsub("%%", "%%%%")
			text = text .. separator
			column = vim.fn.strwidth(text)
		else
			target(0); content(separator, "OpenCodeWinbar")
		end
	end
	local function label(id, text, highlight)
		separate()
		target(id)
		content(text, highlight)
	end
	if left then label(layouts[first - 1].id, "‹", "OpenCodeWinbar") end
	for index = first, last do
		local layout = layouts[index]
		local title, icon, status = labels[index].title, labels[index].icon, labels[index].status
		local active = current and layout.id == current.id
		separate()
		target(layout.id)
		local available = width - column - (right and arrow_width or 0)
		local truncate = require("opencode.util.text").truncate
		local prefix = truncate(" " .. icon, available, nil, vim.fn.strwidth)
		content(prefix, "OpenCodeWinbar" .. (active and "Current" or "") .. status)
		content(truncate(" " .. title .. " ", available - vim.fn.strwidth(prefix), "...", vim.fn.strwidth),
			active and "OpenCodeWinbarCurrent" or "OpenCodeWinbar")
	end
	if right then label(layouts[last + 1].id, "›", "OpenCodeWinbar") end
	-- Consume the remaining row so native clicks cannot create, close or switch tabs.
	target(0)
	parts[#parts + 1] = "%#OpenCodeWinbar#%="
	saved_options = saved_options or { tabline = vim.o.tabline, showtabline = vim.o.showtabline }
	vim.o.tabline, vim.o.showtabline = table.concat(parts), 2
	if not cs.workspace.switching then vim.cmd.redrawtabline() end
end

_G.__opencode_workspace_tab_click = function(id, _, button, modifiers)
	if id == 0 or not saved_options or cs.workspace.tabpage ~= vim.api.nvim_get_current_tabpage() then return end
	local name = ({ l = "Left", r = "Right", m = "Middle" })[button]
	if not name then return end
	local key = "<"
	for _, modifier in ipairs({ "s", "c", "a", "m" }) do
		if modifiers:find(modifier, 1, true) then key = key .. modifier:upper() .. "-" end
	end
	key = key .. name .. "Mouse>"
	local keymaps = require("opencode.util.keymap")
	if keymaps.matches(keymaps.get("session_tabs").select, key) then manager().select(id) end
end

local group = vim.api.nvim_create_augroup("OpenCodeWorkspaceTabline", { clear = true })
vim.api.nvim_create_autocmd("TabLeave", { group = group, callback = M.remove })
vim.api.nvim_create_autocmd({ "TabEnter", "VimResized", "ColorScheme" }, { group = group, callback = M.update })

return M
