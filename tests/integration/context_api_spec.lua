local function editor()
	local client = require("tests.helpers.embedded_editor").new()
	function client.wait(expression)
		assert.is_true(vim.wait(3000, function() return client.lua("return " .. expression) end, 10), expression)
	end
	client.request("nvim_ui_attach", { 100, 32, { rgb = true, ext_linegrid = true } })
	client.lua([[
		_G.notices, _G.connections, _G.sent = {}, {}, {}
		_G.saved = { notify = vim.notify }
		vim.notify = function(message) notices[#notices + 1] = message end
		require('opencode.state').set_connection('connected')
		require('opencode').setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { close_on_focus_lost = false } })
		local lifecycle, sender, chat = require('opencode.lifecycle'), require('opencode.send'), require('opencode.ui.chat')
		saved.connect, saved.send, saved.focus = lifecycle.ensure_connected, sender.send, chat.focus_input
		lifecycle.ensure_connected = function(callback) connections[#connections + 1] = callback end
		sender.send = function(text, opts) sent[#sent + 1] = { text = text, options = opts } end
		chat.focus_input = function(snapshot, context_error)
			_G.focus_snapshot = snapshot
			return saved.focus(snapshot, context_error)
		end
		_G.source = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(source, '/tmp/opencode-context-api.lua')
		vim.api.nvim_set_current_buf(source)
		vim.bo[source].filetype = 'lua'
		vim.api.nvim_buf_set_lines(source, 0, -1, false,
			{ 'local first = 1', 'local second = 2', 'return first + second' })
		_G.expand_sent = function(index, token)
			local request = sent[index]
			return assert(require('opencode.context').expand(token or request.text,
				request.options, request.options._context_snapshot)).text
		end
	]])
	return client
end

describe("context snapshots through the public API", function()
	local client
	before_each(function() client = editor() end)
	after_each(function()
		if client then
			client.lua([[
				require('opencode.lifecycle').ensure_connected = saved.connect
				require('opencode.send').send = saved.send
				require('opencode.ui.chat').focus_input = saved.focus
				vim.notify = saved.notify
			]])
			client.close()
		end
	end)

	it("captures before connecting and keeps source text after the buffer is deleted", function()
		client.lua([[
			_G.options = { context = { { type = 'text', text = 'manual context' } } }
			require('opencode').send('Explain @buffer', options)
			assert(#connections == 1 and #sent == 0)
			vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'changed after send()' })
			local utility = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_set_current_buf(utility)
			vim.bo[utility].filetype = 'opencode'
			vim.api.nvim_buf_set_lines(utility, 0, -1, false, { 'chat content must not become context' })
			vim.api.nvim_buf_delete(source, { force = true })
			connections[1]()
		]])
		local text = client.lua("return expand_sent(1)")
		assert.is_truthy(text:find("local first = 1", 1, true))
		assert.is_truthy(text:find("return first + second", 1, true))
		assert.is_nil(text:find("changed after send()", 1, true))
		assert.is_nil(text:find("chat content", 1, true))
		assert.same({ context = { { type = "text", text = "manual context" } } }, client.lua("return options"))
	end)

	it("uses the last ordinary source when called from a plugin buffer", function()
		client.lua([[
			local utility = vim.api.nvim_create_buf(false, true)
			vim.bo[utility].filetype = 'opencode'
			vim.api.nvim_set_current_buf(utility)
			vim.api.nvim_buf_set_lines(utility, 0, -1, false, { 'chat content must not become context' })
			require('opencode').send('@buffer')
			connections[1]()
		]])
		local text = client.lua("return expand_sent(1)")
		assert.is_truthy(text:find("local first = 1", 1, true))
		assert.is_nil(text:find("chat content", 1, true))
	end)

	it("gives an explicit inclusive range priority over the active Visual selection", function()
		client.feed("ggVj")
		client.wait("vim.api.nvim_get_mode().mode == 'V' and vim.api.nvim_win_get_cursor(0)[1] == 2")
		client.lua([[
			_G.options = { range = { 3, 3 } }
			require('opencode').send('@this', options)
			connections[1]()
		]])
		local text = client.lua("return expand_sent(1)")
		assert.is_truthy(text:find("return first + second", 1, true))
		assert.is_nil(text:find("local first = 1", 1, true))
		assert.is_nil(text:find("local second = 2", 1, true))
		assert.same({ range = { 3, 3 } }, client.lua("return options"))
	end)

	it("records invalid ranges at the call before a deferred connection changes the source", function()
		for _, range in ipairs({ { 0, 1 }, { 2, 1 }, { 1, 4 }, { 1.5, 2 }, { 1 }, { "1", 2 } }) do
			local result = client.lua([[
				require('opencode').send('@this', { range = ... })
				vim.api.nvim_buf_set_lines(source, 3, 3, false, { 'new fourth line' })
				connections[#connections]()
				vim.api.nvim_buf_set_lines(source, 3, 4, false, {})
				local opts = sent[#sent].options
				return { error = opts._context_error, has_snapshot = opts._context_snapshot ~= nil }
			]], { range })
			assert.is_string(result.error)
			assert.is_false(result.has_snapshot)
		end
	end)

	it("captures a deferred edit's retained range before connection and composer focus", function()
		client.lua([[
			local state, history = require('opencode.state'), require('opencode.ui.input.history')
			state.set_session('deferred_context', 'Deferred context')
			local config = vim.deepcopy(state.get_config()); config.context.max_bytes = 1024; state.set_config(config)
			local lines = {}
			for row = 1, 100 do lines[row] = string.format('unselected line %03d ', row) .. string.rep('x', 60) end
			lines[100] = 'range captured before connecting'
			vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
			history.defer_pending({ text = '@this', parts = {}, options = { range = { 100, 100 } } }, 'deferred_context')
			require('opencode').focus_input()
			assert(#connections == 1 and not require('opencode.ui.input').is_visible())
			vim.api.nvim_buf_set_lines(source, 0, -1, false, { 'changed after requesting focus' })
			connections[1]()
		]])
		client.wait("require('opencode.ui.input').is_visible()")
		client.lua([[
			assert(require('opencode.ui.input').get_pending_text() == '@this')
			vim.fn.maparg('<C-g>', 'n', false, true).callback()
			assert(#connections == 2 and #sent == 0)
			connections[2]()
		]])
		local text = client.lua("return expand_sent(1)")
		assert.is_truthy(text:find("range captured before connecting", 1, true))
		assert.is_nil(text:find("unselected line", 1, true))
		assert.is_nil(text:find("changed after requesting focus", 1, true))
		assert.same({ 100, 100 }, client.lua("return sent[1].options.range"))
	end)

	it("forwards a deferred edit's range error through connection and composer focus", function()
		client.lua([[
			local history = require('opencode.ui.input.history')
			require('opencode.state').set_session('invalid_context', 'Invalid context')
			history.defer_pending({ text = '@this', parts = {}, options = { range = { 2, 4 } } }, 'invalid_context')
			require('opencode').focus_input()
			vim.api.nvim_buf_set_lines(source, 3, 3, false, { 'new fourth line' })
			connections[1]()
		]])
		client.wait("require('opencode.ui.input').is_visible()")
		local result = client.lua([[
			vim.fn.maparg('<C-g>', 'n', false, true).callback()
			connections[2]()
			return { text = sent[1].text, error = sent[1].options._context_error,
				has_snapshot = sent[1].options._context_snapshot ~= nil }
		]])
		assert.equals("@this", result.text)
		assert.is_string(result.error)
		assert.is_false(result.has_snapshot)
	end)

	it("captures Visual text and the viewport before deferred connection and real composer focus", function()
		client.lua([[
			local lines = { 'alpha beta gamma' }
			for row = 2, 100 do lines[row] = string.format('source line %03d', row) end
			vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
		]])
		client.feed("gg0v4l")
		client.wait("vim.api.nvim_get_mode().mode == 'v' and vim.api.nvim_win_get_cursor(0)[2] == 4")
		local original_bottom = client.lua([[
			local bottom = vim.fn.line('w$')
			require('opencode').focus_input()
			assert(#connections == 1 and not require('opencode.ui.input').is_visible())
			return string.format('source line %03d', bottom)
		]])
		client.feed("<Esc>")
		client.wait("vim.api.nvim_get_mode().mode == 'n'")
		client.lua([[
			local lines = {}
			for row = 1, 100 do lines[row] = string.format('late source %03d', row) end
			vim.api.nvim_buf_set_lines(source, 0, -1, false, lines)
			vim.api.nvim_win_set_cursor(0, { 100, 0 })
			connections[1]()
		]])
		client.wait("require('opencode.ui.input').is_visible()")
		local result = client.lua([[
			local context = require('opencode.context')
			return { selection = assert(context.expand('@this', {}, focus_snapshot)).text,
				visible = assert(context.expand('@visible', {}, focus_snapshot)).text,
				focused_source = vim.api.nvim_get_current_buf() == source }
		]])
		assert.is_truthy(result.selection:find("alpha", 1, true))
		assert.is_nil(result.selection:find("beta", 1, true))
		assert.is_truthy(result.visible:find(original_bottom, 1, true))
		assert.is_nil(result.visible:find("late source", 1, true))
		assert.is_false(result.focused_source)
	end)
end)
