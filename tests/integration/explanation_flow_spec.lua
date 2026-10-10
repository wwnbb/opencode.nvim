-- Real Visual input through the public API, controller, and popup. Only the
-- connection and generation callback are stubbed so no model is required.
local function editor(explanation_options)
	local client = require("tests.helpers.embedded_editor").new()
	function client.wait(expression)
		assert.is_true(vim.wait(3000, function() return client.lua("return " .. expression) end, 10),
			expression .. "\n" .. vim.inspect(client.lua([[return { mode = vim.api.nvim_get_mode().mode,
				requests = #requests, open = require('opencode.ui.explanation').is_open(),
				lines = vim.api.nvim_buf_get_lines(0, 0, -1, false), notices = notices }]])))
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
		client.lua([[
			local namespace = vim.api.nvim_create_namespace('explanation_diagnostics')
			vim.diagnostic.set(namespace, source, {
				{ lnum = 0, col = 6, end_lnum = 0, end_col = 11, severity = vim.diagnostic.severity.WARN,
					source = 'Ruff', code = 'F841', message = 'Local variable is assigned but never used',
					user_data = { private = 'private diagnostic metadata' } },
				{ lnum = 2, col = 0, severity = vim.diagnostic.severity.ERROR,
					message = 'Unselected diagnostic' },
			})
			local other = vim.api.nvim_create_buf(true, false)
			vim.diagnostic.set(namespace, other, {
				{ lnum = 0, col = 0, message = 'Another buffer diagnostic' },
			})
		]])
		client.feed("VjK")
		client.wait("#requests == 1 and require('opencode.ui.explanation').is_open()")
		assert.is_truthy(client.lua([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
			:find('Explaining selection', 1, true)]]))
		local payload = client.lua("return vim.json.decode(requests[1].prompt:match('Context %(JSON%):\\n(.*)$'))")
		assert.same({ { line = 1, text = "local café = 1" }, { line = 2, text = "return café" } }, payload.selection)
		assert.equals("line", payload.selection_mode)
		assert.same({ { line = 1, column = 7, end_line = 1, end_column = 12, severity = "WARN",
			source = "Ruff", code = "F841", message = "Local variable is assigned but never used" } }, payload.diagnostics)
		local prompt = client.lua("return requests[1].prompt")
		assert.is_nil(prompt:find("Unselected diagnostic", 1, true))
		assert.is_nil(prompt:find("Another buffer diagnostic", 1, true))
		assert.is_nil(prompt:find("private diagnostic metadata", 1, true))
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

	it("shows streamed Markdown before completion and preserves the reader's position", function()
		client.feed("VjK")
		client.wait("#requests == 1 and require('opencode.ui.explanation').is_open()")
		client.lua("requests[1].opts.on_update(...)", { "Thinking about the code.\n<ans" })
		assert.is_truthy(client.lua([[return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
			:find('Explaining selection', 1, true)]]))
		local answer = "```lua\nlocal café = 1\n```\n\n**Значение**\n" .. string.rep("Подробности.\n", 40)
		client.lua("requests[1].opts.on_update(...)", { "Thinking about the code.\n<answer>\n" .. answer })
		client.wait("vim.api.nvim_buf_line_count(0) > 30")
		local displayed = client.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)")
		assert.equals("local café = 1", displayed[1])
		assert.equals("Значение", displayed[3])
		client.feed("25j")
		client.wait("vim.api.nvim_win_get_cursor(0)[1] == 26")
		local top = client.lua("return vim.fn.line('w0')")
		answer = answer .. "Последняя строка."
		client.lua("requests[1].opts.on_update(...)", { "<answer>\n" .. answer .. "\n</ans" })
		assert.equals(26, client.lua("return vim.api.nvim_win_get_cursor(0)[1]"))
		assert.equals(top, client.lua("return vim.fn.line('w0')"))
		client.lua("requests[1].callback(nil, ...)", { "<answer>\n" .. answer .. "\n</answer>\nHidden tail" })
		assert.equals(26, client.lua("return vim.api.nvim_win_get_cursor(0)[1]"))
		client.feed("c")
		client.wait("vim.fn.getreg('\\\"') ~= ''")
		assert.equals(answer, client.lua("return vim.fn.getreg('\\\"')"))
		assert.equals(client.lua("return tick"), client.lua("return vim.api.nvim_buf_get_changedtick(source)"))
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
