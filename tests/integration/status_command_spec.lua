local app = require("opencode.state")
local actions = require("opencode.actions")
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state").state
local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")
local slash = require("opencode.slash")
local slash_commands = require("opencode.ui.input.slash_commands")
local float = require("opencode.ui.float")

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
			create_popup = float.create_centered_popup,
			close_keymaps = float.setup_close_keymaps,
		}
		fetches, sent, opened = 0, {}, 0
		popup, close_popup = nil, nil
		actions.get_server_status = function(callback)
			fetches = fetches + 1
			callback(nil, { version = "2.0.11", mcp = {}, plugins = {} })
		end
		actions.send = function(text) sent[#sent + 1] = text end
		float.create_centered_popup = function(opts)
			opened = opened + 1
			popup = saved.create_popup(opts)
			return popup, popup.bufnr
		end
		float.setup_close_keymaps = function(bufnr, callback)
			close_popup = callback
			return saved.close_keymaps(bufnr, callback)
		end
		slash.register_defaults()
		require("opencode.ui.palette").register_defaults()
	end)

	after_each(function()
		if popup then pcall(function() popup:unmount() end) end
		input.close(false)
		actions.get_server_status, actions.send = saved.fetch, saved.send
		chat.focus_input = saved.chat_focus
		float.create_centered_popup, float.setup_close_keymaps = saved.create_popup, saved.close_keymaps
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
			assert.same({}, sent)
			assert.same({}, input.get_history())
			assert.equals("", input.get_pending_text())
			close_popup()
			assert.is_true(vim.wait(1000, function()
				return input.is_visible() and vim.api.nvim_get_current_win() == input.get_winids()[1]
			end, 10))
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
end)
