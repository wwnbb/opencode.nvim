-- Real Visual input through the public API, controller, and popup. Only the
-- connection and generation callback are stubbed so no model is required.
local function editor(explanation_options)
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
		assert.is_true(vim.wait(3000, function() return client.lua("return " .. expression) end, 10),
			expression .. "\n" .. vim.inspect(client.lua([[return { mode = vim.api.nvim_get_mode().mode,
				requests = #requests, open = require('opencode.ui.explanation').is_open(),
				lines = vim.api.nvim_buf_get_lines(0, 0, -1, false), notices = notices }]])))
	end
	function client.close()
		if not exited then
			stdin:write(vim.mpack.encode({ 2, "nvim_command", { "qa!" } }))
			if not vim.wait(1000, function() return exited end, 5) then process:kill("sigterm") end
		end
		for _, pipe in ipairs({ stdin, stdout, stderr }) do if not pipe:is_closing() then pipe:close() end end
	end
	client.request("nvim_ui_attach", { 100, 32, { rgb = true, ext_linegrid = true } })
	client.lua([[
		local explanation_options = ...
		_G.requests, _G.notices = {}, {}
		vim.notify = function(message) notices[#notices + 1] = message end
		require('opencode.state').set_connection('connected')
		require('opencode').setup({ server = { auto_start = false }, lualine = { enabled = false },
			explanation = vim.tbl_deep_extend('force',
				{ enabled = true, model = { providerID = 'test', modelID = 'explain' } },
				explanation_options) })
		require('opencode.lifecycle').ensure_connected = function(callback) callback(); return true end
		require('opencode.lifecycle').resolve_explanation_model = function()
			return { providerID = 'test', id = 'explain' }
		end
		require('opencode.client').generate_explanation = function(prompt, model, callback, opts)
			local request = { prompt = prompt, model = model, callback = callback, opts = opts }
			requests[#requests + 1] = request
			return { cancel = function() request.cancelled = true end }
		end
		_G.source = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(source)
		vim.api.nvim_buf_set_lines(source, 0, -1, false,
			{ 'local café = 1', 'return café', 'after()' })
		vim.bo[source].filetype = 'lua'
		vim.bo[source].modified = false
		_G.tick = vim.api.nvim_buf_get_changedtick(source)
	]], { explanation_options or {} })
	return client
end

describe("Visual explanation in a fresh Neovim process", function()
	local client
	before_each(function() client = editor() end)
	after_each(function() if client then client.close() end end)

	it("opens on linewise Visual K, shows the full scrollable reply, and copies it without editing source", function()
		client.feed("VjK")
		client.wait("#requests == 1 and require('opencode.ui.explanation').is_open()")
		assert.is_truthy(client.lua([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
			:find('Explaining selection', 1, true)]]))
		local payload = client.lua("return vim.json.decode(requests[1].prompt:match('Context %(JSON%):\\n(.*)$'))")
		assert.same({ { line = 1, text = "local café = 1" }, { line = 2, text = "return café" } }, payload.selection)
		assert.equals("line", payload.selection_mode)
		assert.same({ providerID = "test", id = "explain" }, client.lua("return requests[1].model"))
		local answer = "L1–2 — Defines and returns a value.\n" .. string.rep("More detail.\n", 39) .. "More detail."
		local raw = "The user wants me to explain the code.\n<answer>\n" .. answer
			.. "\n</answer>\nKeep it concise and in Russian."
		client.lua("requests[1].callback(nil, ...)", { raw })
		client.wait("vim.api.nvim_buf_line_count(0) > 30")
		local displayed = client.lua([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')]])
		assert.is_truthy(displayed:find("L1–2 — Defines and returns a value.", 1, true))
		assert.is_nil(displayed:find("The user wants me", 1, true))
		assert.is_nil(displayed:find("Keep it concise", 1, true))
		assert.is_nil(displayed:find("<answer>", 1, true))
		client.feed("25j")
		client.wait("vim.api.nvim_win_get_cursor(0)[1] == 26")
		client.feed("c")
		client.wait("vim.fn.getreg('\\\"') ~= ''")
		assert.equals(answer, client.lua("return vim.fn.getreg('\\\"')"))
		assert.same({ "local café = 1", "return café", "after()" },
			client.lua("return vim.api.nvim_buf_get_lines(source, 0, -1, false)"))
		assert.equals(client.lua("return tick"), client.lua("return vim.api.nvim_buf_get_changedtick(source)"))
		client.feed("q")
		client.wait("not require('opencode.ui.explanation').is_open()")
	end)

	it("cancels on Esc, discards a late answer, and leaves Normal K available", function()
		assert.is_true(client.lua("return vim.tbl_isempty(vim.fn.maparg('K', 'n', false, true))"))
		client.feed("vllK")
		client.wait("#requests == 1 and require('opencode.ui.explanation').is_open()")
		client.feed("<Esc>")
		client.wait("requests[1].cancelled == true and not require('opencode.ui.explanation').is_open()")
		client.lua("requests[1].callback(nil, 'L1 — late')")
		assert.same({ "local café = 1", "return café", "after()" },
			client.lua("return vim.api.nvim_buf_get_lines(source, 0, -1, false)"))
		assert.is_false(client.lua("return require('opencode.ui.explanation').is_open()"))
	end)

	it("uses a custom setup prompt with its language when Visual K builds the request", function()
		client.close()
		client = editor({ prompt = "Décris les blocs en {language} avec leurs lignes.", language = "fr" })
		client.feed("VjK")
		client.wait("#requests == 1 and require('opencode.ui.explanation').is_open()")
		local prompt = client.lua("return requests[1].prompt")
		assert.is_truthy(prompt:find("Décris les blocs en fr", 1, true))
		assert.is_nil(prompt:find("Explain the selected source code", 1, true))
		assert.is_truthy(prompt:find('"text":"local café = 1"', 1, true))
	end)
end)
