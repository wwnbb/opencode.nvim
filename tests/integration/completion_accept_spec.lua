-- Real Insert-mode input through the full public API/controller/UI. Only the
-- connection and generation request are stubbed; buffer edits and undo are real.
local function editor(completion_options)
	local stdin, stdout, stderr = vim.uv.new_pipe(false), vim.uv.new_pipe(false), vim.uv.new_pipe(false)
	local unpacker, responses, errors = vim.mpack.Unpacker(), {}, {}
	local sequence, exited, process = 0, false, nil
	process = assert(vim.uv.spawn(vim.v.progpath, {
		args = { "--embed", "--headless", "--noplugin", "-u", vim.fn.getcwd() .. "/tests/minimal_init.lua", "-i", "NONE", "-n" },
		stdio = { stdin, stdout, stderr },
	}, function()
		exited = true
		if process and not process:is_closing() then process:close() end
	end))
	stdout:read_start(function(err, data)
		if err then errors[#errors + 1] = err end
		if not data then return end
		local offset = 1
		while offset <= #data do
			local message
			message, offset = unpacker(data, offset)
			if message and message[1] == 1 then responses[message[2]] = message end
		end
	end)
	stderr:read_start(function(err, data) if err or data then errors[#errors + 1] = err or data end end)
	local client = {}
	function client.request(method, args)
		sequence = sequence + 1
		local id = sequence
		stdin:write(vim.mpack.encode({ 0, id, method, args }))
		assert(vim.wait(3000, function() return responses[id] ~= nil or exited end, 5), "RPC timeout")
		local response = assert(responses[id], table.concat(errors, "\n"))
		assert(response[3] == vim.NIL, vim.inspect(response[3]))
		return response[4]
	end
	function client.lua(code, args) return client.request("nvim_exec_lua", { code, args or {} }) end
	function client.feed(keys)
		client.lua("vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(..., true, false, true), 'mt', false)", { keys })
	end
	function client.wait(expression)
		assert.is_true(vim.wait(2000, function() return client.lua("return " .. expression) end, 10), expression
			.. "\n" .. vim.inspect(client.lua([[return { mode = vim.api.nvim_get_mode().mode,
				lines = vim.api.nvim_buf_get_lines(0, 0, -1, false), cursor = vim.api.nvim_win_get_cursor(0),
				requests = #requests, notices = notices, visible = require('opencode').completion_visible() }]])))
	end
	function client.respond(index, text) client.lua("local index, text = ...; requests[index].callback(nil, text)", { index, text }) end
	function client.lines() return client.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)") end
	function client.close()
		if not exited then
			stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qa!" } }))
			if not vim.wait(1000, function() return exited end, 5) then process:kill("sigterm") end
		end
		for _, pipe in ipairs({ stdin, stdout, stderr }) do if not pipe:is_closing() then pipe:close() end end
	end
	client.request("nvim_ui_attach", { 80, 20, { rgb = true, ext_linegrid = true } })
	client.lua([[
		local completion_options = ...
		_G.requests, _G.notices = {}, {}
		_G.initial_editor_maps = { ctrl_l = vim.fn.maparg('<C-l>', 'i', false, true),
			tab = vim.fn.maparg('<Tab>', 'i', false, true) }
		vim.notify = function(message) notices[#notices + 1] = message end
		-- Start in an already connected state before registering the event bridge,
		-- so this editor-only fixture does not launch unrelated catalog requests.
		require('opencode.state').set_connection('connected')
		require('opencode').setup({ server = { auto_start = false }, lualine = { enabled = false },
			completion = vim.tbl_deep_extend('force', {
				enabled = true, model = { providerID = 'test', modelID = 'fast' },
			}, completion_options) })
		notices = {}
		require('opencode.lifecycle').ensure_connected = function(callback) callback(); return true end
		require('opencode.lifecycle').resolve_completion_model = function() return { providerID = 'test', id = 'fast' } end
		require('opencode.client').generate_completion = function(prompt, model, callback, opts)
			local request = { prompt = prompt, model = model, callback = callback, opts = opts }
			requests[#requests + 1] = request
			return { cancel = function() request.cancelled = true end }
		end
		_G.visible = require('opencode').completion_visible
		_G.marks = function()
			return vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().OpenCodeCompletion, 0, -1, {})
		end
	]], { completion_options or {} })
	return client
end

describe("editor completion acceptance with real input", function()
	local client
	before_each(function() client = editor() end)
	after_each(function() if client then client.close() end end)

	it("accepts a multiline block with separate undo and redo steps before and after it", function()
		client.feed("iclass Sample")
		client.wait("vim.api.nvim_get_mode().mode == 'i' and vim.api.nvim_get_current_line() == 'class Sample'")
		client.feed("<C-l>")
		client.wait("#requests == 1 and #marks() == 1 and not visible()")
		client.respond(1, ":\n    pass")
		client.wait("visible()")
		assert.same({ "class Sample" }, client.lines())
		client.feed("<Tab>")
		client.wait("not visible() and vim.api.nvim_buf_line_count(0) == 2")
		assert.same({ "class Sample:", "    pass" }, client.lines())
		assert.same({ 2, 8 }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		client.feed(" # tail")
		client.wait("vim.api.nvim_get_current_line() == '    pass # tail'")
		client.feed("<Esc>")
		client.wait("vim.api.nvim_get_mode().mode == 'n'")
		client.feed("u")
		client.wait("vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == '    pass'")
		assert.same({ "class Sample:", "    pass" }, client.lines())
		client.feed("u")
		client.wait("vim.api.nvim_buf_line_count(0) == 1")
		assert.same({ "class Sample" }, client.lines())
		client.feed("u")
		client.wait("vim.api.nvim_get_current_line() == ''")
		client.feed("<C-r>")
		client.wait("vim.api.nvim_get_current_line() == 'class Sample'")
		assert.same({ "class Sample" }, client.lines())
		client.feed("<C-r>")
		client.wait("vim.api.nvim_buf_line_count(0) == 2")
		assert.same({ "class Sample:", "    pass" }, client.lines())
		client.feed("<C-r>")
		client.wait("vim.api.nvim_buf_get_lines(0, 1, 2, false)[1] == '    pass # tail'")
		assert.same({ "class Sample:", "    pass # tail" }, client.lines())
	end)

	it("uses configured trigger and accept keys without taking over Ctrl-L or Tab", function()
		client.close()
		client = editor({ keymaps = { trigger = "<F7>", accept = "<F8>" } })
		assert.is_true(client.lua("return vim.deep_equal(initial_editor_maps.ctrl_l, vim.fn.maparg('<C-l>', 'i', false, true))"))
		assert.is_true(client.lua("return vim.deep_equal(initial_editor_maps.tab, vim.fn.maparg('<Tab>', 'i', false, true))"))
		client.lua([[
			_G.ctrl_hits, _G.tab_hits = 0, 0
			_G.ordinary_ctrl_l = function() ctrl_hits = ctrl_hits + 1; return 'L' end
			_G.ordinary_tab = function() tab_hits = tab_hits + 1; return 'T' end
			vim.keymap.set('i', '<C-l>', ordinary_ctrl_l, { buffer = 0, expr = true })
			vim.keymap.set('i', '<Tab>', ordinary_tab, { buffer = 0, expr = true })
		]])
		client.feed("ix = ")
		client.wait("vim.api.nvim_get_current_line() == 'x = '")
		client.feed("<F7>")
		client.wait("#requests == 1 and #marks() == 1")
		client.respond(1, "1")
		client.wait("visible()")
		assert.is_true(client.lua("return vim.fn.maparg('<C-l>', 'i', false, true).callback == ordinary_ctrl_l"))
		assert.is_true(client.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback == ordinary_tab"))
		client.feed("<F8>")
		client.wait("vim.api.nvim_get_current_line() == 'x = 1' and not visible()")
		assert.is_true(client.lua("return vim.tbl_isempty(vim.fn.maparg('<F8>', 'i', false, true))"))
		client.feed("<C-l><Tab>")
		client.wait("vim.api.nvim_get_current_line() == 'x = 1LT'")
		assert.same({ 1, 1, 1 }, client.lua("return { ctrl_hits, tab_hits, #requests }"))
	end)

	it("inserts Unicode before the untouched suffix and places the cursor after it", function()
		client.lua([[vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'local café = ()' })
			vim.api.nvim_win_set_cursor(0, { 1, #'local café = (' })]])
		client.feed("i<C-l>")
		client.wait("#requests == 1")
		client.respond(1, "世界")
		client.wait("visible()")
		client.feed("<Tab>")
		client.wait("vim.api.nvim_get_current_line() == 'local café = (世界)'")
		assert.same({ 1, #"local café = (世界" }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		client.feed("!")
		client.wait("vim.api.nvim_get_current_line() == 'local café = (世界!)'")
	end)

	it("regenerates pending and ready requests while discarding superseded responses", function()
		client.feed("ivalue = ")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		client.feed("<C-l>")
		client.wait("#requests == 1")
		client.feed("<C-l>")
		client.wait("#requests == 2 and requests[1].cancelled == true")
		client.respond(1, "obsolete")
		assert.is_false(client.lua("return visible()"))
		client.respond(2, "1")
		client.wait("visible()")
		client.feed("<C-l>")
		client.wait("#requests == 3 and not visible()")
		assert.is_truthy(client.lua([[return requests[3].prompt:find('"previous_suggestion":"1"', 1, true)]]))
		client.respond(3, "2")
		client.wait("visible()")
		client.feed("<Tab>")
		client.wait("vim.api.nvim_get_current_line() == 'value = 2'")
	end)

	it("invalidates on typing, cursor-only movement, InsertLeave, and typing over a ready ghost", function()
		client.feed("ivalue = ")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		client.feed("<C-l>")
		client.wait("#requests == 1")
		client.feed("x")
		client.wait("requests[1].cancelled == true")
		client.respond(1, "late typing")
		assert.is_false(client.lua("return visible()"))
		assert.equals(0, client.lua("return #marks()"))
		client.feed("<C-l>")
		client.wait("#requests == 2")
		client.feed("<Left>")
		client.wait("requests[2].cancelled == true")
		client.respond(2, "late movement")
		assert.is_false(client.lua("return visible()"))
		client.feed("<C-l>")
		client.wait("#requests == 3")
		client.feed("<Esc>")
		client.wait("requests[3].cancelled == true and vim.api.nvim_get_mode().mode == 'n'")
		client.respond(3, "late normal mode")
		assert.is_false(client.lua("return visible()"))
		assert.same({ "value = x" }, client.lines())
		client.feed("A<C-l>")
		client.wait("#requests == 4")
		client.respond(4, "finish")
		client.wait("visible()")
		client.feed("y")
		client.wait("not visible() and #marks() == 0")
		assert.same({ "value = xy" }, client.lines())
	end)

	it("accepts from an expression mapping and restores the previous Lua Tab mapping", function()
		client.lua([[
			_G.fallbacks, _G.expression_accepts = 0, 0
			_G.original_tab = function() fallbacks = fallbacks + 1; return 'fallback' end
			vim.keymap.set('i', '<Tab>', original_tab, { buffer = 0, expr = true })
			vim.keymap.set('i', '<F6>', function()
				local accepted = require('opencode').accept_completion()
				if accepted then expression_accepts = expression_accepts + 1 end
				return accepted and '' or 'missing'
			end, { buffer = 0, expr = true })
		]])
		client.feed("ivalue=")
		client.wait("vim.api.nvim_get_current_line() == 'value='")
		client.feed("<C-l>")
		client.wait("#requests == 1")
		client.respond(1, "done")
		client.wait("visible()")
		client.feed("<F6>")
		client.wait("vim.api.nvim_get_current_line() == 'value=done'")
		assert.equals(1, client.lua("return expression_accepts"))
		assert.is_true(client.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback == original_tab"))
		client.feed("<Tab>")
		client.wait("vim.api.nvim_get_current_line() == 'value=donefallback'")
		assert.equals(1, client.lua("return fallbacks"))
		assert.same({}, client.lua("return notices"))
	end)

	it("cancels pending work on a real buffer switch or wipe and ignores late results", function()
		client.feed("isource = ")
		client.wait("vim.api.nvim_get_current_line() == 'source = '")
		client.feed("<C-l>")
		client.wait("#requests == 1")
		client.lua([[
			_G.source_buffer = vim.api.nvim_get_current_buf()
			_G.other_buffer = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_set_current_buf(other_buffer)
		]])
		client.wait("requests[1].cancelled == true and vim.api.nvim_get_current_buf() == other_buffer")
		client.respond(1, "late switch")
		assert.is_false(client.lua("return visible()"))
		assert.same({ "" }, client.lines())
		assert.equals(0, client.lua([[return #vim.api.nvim_buf_get_extmarks(source_buffer,
			vim.api.nvim_get_namespaces().OpenCodeCompletion, 0, -1, {})]]))
		client.feed("<Esc>iother = ")
		client.wait("vim.api.nvim_get_current_line() == 'other = '")
		client.feed("<C-l>")
		client.wait("#requests == 2")
		client.lua("vim.api.nvim_buf_delete(other_buffer, { force = true })")
		client.wait("requests[2].cancelled == true and not vim.api.nvim_buf_is_valid(other_buffer)")
		client.respond(2, "late wipe")
		assert.is_false(client.lua("return visible()"))
		assert.equals(0, client.lua("return #marks()"))
		assert.same({ "source = " }, client.lua("return vim.api.nvim_buf_get_lines(source_buffer, 0, -1, false)"))
	end)
end)
