-- Headless integration coverage for chat session tabs with real nui.nvim/plenary.nvim.
-- Run with: ./tests/run.sh integration

describe("opencode chat tabs", function()
	it("renders and navigates session tabs", function()

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
	assert.is_truthy(chat_view.session_tabs_bufnr and vim.api.nvim_buf_is_valid(chat_view.session_tabs_bufnr), "tab buffer exists")
	local lines = vim.api.nvim_buf_get_lines(chat_view.session_tabs_bufnr, 0, -1, false)
	return lines[1] or ""
end

local function assert_tab_line_fits(chat_view, label)
	local text = tab_line(chat_view)
	local line_width = vim.fn.strdisplaywidth(text)
	local tabbar_width = vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width
	assert.is_true(line_width <= tabbar_width, label .. " fits in tabbar window")
	return text, line_width, tabbar_width
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
		assert.is_truthy((text):find(title, 1, true), label)
	end
	for _, title in ipairs(hidden) do
		assert.is_nil((text):find(title, 1, true), label)
	end
	assert.equals(3, visible_title_count(text), label .. " renders only max_tabs real tabs")
	assert.equals(expected_ellipsis, ellipsis_count(text), label .. " ellipsis count")
	for overflow_label, expected_count in pairs(expected_overflow or {}) do
		assert.equals(expected_count, label_count(text, overflow_label), label .. " overflow " .. overflow_label .. " count")
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
assert.is_truthy(has_keymap(chat_bufnr, "n", "gt"), "chat buffer maps gt to cycle or counted sessions")
assert.is_truthy(has_keymap(chat_bufnr, "n", "5"), "digit keys map directly for question option selection")
assert.is_truthy(not has_keymap(chat_bufnr, "n", "5gt"), "no literal Ngt mapping so digit presses never wait on timeout")

vim.api.nvim_feedkeys("5gt", "mx", false)
assert.equals("session-5", app_state.get_session().id, "5gt jumps to the fifth session tab")
vim.api.nvim_feedkeys("0gt", "mx", false)
assert.equals("session-1", app_state.get_session().id, "0gt jumps to the first session tab")
vim.api.nvim_feedkeys("gt", "mx", false)
assert.equals("session-2", app_state.get_session().id, "plain gt cycles to the next session tab")
vim.api.nvim_feedkeys("3gt", "mx", false)
assert.equals("session-3", app_state.get_session().id, "Ngt jumps to the indexed session tab")
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
assert.equals(0x111111, hl_bg("OpenCodeWinbarCurrent"), "dynamic dark session tab background")
assert.equals(0xbbbbbb, hl_fg("OpenCodeWinbarCurrentIdle"), "dynamic dark active idle icon")
vim.o.background = "light"
assert.is_truthy(vim.wait(100, function()
	return hl_bg("OpenCodeWinbarCurrent") == 0xeeeeee
end), "background change refreshes dynamic session tab colors")
assert.equals(0x444444, hl_fg("OpenCodeWinbarCurrentIdle"), "dynamic light active idle icon")
assert.is_truthy(dynamic_color_calls >= 2, "dynamic session tab colors are reevaluated")

local configured_tab_colors = chat_view.config.session_tabs.colors
vim.api.nvim_set_hl(0, "TabLine", { fg = "#123456", bg = "#abcdef" })
vim.api.nvim_set_hl(0, "TabLineSel", { fg = "#fedcba", bg = "#654321" })
chat_view.config.session_tabs.colors = {}
chat.update_winbar()
assert.equals(0x123456, hl_fg("OpenCodeWinbar"), "default inactive tab foreground inherits TabLine")
assert.equals(0xabcdef, hl_bg("OpenCodeWinbar"), "default inactive tab background inherits TabLine")
assert.equals(0xfedcba, hl_fg("OpenCodeWinbarCurrent"), "default active tab foreground inherits TabLineSel")
assert.equals(0x654321, hl_bg("OpenCodeWinbarCurrent"), "default active tab background inherits TabLineSel")
assert.equals(0xfedcba, hl_fg("OpenCodeWinbarCurrentIdle"), "default active idle icon inherits TabLineSel")
chat_view.config.session_tabs.colors = configured_tab_colors
chat.update_winbar()

assert.is_truthy(chat_view.session_tabs_winid and vim.api.nvim_win_is_valid(chat_view.session_tabs_winid), "float tab window stays open")
assert.is_truthy(vim.api.nvim_win_is_valid(winid), "chat window stays open")
assert.equals(true, vim.api.nvim_win_get_config(chat_view.session_tabs_winid).focusable, "float tab window is focusable")
assert.equals(98, vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width, "tab strip covers the float inner width")
assert.equals("", vim.wo[winid].winbar, "float chat window does not use native winbar")

assert.is_truthy(has_keymap(chat_view.session_tabs_bufnr, "n", "<LeftMouse>"), "float tab strip has a mouse selection mapping")
assert.is_truthy(has_keymap(chat_view.session_tabs_bufnr, "n", "<LeftDrag>"), "normal drag is swallowed")
assert.is_truthy(has_keymap(chat_view.session_tabs_bufnr, "v", "<LeftDrag>"), "visual drag is swallowed")
assert.is_truthy(has_keymap(chat_view.session_tabs_bufnr, "s", "<LeftDrag>"), "select drag is swallowed")
assert.is_truthy(has_keymap(chat_view.session_tabs_bufnr, "n", "v"), "visual mode key is disabled")
assert.is_truthy(has_keymap(chat_view.session_tabs_bufnr, "n", "V"), "linewise visual mode key is disabled")

vim.api.nvim_set_current_win(chat_view.session_tabs_winid)
vim.api.nvim_feedkeys("v", "mx", false)
assert.equals(winid, vim.api.nvim_get_current_win(), "visual mode key returns focus to chat")
assert.is_truthy(not is_visual_or_select_mode(vim.api.nvim_get_mode().mode), "tab strip does not remain in visual mode")

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
assert.is_truthy(tab3_target ~= nil, "visible session tab has a click target")

chat.select_winbar_session(tab3_target)
assert.equals("session-3", app_state.get_session().id, "selecting a visible tab switches session")
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
assert.is_truthy(left_page_target ~= nil, "left ellipsis has a page target")
assert.is_truthy(right_page_target ~= nil, "right ellipsis has a page target")
assert.is_truthy(#chat_view.session_tabs_mouse_targets >= 5, "float tab strip records mouse hit targets")

vim.api.nvim_set_current_win(chat_view.session_tabs_winid)
chat.select_winbar_session(right_page_target)
assert.is_truthy(vim.api.nvim_win_is_valid(winid), "chat window remains open after paging")
assert.equals(winid, vim.api.nvim_get_current_win(), "paging returns focus to chat window")

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
assert.is_truthy(back_page_target ~= nil, "left ellipsis from end view has a page target")

vim.api.nvim_set_current_win(chat_view.session_tabs_winid)
chat.select_winbar_session(back_page_target)
assert.is_truthy(vim.api.nvim_win_is_valid(winid), "chat window remains open after paging back")
assert.equals(winid, vim.api.nvim_get_current_win(), "paging back returns focus to chat window")

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
assert.is_truthy((unicode_line):find("Комиссия по сим...", 1, true), "unicode tab title truncates on character boundaries")

for index = 1, 5 do
	app_state.upsert_session({
		id = "session-" .. index,
		title = "Tab " .. index,
		name = "Tab " .. index,
	}, { touch = false })
	app_state.set_session_status("session-" .. index, "idle")
	app_state.set_session_pending_counts("session-" .. index, {})
end

chat_view.config.session_tabs.auto_fit = true
chat_view.config.session_tabs.max_tabs = 3
chat_view.session_tabs_start = nil
chat_view.session_tabs_current_id = nil
chat_view.float_dims.width = 100
chat.update_winbar()
local auto_full_line = assert_tab_line_fits(chat_view, "auto-fit wide tab strip")
assert.equals(98, vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width, "auto-fit wide tabbar width")
assert.equals(5, visible_title_count(auto_full_line), "auto-fit wide view shows all session tabs")
assert.equals(0, ellipsis_count(auto_full_line), "auto-fit wide view has no overflow ellipsis")

chat_view.session_tabs_start = nil
chat_view.session_tabs_current_id = nil
chat_view.float_dims.width = 37
chat.update_winbar()
local auto_narrow_line = assert_tab_line_fits(chat_view, "auto-fit narrow tab strip")
assert.equals(35, vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width, "auto-fit narrow tabbar width")
assert.equals(2, visible_title_count(auto_narrow_line), "auto-fit narrow view shows the largest fitting tab count")
assert.equals(2, ellipsis_count(auto_narrow_line), "auto-fit narrow view keeps overflow ellipses")
assert.equals(1, label_count(auto_narrow_line, "...1"), "auto-fit narrow view keeps left overflow count")
assert.equals(1, label_count(auto_narrow_line, "...2"), "auto-fit narrow view keeps right overflow count")

chat_view.config.session_tabs.auto_fit = false
chat_view.config.session_tabs.max_tabs = "auto"
app_state.set_session_status("session-2", "busy")
app_state.set_session_pending_counts("session-4", { questions = 1 })
chat_view.session_tabs_start = nil
chat_view.session_tabs_current_id = nil
chat_view.float_dims.width = 46
chat.update_winbar()
local auto_busy_line = assert_tab_line_fits(chat_view, "auto-fit busy tab strip")
assert.equals(44, vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width, "auto-fit busy tabbar width")
assert.equals(2, visible_title_count(auto_busy_line), "auto max_tabs alias reserves marker width")
assert.is_truthy((auto_busy_line):find("R1", 1, true), "auto-fit keeps running marker summary")
assert.is_truthy((auto_busy_line):find("W1", 1, true), "auto-fit keeps waiting marker summary")
assert.equals(1, label_count(auto_busy_line, "...1"), "auto-fit busy view keeps left overflow count")
assert.equals(1, label_count(auto_busy_line, "...2"), "auto-fit busy view keeps right overflow count")

local btw = require("opencode.btw")
local original_pending_count = btw.pending_count
btw.pending_count = function() return 1 end
chat.update_winbar()
local aside_line = assert_tab_line_fits(chat_view, "auto-fit side-question indicator")
assert.is_truthy((aside_line):find("/btw", 1, true), "side question progress appears in the tab strip")
chat_view.config.session_tabs.enabled = false
chat.update_winbar()
local status_only_line = assert_tab_line_fits(chat_view, "side-question indicator with tabs disabled")
assert.is_truthy((status_only_line):find("/btw", 1, true), "side question stays visible with tabs disabled")
chat_view.config.session_tabs.enabled = true
btw.pending_count = original_pending_count
chat.update_winbar()

print("Chat tab integration passed")
	end)
end)
