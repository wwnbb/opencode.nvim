-- Float session tab strip: colors, strip-owned keys, and status summaries.
local app_state = require("opencode.state")
local chat = require("opencode.ui.chat")
local chat_view = require("opencode.ui.chat.state").state

local function has_keymap(bufnr, mode, lhs)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
		if map.lhs == lhs then return true end
	end
	return false
end

local function hl(name) return vim.api.nvim_get_hl(0, { name = name, link = false }) end

local function tab_line()
	local text = vim.api.nvim_buf_get_lines(chat_view.session_tabs_bufnr, 0, -1, false)[1] or ""
	assert.is_true(vim.fn.strdisplaywidth(text) <= vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width)
	return text
end

describe("opencode float chat tabs", function()
	local winid, color_calls
	local function dynamic_tab_colors()
		color_calls = color_calls + 1
		if vim.o.background == "light" then
			return { active_fg = "#111111", active_bg = "#eeeeee", inactive_fg = "#222222", inactive_bg = "#ffffff",
				idle_fg = "#333333", active_idle_fg = "#444444" }
		end
		return { active_fg = "#eeeeee", active_bg = "#111111", inactive_fg = "#dddddd", inactive_bg = "#222222",
			idle_fg = "#cccccc", current_idle_fg = "#bbbbbb" }
	end

	before_each(function()
		color_calls = 0
		vim.o.columns, vim.o.lines = 140, 40
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "float", session_tabs = { enabled = true, max_tabs = 3, separator = " | ",
				colors = dynamic_tab_colors, icons = { running = "R", waiting = "W", idle = "I", error = "E" } } } })
		require("opencode.client").get_messages = function(_, _, callback) callback(nil, {}) end
		for index = 1, 5 do app_state.set_session("session-" .. index, "Tab " .. index) end
		app_state.set_session("session-1", "Tab 1")
		vim.api.nvim_set_current_buf(chat.create())
		local bufnr = vim.api.nvim_create_buf(false, true)
		winid = vim.api.nvim_open_win(bufnr, true, { relative = "editor", row = 4, col = 8, width = 100, height = 20,
			style = "minimal" })
		chat_view.bufnr, chat_view.winid, chat_view.visible = bufnr, winid, true
		chat_view.config = app_state.get_config().chat
		chat_view.float_dims = { row = 4, col = 8, width = 100, height = 20 }
		chat.update_winbar()
	end)

	after_each(function()
		chat.close()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(win).relative ~= "" then pcall(vim.api.nvim_win_close, win, true) end
		end
		app_state.reset()
	end)

	it("reevaluates function colors on background change and inherits TabLine by default", function()
		vim.o.background = "dark"
		chat.update_winbar()
		assert.equals(0x111111, hl("OpenCodeWinbarCurrent").bg)
		assert.equals(0xbbbbbb, hl("OpenCodeWinbarCurrentIdle").fg)
		vim.o.background = "light"
		assert.is_truthy(vim.wait(100, function() return hl("OpenCodeWinbarCurrent").bg == 0xeeeeee end))
		assert.equals(0x444444, hl("OpenCodeWinbarCurrentIdle").fg)
		assert.is_true(color_calls >= 2)

		vim.api.nvim_set_hl(0, "TabLine", { fg = "#123456", bg = "#abcdef", reverse = true })
		vim.api.nvim_set_hl(0, "TabLineSel", { fg = "#fedcba", bg = "#654321", reverse = true })
		chat_view.config.session_tabs.colors = {}
		chat.update_winbar()
		assert.same({ 0x123456, 0xabcdef }, { hl("OpenCodeWinbar").fg, hl("OpenCodeWinbar").bg })
		assert.same({ 0xfedcba, 0x654321 }, { hl("OpenCodeWinbarCurrent").fg, hl("OpenCodeWinbarCurrent").bg })
		assert.equals(0xfedcba, hl("OpenCodeWinbarCurrentIdle").fg)
	end)

	it("reconfigures strip keys in place and returns Visual mode to the chat window", function()
		local tab_buffer = chat_view.session_tabs_bufnr
		assert.equals("", vim.wo[winid].winbar, "float chat window does not use native winbar")
		assert.equals(98, vim.api.nvim_win_get_config(chat_view.session_tabs_winid).width)
		for _, mode in ipairs({ "n", "v", "s" }) do assert.is_true(has_keymap(tab_buffer, mode, "<LeftDrag>")) end
		local original = app_state.get_config()
		app_state.set_config(vim.tbl_deep_extend("force", original, {
			session_tabs = { keymaps = { select = { "<F10>", "<F11>" }, drag = false } },
		}))
		chat.update_winbar()
		assert.equals(tab_buffer, chat_view.session_tabs_bufnr, "configuration reuses the existing tab strip")
		assert.is_true(has_keymap(tab_buffer, "n", "<F10>") and has_keymap(tab_buffer, "n", "<F11>"))
		assert.is_false(has_keymap(tab_buffer, "n", "<LeftMouse>"))
		for _, mode in ipairs({ "n", "v", "s" }) do assert.is_false(has_keymap(tab_buffer, mode, "<LeftDrag>")) end
		app_state.set_config(original)
		chat.update_winbar()
		assert.is_true(has_keymap(tab_buffer, "n", "<LeftMouse>"))
		assert.is_false(has_keymap(tab_buffer, "n", "<F10>"))

		vim.api.nvim_set_current_win(chat_view.session_tabs_winid)
		vim.api.nvim_feedkeys("v", "mx", false)
		assert.equals(winid, vim.api.nvim_get_current_win(), "visual mode key returns focus to chat")
		assert.is_nil(vim.api.nvim_get_mode().mode:find("^[vVsS\22\19]"))
	end)

	it("keeps status summaries and the /btw indicator in a narrow strip", function()
		chat_view.config.session_tabs.max_tabs = "auto"
		app_state.set_session_status("session-2", "busy")
		app_state.set_session_pending_counts("session-4", { questions = 1 })
		chat_view.session_tabs_start, chat_view.session_tabs_current_id = nil, nil
		chat_view.float_dims.width = 46
		chat.update_winbar()
		local line = tab_line()
		assert.is_truthy(line:find("R1", 1, true), "running marker summary")
		assert.is_truthy(line:find("W1", 1, true), "waiting marker summary")

		local btw = require("opencode.btw")
		local original_pending_count = btw.pending_count
		btw.pending_count = function() return 1 end
		local ok, err = pcall(function()
			chat.update_winbar()
			assert.is_truthy(tab_line():find("/btw", 1, true))
			chat_view.config.session_tabs.enabled = false
			chat.update_winbar()
			assert.is_truthy(tab_line():find("/btw", 1, true), "side question stays visible with tabs disabled")
		end)
		btw.pending_count = original_pending_count
		chat_view.config.session_tabs.enabled = true
		assert.is_true(ok, err)
	end)
end)
