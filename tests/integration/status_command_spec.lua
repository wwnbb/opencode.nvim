local app = require("opencode.state")
local actions = require("opencode.actions")
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state").state
local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")
local slash = require("opencode.slash")
local slash_commands = require("opencode.ui.input.slash_commands")
local Popup = require("opencode.ui.popup")

local function input_state()
	for index = 1, 20 do
		local name, value = debug.getupvalue(input.get_winids, index)
		if name == "state" then return value end
	end
	error("Input UI state unavailable")
end

local function input_buffer()
	return vim.api.nvim_win_get_buf(input.get_winids()[1])
end

local function press_input_key(key)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(input_buffer(), "i")) do
		if mapping.lhs:lower() == key:lower() then return mapping.callback() end
	end
	error("Input keymap unavailable: " .. key)
end

local function press_status_key(popup, key)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(popup.bufnr, "n")) do
		if mapping.lhs:lower() == key:lower() then return mapping.callback() end
	end
	error("Status keymap unavailable: " .. key)
end

local function status_windows()
	local windows = {}
	for _, winid in ipairs(vim.api.nvim_list_wins()) do
		if vim.bo[vim.api.nvim_win_get_buf(winid)].filetype == "opencode_status" then
			windows[#windows + 1] = winid
		end
	end
	return windows
end

local function select_status_autocomplete(text)
	local command
	for _, entry in ipairs(slash.get_commands()) do
		if entry.name == "status" then command = entry; break end
	end
	assert.is_not_nil(command)
	assert.equals("action.status", command.id)
	assert.equals(require("opencode.command_registry").get(command.id),
		require("opencode.command_registry").get_slash("status"))
	assert.equals(text, input.get_pending_text())
	local trigger = slash_commands.detect_trigger_in_line(text, #text, 0)
	trigger.row, trigger.line = 0, text
	input_state().autocomplete = {
		visible = true,
		selected = 1,
		trigger = trigger,
		items = { { kind = "slash", label = "/status", command = command } },
	}
	return command
end

describe("/status command selection in chat input", function()
	local original_buffer, old_columns, old_lines, history_file, saved, popup, close_popup
	local fetches, sent, opened

	before_each(function()
		input.close(false)
		app.reset()
		history.clear_pending()
		old_columns, old_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 110, 36
		local config = vim.deepcopy(require("opencode.config").defaults)
		history_file = vim.fn.tempname()
		config.input.history_file = history_file
		app.set_config(config)
		app.set_connection("connected")
		app.set_session("status-test", "Status test")
		app.upsert_session({ id = "status-test", directory = vim.fn.getcwd() })
		chat.setup({ session_tabs = { enabled = true } })
		original_buffer = vim.api.nvim_get_current_buf()
		chat_state.bufnr = vim.api.nvim_create_buf(false, true)
		chat_state.winid = vim.api.nvim_get_current_win()
		chat_state.visible = true
		chat_state.tabpage = vim.api.nvim_get_current_tabpage()
		vim.api.nvim_win_set_buf(chat_state.winid, chat_state.bufnr)
		saved = {
			fetch = actions.get_server_status,
			send = actions.send,
			chat_focus = chat.focus_input,
			popup_new = Popup.new,
		}
		fetches, sent, opened = 0, {}, 0
		popup, close_popup = nil, nil
		actions.get_server_status = function(callback)
			fetches = fetches + 1
			callback(nil, { version = "2.0.11", mcp = {}, plugins = {} })
		end
		actions.send = function(text) sent[#sent + 1] = text end
		Popup.new = function(opts)
			opened = opened + 1
			popup = saved.popup_new(opts)
			close_popup = function() popup:close() end
			return popup
		end
		slash.register_defaults()
		require("opencode.ui.palette").register_defaults()
	end)

	after_each(function()
		if popup then pcall(function() popup:unmount() end) end
		input.close(false)
		actions.get_server_status, actions.send = saved.fetch, saved.send
		chat.focus_input = saved.chat_focus
		Popup.new = saved.popup_new
		if chat_state.winid and vim.api.nvim_win_is_valid(chat_state.winid) then
			vim.api.nvim_win_set_buf(chat_state.winid, original_buffer)
		end
		if chat_state.bufnr and vim.api.nvim_buf_is_valid(chat_state.bufnr) then
			vim.api.nvim_buf_delete(chat_state.bufnr, { force = true })
		end
		chat_state.bufnr, chat_state.winid, chat_state.visible, chat_state.tabpage = nil, nil, false, nil
		history.configure({ history_file = history_file })
		history.clear()
		app.reset()
		vim.o.columns, vim.o.lines = old_columns, old_lines
	end)

	for _, key in ipairs({ "<CR>", "<Tab>", "<C-g>" }) do
		it("opens exactly one status popup from " .. key .. " without submitting the draft", function()
			local attachment = { type = "file", uri = "file:///tmp/status-note.md", name = "status-note.md" }
			history.set_pending("/sta", { attachment })
			assert.is_true(chat.focus_input())
			select_status_autocomplete("/sta")
			assert.equals("", press_input_key(key))
			assert.is_true(vim.wait(1000, function() return close_popup ~= nil end, 10))
			assert.equals(1, fetches)
			assert.equals(1, opened)
			assert.is_nil(popup.frame)
			assert.is_nil(popup.input)
			assert.same({ popup.winid }, status_windows())
			assert.same({}, sent)
			assert.same({}, input.get_history())
			assert.equals("", input.get_pending_text())
			press_status_key(popup, "<Esc>")
			assert.is_true(vim.wait(1000, function()
				return input.is_visible() and vim.api.nvim_get_current_win() == input.get_winids()[1]
			end, 10))
			assert.same({}, status_windows())
			assert.equals("", input.get_pending_text())
			assert.same({ attachment }, input_state().parts)
			assert.same({}, sent)
		end)
	end

	it("opens status when the explicit /status draft is submitted", function()
		local attachment = { type = "file", uri = "file:///tmp/status-direct.md", name = "status-direct.md" }
		history.set_pending("/status", { attachment })
		assert.is_true(chat.focus_input())
		require("opencode.ui.input.autocomplete").close(input_state())
		assert.equals("", press_input_key("<C-g>"))
		assert.is_true(vim.wait(1000, function() return close_popup ~= nil end, 10))
		assert.equals(1, fetches)
		assert.equals(1, opened)
		assert.same({}, sent)
		assert.same({}, input.get_history())
		close_popup()
		assert.is_true(vim.wait(1000, function()
			return input.is_visible() and vim.api.nvim_get_current_win() == input.get_winids()[1]
		end, 10))
		assert.equals("", input.get_pending_text())
		assert.same({ attachment }, input_state().parts)
	end)

	it("does not steal focus after the original session changes while status is open", function()
		history.set_pending("/sta")
		assert.is_true(chat.focus_input())
		select_status_autocomplete("/sta")
		press_input_key("<CR>")
		assert.is_true(vim.wait(1000, function() return close_popup ~= nil end, 10))
		local refocuses = 0
		chat.focus_input = function(...)
			refocuses = refocuses + 1
			return saved.chat_focus(...)
		end
		app.set_session("status-other", "Other")
		close_popup()
		vim.wait(100, function() return false end, 10)
		assert.equals(0, refocuses)
	end)

	it("keeps a long status inside the screen and scrolls to the final plugin", function()
		local plugins = {}
		for index = 1, 88 do
			plugins[index] = { id = string.format("opencode.plugin.%03d", index), state = { status = "active" } }
		end
		actions.get_server_status = function(callback)
			fetches = fetches + 1
			callback(nil, { version = "2.0.12", mcp = {}, plugins = plugins })
		end
		vim.o.columns, vim.o.lines = 50, 18
		history.set_pending("/sta")
		assert.is_true(chat.focus_input())
		select_status_autocomplete("/sta")
		press_input_key("<CR>")
		assert.is_true(vim.wait(1000, function() return close_popup ~= nil end, 10))

		local winid, bufnr = popup.winid, popup.bufnr
		assert.is_nil(popup.frame)
		assert.is_nil(popup.input)
		assert.same({ winid }, status_windows())
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local first_page = table.concat(lines, "\n")
		assert.is_true(first_page:find("opencode.plugin.001", 1, true) ~= nil)
		assert.is_nil(first_page:find("opencode.plugin.088", 1, true))
		assert.equals(vim.api.nvim_win_get_height(winid), #lines)
		assert.is_false(vim.bo[bufnr].modifiable)

		local config = vim.api.nvim_win_get_config(winid)
		assert.is_true(config.row >= 0)
		assert.is_true(config.col >= 0)
		assert.is_true(config.row + config.height <= vim.o.lines - vim.o.cmdheight)
		assert.is_true(config.col + config.width <= vim.o.columns)
		assert.is_true(first_page:find("Status", 1, true) ~= nil)
		assert.is_true(first_page:find("j/k:scroll  q/esc:close", 1, true) ~= nil)
		vim.o.columns, vim.o.lines = 38, 15
		vim.api.nvim_exec_autocmds("VimResized", {})
		config = vim.api.nvim_win_get_config(winid)
		assert.is_true(config.row >= 0)
		assert.is_true(config.col >= 0)
		assert.is_true(config.row + config.height <= vim.o.lines - vim.o.cmdheight)
		assert.is_true(config.col + config.width <= vim.o.columns)
		local resized_page = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		assert.is_true(resized_page:find("j/k:scroll  q/esc:close", 1, true) ~= nil)

		vim.api.nvim_set_current_win(winid)
		press_status_key(popup, "G")
		local last_page = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		assert.is_true(last_page:find("opencode.plugin.088", 1, true) ~= nil)
		assert.is_true(last_page:find("Status", 1, true) ~= nil)
		assert.is_true(last_page:find("j/k:scroll  q/esc:close", 1, true) ~= nil)
		press_status_key(popup, "gg")
		local reset_page = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		assert.is_true(reset_page:find("opencode.plugin.001", 1, true) ~= nil)
		assert.is_nil(reset_page:find("opencode.plugin.088", 1, true))
		close_popup()
		assert.same({}, status_windows())
	end)
end)

describe("/status from a floating chat", function()
	local previous_win, previous_columns, previous_lines, history_file
	local saved_fetch, saved_popup_new
	local status_popup, close_status

	before_each(function()
		previous_win = vim.api.nvim_get_current_win()
		previous_columns, previous_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 110, 40
		input.close(false)
		app.reset()
		local config = vim.deepcopy(require("opencode.config").defaults)
		config.chat.layout = "float"
		config.chat.close_on_focus_lost = true
		history_file = vim.fn.tempname()
		config.input.history_file = history_file
		app.set_config(config)
		app.set_connection("connected")
		app.set_session("status-float", "Status float")
		app.upsert_session({ id = "status-float", directory = vim.fn.getcwd() })
		chat.setup({ layout = "float", close_on_focus_lost = true, session_tabs = { enabled = false } })
		chat.open()
		assert.is_true(chat.is_visible())

		saved_fetch = actions.get_server_status
		saved_popup_new = Popup.new
		status_popup, close_status = nil, nil
		actions.get_server_status = function(callback)
			callback(nil, { version = "2.0.12", mcp = {}, plugins = {} })
		end
		Popup.new = function(opts)
			status_popup = saved_popup_new(opts)
			close_status = function() status_popup:close() end
			return status_popup
		end
		slash.register_defaults()
		require("opencode.ui.palette").register_defaults()
	end)

	after_each(function()
		if status_popup then pcall(function() status_popup:close() end) end
		actions.get_server_status = saved_fetch
		Popup.new = saved_popup_new
		input.close(false)
		chat.close()
		history.configure({ history_file = history_file })
		history.clear()
		app.reset()
		vim.o.columns, vim.o.lines = previous_columns, previous_lines
		if vim.api.nvim_win_is_valid(previous_win) then vim.api.nvim_set_current_win(previous_win) end
	end)

	it("keeps the chat open while Status is visible and after it closes", function()
		local chat_win = chat.get_winid()
		history.set_pending("/sta")
		assert.is_true(chat.focus_input())
		select_status_autocomplete("/sta")
		press_input_key("<CR>")
		assert.is_true(vim.wait(1000, function() return close_status ~= nil end, 10))
		vim.wait(100, function() return not chat.is_visible() end, 10)
		assert.is_true(chat.is_visible())
		assert.is_true(vim.api.nvim_win_is_valid(chat_win))
		assert.is_true(vim.api.nvim_win_is_valid(status_popup.winid))
		assert.is_nil(status_popup.frame)
		assert.is_nil(status_popup.input)
		assert.same({ status_popup.winid }, status_windows())
		close_status()
		assert.same({}, status_windows())
		assert.is_true(vim.wait(1000, function()
			return input.is_visible() and vim.api.nvim_get_current_win() == input.get_winids()[1]
		end, 10))
		assert.is_true(chat.is_visible())
		assert.is_true(vim.api.nvim_win_is_valid(chat_win))
	end)
end)
