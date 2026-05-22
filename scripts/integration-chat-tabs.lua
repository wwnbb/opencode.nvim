-- Headless integration coverage for chat session tabs with real nui.nvim/plenary.nvim.
-- Run with: ./scripts/test-headless.sh scripts/integration-chat-tabs.lua

local function fail(message)
	error(message, 0)
end

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		fail(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_true(value, message)
	if not value then
		fail(message)
	end
end

local function assert_contains(text, needle, message)
	if not text:find(needle, 1, true) then
		fail(message .. ": missing " .. vim.inspect(needle) .. " in " .. vim.inspect(text))
	end
end

local function assert_not_contains(text, needle, message)
	if text:find(needle, 1, true) then
		fail(message .. ": unexpected " .. vim.inspect(needle) .. " in " .. vim.inspect(text))
	end
end

local function ellipsis_count(text)
	local _, count = text:gsub("%.%.%.", "")
	return count
end

local function label_count(text, label)
	local count = 0
	local start = 1
	while true do
		local found = text:find(label, start, true)
		if not found then
			return count
		end
		count = count + 1
		start = found + #label
	end
end

local function visible_title_count(text)
	local count = 0
	for index = 1, 5 do
		if text:find("Tab " .. index, 1, true) then
			count = count + 1
		end
	end
	return count
end

local function is_visual_or_select_mode(mode)
	return mode == "v" or mode == "V" or mode == string.char(22) or mode == "s" or mode == "S" or mode == string.char(19)
end

local function tab_line(chat_view)
	assert_true(chat_view.session_tabs_bufnr and vim.api.nvim_buf_is_valid(chat_view.session_tabs_bufnr), "tab buffer exists")
	local lines = vim.api.nvim_buf_get_lines(chat_view.session_tabs_bufnr, 0, -1, false)
	return lines[1] or ""
end

local function find_target(chat_view, predicate)
	for id, target in pairs(chat_view.winbar_targets or {}) do
		if type(target) == "table" and predicate(target) then
			return id, target
		end
	end
	return nil, nil
end

local function has_keymap(bufnr, mode, lhs)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
		if map.lhs == lhs then
			return true
		end
	end
	return false
end

local function hl_bg(name)
	local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
	return hl.bg
end

local function hl_fg(name)
	local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
	return hl.fg
end

local function assert_visible_window(text, visible, hidden, expected_ellipsis, expected_overflow, label)
	for _, title in ipairs(visible) do
		assert_contains(text, title, label)
	end
	for _, title in ipairs(hidden) do
		assert_not_contains(text, title, label)
	end
	assert_eq(visible_title_count(text), 3, label .. " renders only max_tabs real tabs")
	assert_eq(ellipsis_count(text), expected_ellipsis, label .. " ellipsis count")
	for overflow_label, expected_count in pairs(expected_overflow or {}) do
		assert_eq(label_count(text, overflow_label), expected_count, label .. " overflow " .. overflow_label .. " count")
	end
end

vim.o.columns = 140
vim.o.lines = 40

local dynamic_color_calls = 0
local function dynamic_tab_colors()
	dynamic_color_calls = dynamic_color_calls + 1
	if vim.o.background == "light" then
		return {
			active_fg = "#111111",
			active_bg = "#eeeeee",
			inactive_fg = "#222222",
			inactive_bg = "#ffffff",
			idle_fg = "#333333",
			active_idle_fg = "#444444",
		}
	end
	return {
		active_fg = "#eeeeee",
		active_bg = "#111111",
		inactive_fg = "#dddddd",
		inactive_bg = "#222222",
		idle_fg = "#cccccc",
		current_idle_fg = "#bbbbbb",
	}
end

local opencode = require("opencode")
opencode.setup({
	server = {
		auto_start = false,
		lazy = true,
	},
	chat = {
		layout = "float",
		session_tabs = {
			enabled = true,
			max_tabs = 3,
			separator = " | ",
			colors = dynamic_tab_colors,
			icons = {
				running = "R",
				waiting = "W",
				idle = "I",
				error = "E",
			},
		},
	},
	lualine = {
		enabled = false,
	},
})

local client = require("opencode.client")
client.get_messages = function(_, _, callback)
	callback(nil, {})
end

local app_state = require("opencode.state")
local chat = require("opencode.ui.chat")
local chat_view = require("opencode.ui.chat.state").state

for index = 1, 5 do
	app_state.set_session("session-" .. index, "Tab " .. index)
end
app_state.set_session("session-1", "Tab 1")

local chat_bufnr = chat.create()
vim.api.nvim_set_current_buf(chat_bufnr)
assert_true(has_keymap(chat_bufnr, "n", "0gt"), "chat buffer maps 0gt to the first session tab")
assert_true(has_keymap(chat_bufnr, "n", "5gt"), "chat buffer maps counted gt navigation")

vim.api.nvim_feedkeys("5gt", "mx", false)
assert_eq(app_state.get_session().id, "session-5", "5gt jumps to the fifth session tab")
vim.api.nvim_feedkeys("0gt", "mx", false)
assert_eq(app_state.get_session().id, "session-1", "0gt jumps to the first session tab")
vim.api.nvim_feedkeys("gt", "mx", false)
assert_eq(app_state.get_session().id, "session-2", "plain gt cycles to the next session tab")
vim.api.nvim_feedkeys("3gt", "mx", false)
assert_eq(app_state.get_session().id, "session-3", "Ngt jumps to the indexed session tab")
app_state.set_session("session-1", "Tab 1")

local bufnr = vim.api.nvim_create_buf(false, true)
local winid = vim.api.nvim_open_win(bufnr, true, {
	relative = "editor",
	row = 4,
	col = 8,
	width = 100,
	height = 20,
	style = "minimal",
})

chat_view.bufnr = bufnr
chat_view.winid = winid
chat_view.visible = true
chat_view.config = app_state.get_config().chat
chat_view.float_dims = {
	row = 4,
	col = 8,
	width = 100,
	height = 20,
}

chat.update_winbar()

vim.o.background = "dark"
chat.update_winbar()
assert_eq(hl_bg("OpenCodeWinbarCurrent"), 0x111111, "dynamic dark session tab background")
assert_eq(hl_fg("OpenCodeWinbarCurrentIdle"), 0xbbbbbb, "dynamic dark active idle icon")
vim.o.background = "light"
assert_true(vim.wait(100, function()
	return hl_bg("OpenCodeWinbarCurrent") == 0xeeeeee
end), "background change refreshes dynamic session tab colors")
assert_eq(hl_fg("OpenCodeWinbarCurrentIdle"), 0x444444, "dynamic light active idle icon")
assert_true(dynamic_color_calls >= 2, "dynamic session tab colors are reevaluated")

assert_true(chat_view.session_tabs_winid and vim.api.nvim_win_is_valid(chat_view.session_tabs_winid), "float tab window stays open")
assert_true(vim.api.nvim_win_is_valid(winid), "chat window stays open")
assert_eq(vim.api.nvim_win_get_config(chat_view.session_tabs_winid).focusable, true, "float tab window is focusable")
assert_eq(vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width, 98, "tab strip covers the float inner width")
assert_eq(vim.wo[winid].winbar, "", "float chat window does not use native winbar")

assert_true(has_keymap(chat_view.session_tabs_bufnr, "n", "<LeftMouse>"), "float tab strip has a mouse selection mapping")
assert_true(has_keymap(chat_view.session_tabs_bufnr, "n", "<LeftDrag>"), "normal drag is swallowed")
assert_true(has_keymap(chat_view.session_tabs_bufnr, "v", "<LeftDrag>"), "visual drag is swallowed")
assert_true(has_keymap(chat_view.session_tabs_bufnr, "s", "<LeftDrag>"), "select drag is swallowed")
assert_true(has_keymap(chat_view.session_tabs_bufnr, "n", "v"), "visual mode key is disabled")
assert_true(has_keymap(chat_view.session_tabs_bufnr, "n", "V"), "linewise visual mode key is disabled")

vim.api.nvim_set_current_win(chat_view.session_tabs_winid)
vim.api.nvim_feedkeys("v", "mx", false)
assert_eq(vim.api.nvim_get_current_win(), winid, "visual mode key returns focus to chat")
assert_true(not is_visual_or_select_mode(vim.api.nvim_get_mode().mode), "tab strip does not remain in visual mode")

local first_line = tab_line(chat_view)
assert_visible_window(
	first_line,
	{ "Tab 1", "Tab 2", "Tab 3" },
	{ "Tab 4", "Tab 5" },
	1,
	{ ["...2"] = 1 },
	"initial view"
)

local tab3_target = find_target(chat_view, function(target)
	return target.kind == "session" and target.session_id == "session-3"
end)
assert_true(tab3_target ~= nil, "visible session tab has a click target")

chat.select_winbar_session(tab3_target)
assert_eq(app_state.get_session().id, "session-3", "selecting a visible tab switches session")
chat.update_winbar()

local middle_line = tab_line(chat_view)
assert_visible_window(
	middle_line,
	{ "Tab 2", "Tab 3", "Tab 4" },
	{ "Tab 1", "Tab 5" },
	2,
	{ ["...1"] = 2 },
	"centered tab 3 view"
)

local left_page_target = find_target(chat_view, function(target)
	return target.kind == "page" and target.start == 1
end)
local right_page_target = find_target(chat_view, function(target)
	return target.kind == "page" and target.start == 3
end)
assert_true(left_page_target ~= nil, "left ellipsis has a page target")
assert_true(right_page_target ~= nil, "right ellipsis has a page target")
assert_true(#chat_view.session_tabs_mouse_targets >= 5, "float tab strip records mouse hit targets")

vim.api.nvim_set_current_win(chat_view.session_tabs_winid)
chat.select_winbar_session(right_page_target)
assert_true(vim.api.nvim_win_is_valid(winid), "chat window remains open after paging")
assert_eq(vim.api.nvim_get_current_win(), winid, "paging returns focus to chat window")

local end_line = tab_line(chat_view)
assert_visible_window(
	end_line,
	{ "Tab 3", "Tab 4", "Tab 5" },
	{ "Tab 1", "Tab 2" },
	1,
	{ ["...2"] = 1 },
	"end view"
)

local back_page_target = find_target(chat_view, function(target)
	return target.kind == "page" and target.start == 1
end)
assert_true(back_page_target ~= nil, "left ellipsis from end view has a page target")

vim.api.nvim_set_current_win(chat_view.session_tabs_winid)
chat.select_winbar_session(back_page_target)
assert_true(vim.api.nvim_win_is_valid(winid), "chat window remains open after paging back")
assert_eq(vim.api.nvim_get_current_win(), winid, "paging back returns focus to chat window")

local back_line = tab_line(chat_view)
assert_visible_window(
	back_line,
	{ "Tab 1", "Tab 2", "Tab 3" },
	{ "Tab 4", "Tab 5" },
	1,
	{ ["...2"] = 1 },
	"paged back view"
)

app_state.upsert_session({
	id = "session-1",
	title = "Комиссия по символу maker taker",
	name = "Комиссия по символу maker taker",
}, { touch = false })
chat.update_winbar()
local unicode_line = tab_line(chat_view)
assert_contains(unicode_line, "Комиссия по сим...", "unicode tab title truncates on character boundaries")

print("Chat tab integration passed")
