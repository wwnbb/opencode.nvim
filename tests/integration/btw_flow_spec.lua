local app = require("opencode.state")
local actions = require("opencode.actions")
local btw = require("opencode.btw")
local client = require("opencode.client")
local chat = require("opencode.ui.chat")
local chat_state = require("opencode.ui.chat.state").state
local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")
local slash = require("opencode.slash")
local sync = require("opencode.sync")
local slash_commands = require("opencode.ui.input.slash_commands")

local function input_state()
	for index = 1, 20 do
		local name, value = debug.getupvalue(input.get_winids, index)
		if name == "state" then return value end
	end
	error("Input UI state unavailable")
end

describe("/btw composer flow", function()
	local previous_buffer, previous_config, saved, reply, sent, history_file

	before_each(function()
		previous_buffer = vim.api.nvim_get_current_buf()
		previous_config = { columns = vim.o.columns, lines = vim.o.lines }
		vim.o.columns, vim.o.lines = 110, 36
		local config = vim.deepcopy(require("opencode.config").defaults)
		history_file = vim.fn.tempname()
		config.input.history_file = history_file
		app.reset()
		app.set_config(config)
		app.set_connection("connected")
		app.set_session("btw-flow", "Side questions")
		app.upsert_session({ id = "btw-flow", directory = vim.fn.getcwd() })
		sync.clear_all()
		history.clear_pending()
		chat.setup({ session_tabs = { enabled = true } })
		chat_state.bufnr = vim.api.nvim_create_buf(false, true)
		chat_state.winid = vim.api.nvim_get_current_win()
		chat_state.visible = true
		chat_state.tabpage = vim.api.nvim_get_current_tabpage()
		vim.api.nvim_win_set_buf(chat_state.winid, chat_state.bufnr)
		slash.register_defaults()
		saved = { ask = actions.ask_btw, send = actions.send, generate = client.generate_text }
		sent, reply = {}, nil
		actions.ask_btw = function(question, session_id) return btw.ask(session_id or app.get_session().id, question) end
		actions.send = function(text) sent[#sent + 1] = text end
		client.generate_text = function(session_id, prompt, callback)
			reply = { session_id = session_id, prompt = prompt, callback = callback }
		end
	end)

	after_each(function()
		btw.reset()
		require("opencode.ui.btw").close()
		input.close(false)
		client.generate_text = saved.generate
		actions.ask_btw, actions.send = saved.ask, saved.send
		if chat_state.winid and vim.api.nvim_win_is_valid(chat_state.winid) then
			vim.api.nvim_win_set_buf(chat_state.winid, previous_buffer)
		end
		if chat_state.bufnr and vim.api.nvim_buf_is_valid(chat_state.bufnr) then
			vim.api.nvim_buf_delete(chat_state.bufnr, { force = true })
		end
		chat_state.bufnr, chat_state.winid, chat_state.visible, chat_state.tabpage = nil, nil, false, nil
		history.configure({ history_file = history_file })
		history.clear()
		sync.clear_all()
		app.reset()
		vim.o.columns, vim.o.lines = previous_config.columns, previous_config.lines
	end)

	it("sends /btw <question> with Enter, hides input, and displays the transient answer", function()
		assert.is_true(chat.focus_input())
		local input_win = vim.api.nvim_get_current_win()
		local input_buf = vim.api.nvim_win_get_buf(input_win)
		assert.equals("opencode_input", vim.bo[input_buf].filetype)
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "/btw how is your day" })
		local enter = vim.fn.maparg("<CR>", "i", false, true)
		assert.is_function(enter.callback)
		assert.equals("", enter.callback())
		assert.is_true(vim.wait(1000, function() return reply ~= nil end, 10))
		assert.equals("btw-flow", reply.session_id)
		assert.is_false(input.is_visible())
		assert.equals(1, btw.pending_count())
		assert.is_truthy(vim.wo[chat_state.winid].winbar:find("/btw", 1, true))
		assert.same({}, sent)
		assert.same({}, sync.get_messages("btw-flow"))
		reply.callback(nil, "Day good. Sun up, tokens flow.")
		assert.equals(0, btw.pending_count())
		assert.is_true(require("opencode.ui.btw").is_visible())
		assert.same({}, sync.get_messages("btw-flow"))
	end)

	it("opens the question dialog for bare /btw and submits its prompt", function()
		assert.is_true(chat.focus_input())
		local input_buf = vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(input_buf, 0, -1, false, { "/btw" })
		local enter = vim.fn.maparg("<CR>", "i", false, true)
		assert.equals("", enter.callback())
		assert.is_true(vim.wait(1000, function()
			return require("opencode.ui.btw").is_visible()
		end, 10))
		assert.is_false(input.is_visible())
		local question_buf = vim.api.nvim_get_current_buf()
		assert.equals("opencode_btw_input", vim.bo[question_buf].filetype)
		app.set_session("btw-other", "Other session")
		vim.api.nvim_buf_set_lines(question_buf, 0, -1, false, { "What changed?" })
		vim.fn.maparg("<CR>", "i", false, true).callback()
		assert.is_true(vim.wait(1000, function() return reply ~= nil end, 10))
		assert.equals("btw-flow", reply.session_id)
		assert.is_truthy(reply.prompt:find("What changed?", 1, true))
		assert.same({}, sent)
		assert.same({}, sync.get_messages("btw-flow"))
	end)

	it("opens the question dialog immediately when /btw is selected from completion", function()
		history.set_pending("/bt")
		assert.is_true(chat.focus_input())
		local command
		for _, entry in ipairs(slash.get_commands()) do
			if entry.name == "btw" then command = entry; break end
		end
		assert.is_not_nil(command)
		local trigger = slash_commands.detect_trigger_in_line("/bt", #"/bt", 0)
		trigger.row, trigger.line = 0, "/bt"
		input_state().autocomplete = {
			visible = true,
			selected = 1,
			trigger = trigger,
			items = { { kind = "slash", label = "/btw", command = command } },
		}
		local enter = vim.fn.maparg("<CR>", "i", false, true)
		assert.is_function(enter.callback)
		assert.equals("", enter.callback())
		assert.is_true(vim.wait(1000, function() return require("opencode.ui.btw").is_visible() end, 10))
		assert.is_false(input.is_visible())
		assert.same({}, sent)
		assert.same({}, input.get_history())
		assert.equals("", input.get_pending_text())
		assert.equals("opencode_btw_input", vim.bo[vim.api.nvim_get_current_buf()].filetype)
	end)
end)

describe("/btw floating chat focus", function()
	local previous_win, previous_columns, previous_lines
	local ui_btw = require("opencode.ui.btw")

	before_each(function()
		previous_win = vim.api.nvim_get_current_win()
		previous_columns, previous_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 110, 40
		local config = vim.deepcopy(require("opencode.config").defaults)
		config.chat.layout = "float"
		config.chat.close_on_focus_lost = true
		config.input.history_file = vim.fn.tempname()
		app.reset()
		app.set_config(config)
		app.set_session("btw-focus", "Focus")
		app.upsert_session({ id = "btw-focus", directory = vim.fn.getcwd() })
		chat.setup({ layout = "float", close_on_focus_lost = true, session_tabs = { enabled = false } })
		chat.open()
		assert.is_true(chat.is_visible())
	end)

	after_each(function()
		ui_btw.close()
		input.close(false)
		chat.close()
		app.reset()
		vim.o.columns, vim.o.lines = previous_columns, previous_lines
		if vim.api.nvim_win_is_valid(previous_win) then vim.api.nvim_set_current_win(previous_win) end
	end)

	local function assert_chat_survives_escape(open_dialog)
		assert.is_true(chat.focus_input())
		local composer_win = vim.api.nvim_get_current_win()
		local view = open_dialog()
		assert.equals(composer_win, view.previous_win)
		assert.is_true(vim.wait(1000, function() return not input.is_visible() end, 10))
		assert.is_false(vim.api.nvim_win_is_valid(composer_win))
		assert.is_true(chat.is_visible())
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)
		assert.is_true(vim.wait(1000, function() return not ui_btw.is_visible() end, 10))
		vim.wait(50)
		assert.is_true(chat.is_visible())
		assert.equals(chat.get_winid(), vim.api.nvim_get_current_win())
	end

	it("keeps floating chat open after closing the question prompt", function()
		assert_chat_survives_escape(function() return ui_btw.prompt() end)
	end)

	it("keeps floating chat open after closing the answer dialog", function()
		assert_chat_survives_escape(function() return ui_btw.show("Question", "Answer") end)
	end)
end)
