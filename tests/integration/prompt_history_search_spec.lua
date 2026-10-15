local function editor(provider)
	local client = require("tests.helpers.embedded_editor").new()
	client.request("nvim_ui_attach", { 100, 32, { rgb = true, ext_linegrid = true } })
	client.lua([[
		local provider = ...
		local app = require('opencode.state')
		app.set_config(require('opencode.config').merge({
			input = { history_file = vim.fn.stdpath('data') .. '/history-search.json', history_search_provider = provider },
			palette = { frecency = false },
		}))
		app.set_session('history-search', 'History search')
		_G.input, _G.history = require('opencode.ui.input'), require('opencode.ui.input.history')
		history.configure(app.get_config().input)
		_G.prompt = 'First line\nMATCH [literal]\nLast line'
		_G.attachment = { type = 'file', uri = 'file:///tmp/history-notes.txt', name = 'history-notes.txt' }
		history.add(prompt, { attachment })
		history.add('A newer unrelated prompt')
		history.set_pending('Draft', { { type = 'agent', name = 'explore' } })
		local chat = require('opencode.ui.chat')
		chat.setup()
		local chat_state = require('opencode.ui.chat.state').state
		chat_state.bufnr, chat_state.winid, chat_state.visible = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), true
		local actions = require('opencode.actions')
		_G.sent, _G.processes, _G.notices = {}, {}, {}
		actions.send = function(...) sent[#sent + 1] = { ... } end
		actions.focus_input = function() return chat.focus_input() end
		vim.notify = function(message) notices[#notices + 1] = message end
		local system = vim.system
		vim.system = function(argv, opts, callback)
			processes[#processes + 1] = argv
			return system(argv, opts, callback)
		end
		local menu = require('opencode.ui.menu')
		local open = menu.open
		menu.open = function(opts)
			_G.picker = open(opts)
			_G.picker_buf = picker.popup.bufnr
			return picker
		end
		_G.palette = require('opencode.ui.palette')
		palette.setup()
		chat.focus_input()
	]], { provider })
	function client.wait(expression)
		assert.is_true(vim.wait(2000, function() return client.lua("return " .. expression) end, 5), expression
			.. "\n" .. vim.inspect(client.lua([[return { mode = vim.api.nvim_get_mode().mode,
				lines = vim.api.nvim_buf_get_lines(0, 0, -1, false), draft = input.get_pending_text(), notices = notices }]])))
	end
	function client.open_history()
		client.wait("input.is_visible() and vim.api.nvim_get_mode().mode == 'i'")
		client.feed(" kept")
		client.wait("input.get_pending_text() == 'Draft kept'")
		client.lua("require('opencode.ui.chat').focus()")
		client.wait("not input.is_visible()")
		client.lua("palette.show()")
		client.wait("palette.is_visible() and vim.api.nvim_get_mode().mode == 'i'")
		client.feed("Search Prompt History")
		client.wait("vim.api.nvim_get_current_line() == 'Search Prompt History'")
		client.feed("<CR>")
		client.wait("picker ~= nil and vim.api.nvim_get_mode().mode == 'i'")
	end
	return client
end

describe("prompt history search with real editor input", function()
	local client
	after_each(function() if client then client.close(); client = nil end end)

	for _, provider in ipairs({ "grep", "ripgrep" }) do
		it("searches with " .. provider .. " and restores the full prompt into the composer without sending", function()
			client = editor(provider)
			assert.equals("Search Prompt History", client.lua("return require('opencode.command_registry').get('prompt.history').title"))
			client.open_history()
			client.feed("match [literal]")
			client.wait("#processes > 0 and picker.current() ~= nil and picker.current().entry.text == prompt")
			assert.equals(provider == "ripgrep" and "rg" or "grep", client.lua("return processes[#processes][1]"))
			assert.equals("match [literal]", client.lua("return processes[#processes][#processes[#processes] - 2]"))
			client.feed("<CR>")
			client.wait("input.is_visible() and vim.api.nvim_get_current_win() == input.get_winids()[1] and vim.api.nvim_get_mode().mode == 'i'")
			assert.equals("Draft kept\n\nFirst line\nMATCH [literal]\nLast line", client.lua("return input.get_pending_text()"))
			assert.same({ { type = "agent", name = "explore" },
				{ type = "file", uri = "file:///tmp/history-notes.txt", name = "history-notes.txt" } },
				client.lua("return input.get_pending_parts()"))
			assert.same({}, client.lua("return sent"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("keeps the unsent draft and attachments when search is cancelled", function()
		client = editor("grep")
		client.open_history()
		client.feed("missing text")
		client.wait("#processes > 0 and picker.current() == nil")
		client.feed("<Esc>")
		client.wait("vim.api.nvim_get_mode().mode == 'n'")
		client.feed("<Esc>")
		client.wait("not vim.api.nvim_buf_is_valid(picker_buf)")
		assert.equals("Draft kept", client.lua("return input.get_pending_text()"))
		assert.same({ { type = "agent", name = "explore" } }, client.lua("return input.get_pending_parts()"))
		assert.same({}, client.lua("return sent"))
	end)
end)
