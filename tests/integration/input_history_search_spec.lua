local function editor(options, surface)
	surface = surface or {}
	local client = require("tests.helpers.embedded_editor").new()
	client.request("nvim_ui_attach", { surface.width or 100, surface.height or 32, { rgb = true, ext_linegrid = true } })
	client.lua([[
		local options, surface = ...
		_G.app, _G.input, _G.history = require('opencode.state'), require('opencode.ui.input'), require('opencode.ui.input.history')
		options.history_file = vim.fn.stdpath('data') .. '/input-history-search.json'
		app.set_config(require('opencode.config').merge({ input = options,
			chat = { layout = surface.layout or 'vertical', close_on_focus_lost = false },
		}))
		app.set_session('history-search', 'History search')
		history.configure(app.get_config().input)
		_G.prompt = 'First line\nMATCH [literal]\nLast line'
		_G.original = 'Draft\nkeep this unchanged'
		_G.attachment = { type = 'file', uri = 'file:///tmp/history-notes.txt', name = 'history-notes.txt' }
		history.add(prompt, { attachment })
		history.add('A newer unrelated prompt')
		for index = 1, surface.entries or 0 do history.add('Extra history prompt ' .. index) end
		history.set_pending('Draft\nkeep this', { { type = 'agent', name = 'explore' } })
		if surface.draft then history.set_pending(surface.draft) end
		local chat = require('opencode.ui.chat')
		chat.setup()
		_G.editor_buf = vim.api.nvim_get_current_buf()
		local chat_state = require('opencode.ui.chat.state').state
		if surface.layout then chat.open()
		else chat_state.bufnr, chat_state.winid, chat_state.visible = editor_buf, vim.api.nvim_get_current_win(), true end
		_G.sent, _G.processes, _G.notices, _G.menu_calls = {}, {}, {}, 0
		local actions = require('opencode.actions')
		actions.send = function(...) sent[#sent + 1] = { ... } end
		actions.focus_input = function() return chat.focus_input() end
		vim.notify = function(message) notices[#notices + 1] = message end
		local system = vim.system
		vim.system = function(argv, opts, callback)
			local process = { argv = argv }
			processes[#processes + 1] = process
			return system(argv, opts, function(result) process.done = true; callback(result) end)
		end
		local menu = require('opencode.ui.menu')
		local open = menu.open
		menu.open = function(opts) menu_calls = menu_calls + 1; return open(opts) end
		_G.completion_text = function()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				local buf = vim.api.nvim_win_get_buf(win)
				if vim.bo[buf].filetype == 'opencode_input_autocomplete' then
					return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
				end
			end
		end
		chat.focus_input()
		_G.composer_buf = vim.api.nvim_win_get_buf(input.get_winids()[1])
		_G.composer_text = function() return table.concat(vim.api.nvim_buf_get_lines(composer_buf, 0, -1, false), '\n') end
	]], { options or {}, surface })
	function client.wait(expression)
		local deadline, matched = vim.uv.hrtime() + 2000000000, false
		repeat
			matched = client.lua("return not not (" .. expression .. ")")
			if matched then break end
			vim.wait(5)
		until vim.uv.hrtime() >= deadline
		assert.is_true(matched, expression
			.. "\n" .. vim.inspect(client.lua([[return { mode = vim.api.nvim_get_mode().mode,
				lines = vim.api.nvim_buf_get_lines(0, 0, -1, false), completion = completion_text(), notices = notices }]])))
	end
	function client.search(key)
		client.wait("input.is_visible() and vim.api.nvim_get_mode().mode == 'i'")
		client.feed(" unchanged")
		client.wait("composer_text() == original")
		client.feed(key or "<C-r>")
		client.wait("completion_text() ~= nil and composer_text() == ''")
		assert.equals(0, client.lua("return menu_calls"))
		assert.equals(client.lua("return composer_buf"), client.lua("return vim.api.nvim_get_current_buf()"))
	end
	return client
end

describe("prompt history search inside the input composer", function()
	local client
	after_each(function() if client then client.close(); client = nil end end)

	for _, case in ipairs({
		{ provider = "grep", confirm = "<CR>" },
		{ provider = "ripgrep", confirm = "<C-g>" },
		{ provider = "grep", key = "<F6>", confirm = "<Tab>" },
	}) do
		it("selects with " .. case.confirm .. " using " .. case.provider .. " and an input-only " .. (case.key or "<C-r>") .. " shortcut", function()
			client = editor({ history_search_provider = case.provider, keymaps = case.key and { history_search = case.key } or nil })
			assert.equals(1, client.lua("return vim.fn.maparg(..., 'i', false, true).buffer", { case.key or "<C-r>" }))
			assert.same({}, client.lua("return vim.api.nvim_buf_get_keymap(editor_buf, 'i')"))
			if case.key then assert.equals("", client.lua("return vim.fn.maparg('<C-r>', 'i')")) end
			client.search(case.key)
			client.feed("match [literal]")
			client.wait("#processes > 0 and processes[#processes].done and completion_text() ~= nil and completion_text():find('MATCH [literal]', 1, true) ~= nil")
			assert.equals(case.provider == "ripgrep" and "rg" or "grep", client.lua("return processes[#processes].argv[1]"))
			client.feed(case.confirm)
			client.wait("completion_text() == nil and composer_text() == original .. '\\n\\n' .. prompt")
			assert.equals("i", client.lua("return vim.api.nvim_get_mode().mode"))
			assert.equals(client.lua("return composer_buf"), client.lua("return vim.api.nvim_get_current_buf()"))
			assert.same({ { type = "agent", name = "explore" },
				{ type = "file", uri = "file:///tmp/history-notes.txt", name = "history-notes.txt" } }, client.lua("return input.get_pending_parts()"))
			assert.same({}, client.lua("return sent"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("restores the exact original draft and attachments on Escape", function()
		client = editor()
		client.search()
		client.feed("match")
		client.wait("#processes > 0 and processes[#processes].done")
		client.feed("<Esc>")
		client.wait("completion_text() == nil and composer_text() == original")
		assert.same({ { type = "agent", name = "explore" } }, client.lua("return input.get_pending_parts()"))
		assert.same({}, client.lua("return sent"))
	end)

	it("previews the highlighted prompt as virtual text until it is selected", function()
		client = editor()
		client.search()
		client.lua([[
			_G.preview = function()
				local ns = vim.api.nvim_get_namespaces().opencode_input_history_preview
				local marks = vim.api.nvim_buf_get_extmarks(composer_buf, ns, 0, -1, { details = true })
				if #marks == 0 then return nil end
				return marks[1][4].virt_text[1][1]
			end
		]])
		client.wait("preview() == 'A newer unrelated prompt'")
		assert.equals("", client.lua("return composer_text()"))
		client.feed("<Down>")
		client.wait("preview() == 'First line MATCH [literal] Last line'")
		assert.equals("", client.lua("return composer_text()"))
		client.feed("<Up>")
		client.wait("preview() == 'A newer unrelated prompt'")
		client.feed("match")
		client.wait("preview() ~= nil and preview():find('MATCH [literal]', 1, true) ~= nil")
		assert.equals("match", client.lua("return composer_text()"))
		client.feed("<CR>")
		client.wait("preview() == nil and composer_text() == original .. '\\n\\n' .. prompt")
		assert.same({}, client.lua("return sent"))
	end)

	it("does not send when the send key confirms a search with no matches", function()
		client = editor()
		client.search()
		client.feed("missing query")
		client.wait("#processes > 0 and processes[#processes].done")
		client.feed("<C-g>")
		client.wait("input.is_visible() and vim.api.nvim_get_mode().mode == 'i'")
		assert.same({}, client.lua("return sent"))
		client.feed("<Esc>")
		client.wait("completion_text() == nil and composer_text() == original")
	end)

	it("saves the original draft when leaving the composer during search", function()
		client = editor()
		client.search()
		client.feed("match")
		client.lua("require('opencode.ui.chat').focus()")
		client.wait("not input.is_visible() and completion_text() == nil")
		assert.equals("Draft\nkeep this unchanged", client.lua("return history.get_pending('history-search')"))
		assert.same({ { type = "agent", name = "explore" } }, client.lua("return history.get_pending_parts('history-search')"))
		assert.same({}, client.lua("return sent"))
	end)

	it("preserves each session's draft when the active session changes during search", function()
		client = editor()
		client.search()
		client.feed("match")
		client.lua("history.set_pending('Other draft', {}, 'other'); app.set_session('other', 'Other')")
		client.wait("completion_text() == nil and input.get_pending_text() == 'Other draft'")
		assert.equals("Draft\nkeep this unchanged", client.lua("return history.get_pending('history-search')"))
		assert.same({ { type = "agent", name = "explore" } }, client.lua("return history.get_pending_parts('history-search')"))
		assert.same({}, client.lua("return input.get_pending_parts()"))
		assert.same({}, client.lua("return sent"))
	end)

	for _, layout in ipairs({ "vertical", "float" }) do
		it("keeps " .. layout .. " history results above the input while filtering and resizing", function()
			client = editor({}, { width = 80, height = 24, layout = layout, entries = 15, draft = "one\ntwo\nthree\nfour\nfive" })
			client.lua([[
				_G.geometry = function()
					local function rect(win)
						local pos = vim.api.nvim_win_get_position(win)
						return { row = pos[1], col = pos[2], height = vim.api.nvim_win_get_height(win), width = vim.api.nvim_win_get_width(win) }
					end
					local input_win, info_win = unpack(input.get_winids())
					local rows = { input = rect(input_win), info = rect(info_win), parent = rect(require('opencode.ui.chat').get_winid()),
						frame = rect(vim.api.nvim_win_get_config(input_win).win) }
					for _, win in ipairs(vim.api.nvim_list_wins()) do
						if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'opencode_input_autocomplete' then
							rows.results = rect(vim.api.nvim_win_get_config(win).win)
						end
					end
					return rows
				end
			]])
			client.wait("vim.api.nvim_get_mode().mode == 'i'")
			local before = client.lua("return geometry()")
			client.feed("<C-r>")
			client.wait("completion_text() ~= nil")
			local opened = client.lua("return geometry()")
			assert.same(before.input, opened.input)
			assert.same(before.info, opened.info)
			assert.same(before.parent, opened.parent)
			assert.equals(10, opened.results.height)
			assert.is_true(opened.results.row + opened.results.height <= opened.frame.row, vim.inspect(opened))
			client.feed("match")
			client.wait("#processes > 0 and processes[#processes].done and completion_text():find('MATCH', 1, true) ~= nil")
			local filtered = client.lua("return geometry()")
			assert.same(opened.input, filtered.input)
			assert.equals(1, filtered.results.height)
			assert.is_true(filtered.results.row + filtered.results.height <= filtered.frame.row, vim.inspect(filtered))
			client.feed("<C-u>")
			client.wait("composer_text() == '' and geometry().results.height == 10")
			local expanded = client.lua("return geometry()")
			assert.same(opened.input, expanded.input)
			assert.same(opened.results, expanded.results)
			client.request("nvim_ui_try_resize", { 80, 18 })
			client.lua("vim.api.nvim_exec_autocmds('VimResized', {})")
			client.wait("geometry().input.row < " .. filtered.input.row)
			client.wait("geometry().results.row + geometry().results.height <= geometry().frame.row")
			assert.equals("", client.lua("return composer_text()"))
			assert.equals(client.lua("return composer_buf"), client.lua("return vim.api.nvim_get_current_buf()"))
		end)
	end
end)
