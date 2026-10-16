-- Real Insert-mode input through the full public API/controller/UI. Only the
-- connection and generation request are stubbed; buffer edits and undo are real.
local function editor(completion_options)
	local client = require("tests.helpers.embedded_editor").new()
	function client.wait(expression)
		local deadline, matched = vim.uv.hrtime() + 2000000000, false
		vim.wait(2000, function()
			matched = client.lua("return " .. expression)
			return matched or vim.uv.hrtime() >= deadline
		end, 10)
		assert.is_true(matched, expression
			.. "\n" .. vim.inspect(client.lua([[return { mode = vim.api.nvim_get_mode().mode,
				lines = vim.api.nvim_buf_get_lines(0, 0, -1, false), cursor = vim.api.nvim_win_get_cursor(0),
				requests = #requests, notices = notices, visible = require('opencode').completion_visible() }]])))
	end
	function client.respond(index, text) client.lua("local index, text = ...; requests[index].callback(nil, text)", { index, text }) end
	function client.update(index, text) client.lua("local index, text = ...; requests[index].opts.on_update(text)", { index, text }) end
	function client.lines() return client.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)") end
	client.request("nvim_ui_attach", { 80, 20, { rgb = true, ext_linegrid = true } })
	client.lua([[
		local completion_options = ...
		_G.requests, _G.notices, _G.accepts = {}, {}, 0
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
		local actions = require('opencode.actions')
		local accept = actions.accept_completion
		actions.accept_completion = function()
			local accepted = accept()
			if accepted then accepts = accepts + 1 end
			return accepted
		end
		require('opencode.lifecycle').ensure_connected = function(callback) callback(); return true end
		require('opencode.lifecycle').resolve_completion_model = function() return { providerID = 'test', id = 'fast' } end
		require('opencode.client').generate_completion = function(prompt, model, callback, opts)
			local request = { prompt = prompt, model = model, callback = callback, opts = opts }
			requests[#requests + 1] = request
			return { cancel = function() request.cancelled = true end }
		end
		_G.visible = require('opencode').completion_visible
		_G.marks = function(details)
			return vim.api.nvim_buf_get_extmarks(0, vim.api.nvim_get_namespaces().OpenCodeCompletion, 0, -1, { details = details == true })
		end
	]], { completion_options or {} })
	return client
end

describe("editor completion acceptance with real input", function()
	local client
	before_each(function() client = editor() end)
	after_each(function() if client then client.close() end end)
	local function autoindented_body(expandtab)
		client.lua([[
			vim.bo.autoindent, vim.bo.indentexpr = true, '4'
			vim.bo.shiftwidth, vim.bo.tabstop, vim.bo.expandtab = 4, 4, ...
		]], { expandtab })
		client.feed("idef guess_number():<CR>")
		client.wait("vim.api.nvim_get_mode().mode == 'i' and vim.api.nvim_buf_line_count(0) == 2")
		local indent = expandtab and "    " or "\t"
		assert.same({ "def guess_number():", indent }, client.lines())
		return indent
	end
	local function arm_two_lines()
		client.feed("ialpha = <CR>middle<CR>beta = <CR>after<Esc>ggA<C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.feed("<Esc>3GA<C-l><Tab><Cmd>lua _G.pair_armed = true<CR>")
		client.wait("pair_armed == true")
		assert.equals(2, client.lua("return #requests"))
		assert.equals(2, client.lua("return accepts"))
		assert.is_false(client.lua("return requests[1].cancelled == true or requests[2].cancelled == true"))
	end
	local function arm_two_buffers()
		client.feed("ialpha = <C-l><Tab><Esc>")
		client.wait("#requests == 1 and accepts == 1 and vim.api.nvim_get_mode().mode == 'n'")
		client.lua([[
			_G.source_buffer = vim.api.nvim_get_current_buf()
			_G.other_buffer = vim.api.nvim_create_buf(true, false)
			vim.api.nvim_set_current_buf(other_buffer)
		]])
		client.feed("ibeta = <CR>other<Esc>ggA<C-l><Tab><Cmd>lua _G.pair_armed = true<CR>")
		client.wait("pair_armed == true")
		assert.equals(2, client.lua("return #requests"))
		assert.equals(2, client.lua("return accepts"))
		assert.is_false(client.lua("return requests[1].cancelled == true or requests[2].cancelled == true"))
	end

	for _, case in ipairs({
		{ "end of line", "ivalue = ", "value = ", "", "value = 42" },
		{ "before a suffix", "iprint()<Left>", "print(", ")", "print(42)" },
		{ "before UTF-8 text", "iprint('é')<Left><Left><Left>", "print('", "é')", "print('42é')" },
	}) do
		it("prompts for an instruction and accepts completion " .. case[1], function()
			client.feed(case[2])
			client.wait("vim.api.nvim_get_mode().mode == 'i'")
			local original = client.lines()
			client.feed("<C-S-l>")
			client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			assert.equals(0, client.lua("return #requests"))
			client.feed("use the number 42<C-g>")
			client.wait("#requests == 1 and vim.api.nvim_get_mode().mode == 'i'")
			local data = client.lua([[return vim.json.decode(requests[1].prompt:match('Context %(JSON%):\n(.*)$'))]])
			assert.equals("use the number 42", data.instruction)
			assert.equals(case[3], data.prefix)
			assert.equals(case[4], data.suffix)
			assert.same(original, client.lines())
			client.respond(1, "42")
			client.wait("visible()")
			client.feed("<Tab>")
			client.wait("not visible()")
			assert.same({ case[5] }, client.lines())
			assert.same({}, client.lua("return notices"))
		end)
	end

	for _, send in ipairs({ "<C-g>", "<C-x><C-s>" }) do
		it("accepts a multiline instruction with the chat input send key: " .. send, function()
			client.feed("ivalue = <C-S-l>")
			client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			client.feed("use the number 42<CR>keep the existing suffix")
			client.wait("vim.api.nvim_buf_line_count(0) == 2")
			assert.equals(0, client.lua("return #requests"))
			assert.same({ "use the number 42", "keep the existing suffix" }, client.lines())
			assert.is_true(client.lua("return vim.api.nvim_win_get_height(0) >= 2"))
			client.feed(send)
			client.wait("#requests == 1 and vim.api.nvim_get_mode().mode == 'i'")
			local data = client.lua([[return vim.json.decode(requests[1].prompt:match('Context %(JSON%):\n(.*)$'))]])
			assert.equals("use the number 42\nkeep the existing suffix", data.instruction)
			assert.same({ "value = " }, client.lines())
			client.respond(1, "42")
			client.wait("visible()")
			client.feed("<Tab>")
			client.wait("not visible()")
			assert.same({ "value = 42" }, client.lines())
		end)
	end

	it("uses the chat input surface with completion controls and no chat selectors", function()
		client.feed("ivalue = <C-S-l>")
		client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
		local surface = client.lua([[
			local text, mappings = {}, {}
			for _, winid in ipairs(vim.api.nvim_list_wins()) do
				if vim.api.nvim_win_get_config(winid).relative ~= '' then
					vim.list_extend(text, vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(winid), 0, -1, false))
				end
			end
			for _, key in ipairs({ '<C-t>', '<C-a>', '<C-e>', '<C-\\>' }) do
				local mapping = vim.fn.maparg(key, 'i', false, true)
				if mapping.buffer == 1 then mappings[#mappings + 1] = key end
			end
			return { highlight = vim.wo.winhighlight, text = table.concat(text, '\n'), mappings = mappings }
		]])
		assert.is_truthy(surface.highlight:find("Normal:OpenCodeInputBg", 1, true))
		assert.is_truthy(surface.text:find("┃", 1, true))
		assert.is_truthy(surface.text:find("fast", 1, true))
		assert.is_nil(surface.text:find(":send", 1, true))
		assert.is_nil(surface.text:find(":cancel", 1, true))
		assert.same({}, surface.mappings)
		client.feed("<Esc>")
		client.wait("vim.bo.filetype ~= 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
		assert.same({ "value = " }, client.lines())
	end)

	for _, finish in ipairs({ "<Esc>", "<C-g>" }) do
		it("preserves the chat draft when finishing a completion instruction: " .. finish, function()
			client.lua([[
				local history = require('opencode.ui.input.history')
				history.set_pending('Keep my chat draft', { { type = 'agent', name = 'explore' } })
				history.set_pending_mode('shell')
				history.set_pending_cursor(5)
				history.set_pending_options({ delivery = 'steer' })
				_G.read_chat_draft = function()
					return { text = history.get_pending(), parts = history.get_pending_parts(),
						mode = history.get_pending_mode(), cursor = history.get_pending_cursor(),
						options = history.get_pending_options() }
				end
			]])
			local draft = client.lua("return read_chat_draft()")
			client.feed("ivalue = <C-S-l>")
			client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			assert.same({ "" }, client.lines())
			client.feed("use 42" .. finish)
			client.wait("vim.bo.filetype ~= 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			assert.same(draft, client.lua("return read_chat_draft()"))
			assert.same({ "value = " }, client.lines())
		end)
	end

	for _, cancel in ipairs({ "<Esc>", "   <C-g>" }) do
		it("cancels the instruction prompt without requesting or editing: " .. cancel, function()
			client.feed("ivalue = <C-S-l>")
			client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			client.feed(cancel)
			client.wait("vim.bo.filetype ~= 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			assert.equals(0, client.lua("return #requests"))
			assert.same({ "value = " }, client.lines())
			assert.same({ 1, #"value = " }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		end)
	end

	for _, expandtab in ipairs({ true, false }) do
		for _, cancel in ipairs({ "<Esc>", "<C-c>", "<C-g>" }) do
			it("preserves untouched autoindent when cancelling a prompt: " .. tostring(expandtab) .. cancel, function()
				local indent = autoindented_body(expandtab)
				client.feed("<C-S-l>")
				client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
				client.feed(cancel)
				client.wait("vim.bo.filetype ~= 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
				assert.same({ "def guess_number():", indent }, client.lines())
				assert.equals(0, client.lua("return #requests"))
			end)
		end
		it("preserves native autoindent through the instruction prompt: " .. tostring(expandtab), function()
			local indent = autoindented_body(expandtab)
			client.feed("<C-S-l>")
			client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			client.feed("return 42<C-g>")
			client.wait("#requests == 1 and vim.api.nvim_get_mode().mode == 'i'")
			assert.same({ "def guess_number():", indent }, client.lines())
			client.respond(1, "return 42")
			client.wait("visible()")
			client.feed("<Tab>")
			client.wait("not visible()")
			assert.same({ "def guess_number():", indent .. "return 42" }, client.lines())
		end)
	end

	it("closes an instruction prompt on teardown without starting a request", function()
		client.feed("ivalue = <C-S-l>")
		client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
		client.lua("require('opencode.completion').teardown()")
		client.wait("vim.bo.filetype ~= 'opencode_input'")
		assert.equals(0, client.lua("return #requests"))
		assert.same({ "value = " }, client.lines())
	end)

	it("honors dismissal between submitting an instruction and resuming the source", function()
		client.lua([[
			local prompt = require('opencode.ui.completion_prompt')
			local create = prompt.open
			prompt.open = function(opts)
				local submit = opts.on_submit
				opts.on_submit = function(value)
					submit(value)
					require('opencode').dismiss_completion()
				end
				return create(opts)
			end
		]])
		client.feed("ivalue = <C-S-l>")
		client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
		client.feed("return 42<C-g>")
		client.wait("vim.bo.filetype ~= 'opencode_input' and vim.api.nvim_get_mode().mode == 'n'")
		client.feed("A<Cmd>lua _G.resumed_after_dismissal = true<CR>")
		client.wait("resumed_after_dismissal == true")
		assert.equals(0, client.lua("return #requests"))
		assert.same({ "value = " }, client.lines())
	end)

	it("does not request completion if the source changed while entering an instruction", function()
		client.feed("ivalue = ")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		client.lua("_G.prompt_source = vim.api.nvim_get_current_buf()")
		client.feed("<C-S-l>")
		client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
		client.lua("vim.api.nvim_buf_set_lines(prompt_source, 0, -1, false, { 'changed' })")
		client.feed("use 42<C-g>")
		client.wait("vim.api.nvim_get_current_buf() == prompt_source and vim.api.nvim_get_mode().mode == 'n'")
		assert.equals(0, client.lua("return #requests"))
		assert.same({ "changed" }, client.lines())
	end)

	local function edit_selection(lines, keys)
		client.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, ...); vim.bo.modified = false", { lines })
		client.feed(keys .. "<C-S-l>")
		client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
		client.feed("simplify this code<C-g>")
		client.wait("#requests == 1 and vim.api.nvim_get_mode().mode == 'n'")
		assert.same(lines, client.lines())
	end

	for _, case in ipairs({
		{ "linewise", { "before", "old one", "old two", "after" }, "2GVj", "new\ncode\n", { "before", "new", "code", "after" } },
		{ "reversed linewise", { "before", "old one", "old two", "after" }, "3GVk", "new", { "before", "new", "after" } },
		{ "a word", { "local value = old" }, "gg0wve", "result", { "local result = old" } },
		{ "Unicode characters", { "print('é世')" }, "gg07lvl", "ok", { "print('ok')" } },
		{ "multiple partial lines", { "before", "prefix old", "middle", "old suffix", "after" }, "2G0wv2j0ll", "new\ncode", { "before", "prefix new", "code suffix", "after" } },
		{ "an inclusive end-of-line", { "prefix old", "next" }, "gg0wv$", "new", { "prefix newnext" } },
		{ "an exclusive newline", { "prefix old", "next" }, "gg0wvj0", "new", { "prefix newnext" }, "exclusive" },
		{ "an empty final selected line", { "prefix old", "", "next" }, "gg0wvj0", "new", { "prefix newnext" } },
		{ "deleting selected lines", { "before", "remove", "after" }, "2GV", "", { "before", "after" } },
		{ "deleting a word", { "local value = old" }, "gg0wve", "", { "local  = old" } },
	}) do
		it("previews and replaces only " .. case[1] .. " selection in one undo step", function()
			client.lua("vim.o.selection = ...", { case[6] or "inclusive" })
			edit_selection(case[2], case[3])
			assert.is_false(client.lua("return vim.bo.modified"))
			client.respond(1, case[4])
			client.wait("visible()")
			assert.same(case[2], client.lines())
			assert.is_false(client.lua("return vim.bo.modified"))
			assert.is_true(client.lua("return #marks(true)[1][4].virt_lines > 0"))
			client.feed("<Tab>")
			client.wait("not visible() and #marks() == 0")
			assert.same(case[5], client.lines())
			client.feed("u<Cmd>lua _G.selection_undone = true<CR>")
			client.wait("selection_undone == true")
			assert.same(case[2], client.lines())
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("keeps large selected blocks within their own replacement line allowance", function()
		local lines = {}
		for index = 1, 20 do lines[index] = "old " .. index end
		edit_selection(lines, "ggVG")
		local data = client.lua([[return vim.json.decode(requests[1].prompt:match('Context %(JSON%):\n(.*)$'))]])
		assert.equals("simplify this code", data.instruction)
		assert.equals(32, data.max_lines)
		client.update(1, "new")
		assert.same(lines, client.lines())
		client.feed("<Tab>")
		client.wait("accepts == 1")
		local changed = vim.deepcopy(lines)
		changed[1] = "new 1"
		client.respond(1, table.concat(changed, "\n"))
		client.wait("#marks() == 0")
		assert.same(changed, client.lines())
	end)

	for _, cancel in ipairs({ "<Esc>", "<C-g>" }) do
		it("cancels a Visual edit prompt without modifying the selection: " .. cancel, function()
			client.lua("vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'keep', 'unchanged' })")
			client.feed("ggVj<C-S-l>")
			client.wait("vim.bo.filetype == 'opencode_input' and vim.api.nvim_get_mode().mode == 'i'")
			client.feed(cancel)
			client.wait("vim.bo.filetype ~= 'opencode_input' and vim.api.nvim_get_mode().mode == 'n'")
			assert.same({ "keep", "unchanged" }, client.lines())
			assert.equals(0, client.lua("return #requests"))
		end)
	end

	it("rejects a selection preview with Esc and restores the previous Normal mappings", function()
		client.lua("vim.keymap.set('n', '<Tab>', 'original'); vim.keymap.set('n', '<Esc>', 'original')")
		local original = client.lua("return { vim.fn.maparg('<Tab>', 'n', false, true), vim.fn.maparg('<Esc>', 'n', false, true) }")
		edit_selection({ "keep", "unchanged" }, "ggVj")
		client.respond(1, "replacement")
		client.wait("visible()")
		client.feed("<Esc>")
		client.wait("not visible() and #marks() == 0")
		assert.same({ "keep", "unchanged" }, client.lines())
		assert.same(original, client.lua("return { vim.fn.maparg('<Tab>', 'n', false, true), vim.fn.maparg('<Esc>', 'n', false, true) }"))
	end)

	it("cancels a queued selection edit on any source change and ignores late output", function()
		edit_selection({ "before", "selected", "after" }, "2GV")
		client.feed("<Tab>")
		client.wait("accepts == 1")
		client.lua("vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'changed elsewhere' })")
		client.wait("requests[1].cancelled == true and #marks() == 0")
		client.update(1, "stale stream")
		client.respond(1, "stale edit")
		assert.same({ "changed elsewhere", "selected", "after" }, client.lines())
	end)

	it("replaces the loading spinner with cumulative ghost text before the final response", function()
		client.feed("ivalue = ")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		client.lua("vim.bo.modified = false")
		local changedtick = client.lua("return vim.api.nvim_buf_get_changedtick(0)")
		client.feed("<C-l>")
		client.wait("#requests == 1 and #marks() == 1")
		assert.is_false(client.lua("return visible()"))
		assert.equals("OpenCodeCompletionSpinner", client.lua("return marks(true)[1][4].virt_text[1][2]"))
		client.update(1, "4")
		client.wait("visible() and marks(true)[1][4].virt_text[1][1] == '4'")
		client.update(1, "42")
		client.wait("marks(true)[1][4].virt_text[1][1] == '42'")
		assert.equals("OpenCodeCompletion", client.lua("return marks(true)[1][4].virt_text[1][2]"))
		assert.same({ 1, #"value = " }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals(changedtick, client.lua("return vim.api.nvim_buf_get_changedtick(0)"))
		assert.is_false(client.lua("return vim.bo.modified"))
		assert.same({ "value = " }, client.lines())
		client.respond(1, "43")
		client.update(1, "late")
		assert.equals("43", client.lua("return marks(true)[1][4].virt_text[1][1]"))
	end)

	it("queues repeated Tab presses before the first token and inserts the final result once", function()
		client.feed("ivalue = ")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		client.feed("<C-l>")
		client.wait("#requests == 1")
		client.feed("<Tab><Tab>")
		client.wait("accepts == 2")
		assert.same({ "value = " }, client.lines())
		assert.is_false(client.lua("return requests[1].cancelled == true"))
		assert.equals(1, client.lua("return #marks()"))
		client.update(1, "4")
		client.wait("visible()")
		assert.same({ "value = " }, client.lines())
		client.respond(1, "42")
		client.wait("not visible() and vim.api.nvim_get_current_line() == 'value = 42'")
		client.respond(1, "duplicate")
		assert.same({ "value = 42" }, client.lines())
		client.feed("x<Esc>u")
		client.wait("vim.api.nvim_get_current_line() == 'value = 42'")
		client.feed("u")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		assert.same({}, client.lua("return notices"))
	end)

	for _, phase in ipairs({ "pending", "streaming" }) do
		it("keeps " .. phase .. " acceptance after Esc and inserts without moving the Normal-mode cursor", function()
			local prefix = "local café = "
			client.feed("i" .. prefix .. "<C-l>")
			client.wait("#requests == 1")
			if phase == "streaming" then client.update(1, "世") end
			client.feed("<Tab><Esc>")
			client.wait("accepts == 1 and vim.api.nvim_get_mode().mode == 'n'")
			assert.is_false(client.lua("return requests[1].cancelled == true"))
			assert.equals(1, client.lua("return #marks()"))
			local cursor = client.lua("return vim.api.nvim_win_get_cursor(0)")
			assert.same({ 1, #prefix - 1 }, cursor)
			client.update(1, "世界")
			assert.same({ prefix }, client.lines())
			client.respond(1, "世界")
			client.wait("#marks() == 0 and vim.api.nvim_get_current_line() == 'local café = 世界'")
			assert.equals("n", client.lua("return vim.api.nvim_get_mode().mode"))
			assert.same(cursor, client.lua("return vim.api.nvim_win_get_cursor(0)"))
			client.feed("u")
			client.wait("vim.api.nvim_get_current_line() == 'local café = '")
			client.feed("u")
			client.wait("vim.api.nvim_get_current_line() == ''")
			assert.same({}, client.lua("return notices"))
		end)
	end

	for _, case in ipairs({ { "spaces", true }, { "tabs", false } }) do
		it("strips untouched native autoindent with " .. case[1] .. " on Esc without completion", function()
			autoindented_body(case[2])
			client.feed("<Esc><Cmd>lua _G.left_insert = true<CR>")
			client.wait("left_insert == true")
			assert.same({ "def guess_number():", "" }, client.lines())
			assert.same({ 2, 0 }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		end)

		it("preserves queued completion and native autoindent with " .. case[1] .. " on Esc", function()
			local indent = autoindented_body(case[2])
			local changedtick = client.lua("return vim.api.nvim_buf_get_changedtick(0)")
			if case[2] then
				client.feed("<C-l><Tab><Tab><Esc><Cmd>lua _G.left_insert = true<CR>")
			else
				client.feed("<C-l>")
				client.wait("#requests == 1")
				client.update(1, "return")
				client.feed("<Tab><Esc><Cmd>lua _G.left_insert = true<CR>")
			end
			client.wait("left_insert == true")
			assert.equals(case[2] and 2 or 1, client.lua("return accepts"))
			assert.equals(changedtick, client.lua("return vim.api.nvim_buf_get_changedtick(0)"))
			assert.same({ "def guess_number():", indent }, client.lines())
			assert.is_false(client.lua("return requests[1].cancelled == true"))
			assert.equals(1, client.lua("return #marks()"))
			local before_completion = client.lines()
			local cursor = client.lua("return vim.api.nvim_win_get_cursor(0)")
			client.update(1, "return 42")
			assert.equals(indent .. "return 42", client.lua([[
				local mark = marks(true)[1]
				return vim.api.nvim_buf_get_lines(0, mark[2], mark[2] + 1, false)[1]:sub(1, mark[3])
					.. mark[4].virt_text[1][1]
			]]))
			client.respond(1, "return 42")
			client.feed("<Cmd>lua _G.commit_checked = true<CR>")
			client.wait("commit_checked == true")
			assert.same({ "def guess_number():", indent .. "return 42" }, client.lines())
			assert.same(cursor, client.lua("return vim.api.nvim_win_get_cursor(0)"))
			assert.equals("n", client.lua("return vim.api.nvim_get_mode().mode"))
			assert.equals(0, client.lua("return #marks()"))
			client.feed("u<Cmd>lua _G.completion_undone = true<CR>")
			client.wait("completion_undone == true")
			assert.same(before_completion, client.lines())
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("preserves autoindent and header edits without invoking user Left or Right mappings", function()
		local indent = autoindented_body(true)
		client.lua([[
			_G.arrow_maps = 0
			for _, key in ipairs({ '<Left>', '<Right>' }) do
				vim.keymap.set('i', key, function() arrow_maps = arrow_maps + 1; return key end,
					{ buffer = 0, expr = true })
			end
		]])
		client.feed("<C-l><Tab><Esc>kA # header<Cmd>lua _G.header_edited = true<CR>")
		client.wait("header_edited == true")
		assert.same({ "def guess_number(): # header", indent }, client.lines())
		assert.is_false(client.lua("return requests[1].cancelled == true"))
		assert.equals(0, client.lua("return arrow_maps"))
		client.respond(1, "return 42")
		client.feed("<Cmd>lua _G.commit_checked = true<CR>")
		client.wait("commit_checked == true")
		assert.same({ "def guess_number(): # header", indent .. "return 42" }, client.lines())
		assert.same({ 1, #"def guess_number(): # header" }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals("i", client.lua("return vim.api.nvim_get_mode().mode"))
		assert.same({}, client.lua("return notices"))
	end)

	for _, deletion in ipairs({ "<BS>", "<C-u>" }) do
		it("cancels queued completion when native autoindent is manually removed with " .. deletion, function()
			local indent = autoindented_body(true)
			client.feed("<C-l><Tab>")
			client.wait("#requests == 1 and accepts == 1")
			client.feed(deletion .. "<Cmd>lua _G.indent_edited = true<CR>")
			client.wait("indent_edited == true")
			assert.is_true(client.lua("return requests[1].cancelled == true"))
			local edited = client.lines()
			assert.is_true(edited[2] ~= indent)
			client.update(1, "return 42")
			client.respond(1, "return 42")
			assert.same(edited, client.lines())
			assert.equals(0, client.lua("return #marks()"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("cancels a non-whitespace target edit made while leaving Insert mode", function()
		autoindented_body(true)
		client.feed("return <C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.lua([[
			vim.api.nvim_create_autocmd('InsertLeavePre', { once = true, callback = function()
				vim.api.nvim_buf_set_lines(0, 1, 2, false, { '' })
			end })
		]])
		client.feed("<Esc><Cmd>lua _G.left_insert = true<CR>")
		client.wait("left_insert == true")
		assert.is_true(client.lua("return requests[1].cancelled == true"))
		client.respond(1, "42")
		assert.same({ "def guess_number():", "" }, client.lines())
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)

	it("handles a final response during InsertLeavePre without replaying Insert undo keys in Normal mode", function()
		client.feed("ivalue = <C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.lua([[
			vim.api.nvim_create_autocmd('InsertLeavePre', {
				once = true,
				callback = function() requests[1].callback(nil, '42') end,
			})
		]])
		client.feed("<Esc>")
		client.wait("vim.api.nvim_get_mode().mode == 'n' and vim.api.nvim_get_current_line() == 'value = 42'")
		assert.same({ 1, #"value = " - 1 }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		client.feed("u")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		assert.same({}, client.lua("return notices"))
	end)

	it("preserves the logical Normal-mode cursor after navigation and a multiline insertion above it", function()
		client.feed("ivalue = <CR>after<Esc>ggA<C-l>")
		client.wait("#requests == 1")
		client.feed("<Tab><Esc>j0")
		client.wait("accepts == 1 and vim.api.nvim_get_mode().mode == 'n' and vim.api.nvim_win_get_cursor(0)[1] == 2")
		assert.same({ 2, 0 }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.is_false(client.lua("return requests[1].cancelled == true"))
		client.respond(1, "42\ncontinued")
		client.wait("#marks() == 0 and vim.api.nvim_buf_line_count(0) == 3")
		assert.same({ "value = 42", "continued", "after" }, client.lines())
		assert.same({ 3, 0 }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals("n", client.lua("return vim.api.nvim_get_mode().mode"))
		client.feed("u")
		client.wait("vim.api.nvim_buf_line_count(0) == 2")
		assert.same({ "value = ", "after" }, client.lines())
		client.feed("<C-r>")
		client.wait("vim.api.nvim_buf_line_count(0) == 3")
		assert.same({ "value = 42", "continued", "after" }, client.lines())
		assert.same({}, client.lua("return notices"))
	end)

	for _, case in ipairs({
		{ "above", "<Up><End>", 1, "before edited" },
		{ "below", "<Down><End>", 4, "after edited" },
	}) do
		it("keeps editing " .. case[1] .. " the target through multiline acceptance with separate undo", function()
			client.feed("ibefore<CR>value = <CR>after<Esc>2GA<C-l><Tab>")
			client.wait("#requests == 1 and accepts == 1")
			client.feed(case[2] .. " edited")
			client.wait("vim.api.nvim_get_current_line() == " .. vim.inspect(case[4]))
			assert.is_false(client.lua("return requests[1].cancelled == true"))
			client.respond(1, "42\ncontinued")
			client.feed("<Cmd>lua _G.commit_checked = true<CR>")
			client.wait("commit_checked == true")
			local expected = { "before", "value = 42", "continued", "after" }
			expected[case[3]] = case[4]
			assert.same(expected, client.lines())
			assert.equals("i", client.lua("return vim.api.nvim_get_mode().mode"))
			assert.same({ case[3], #case[4] }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
			client.feed("!<Esc>u<Cmd>lua _G.tail_undone = true<CR>")
			client.wait("tail_undone == true")
			assert.same(expected, client.lines())
			client.feed("u<Cmd>lua _G.completion_undone = true<CR>")
			client.wait("completion_undone == true")
			local before_completion = { "before", "value = ", "after" }
			before_completion[case[3] == 1 and 1 or 3] = case[4]
			assert.same(before_completion, client.lines())
			client.feed("u<Cmd>lua _G.edit_undone = true<CR>")
			client.wait("edit_undone == true")
			assert.same({ "before", "value = ", "after" }, client.lines())
			assert.same({}, client.lua("return notices"))
		end)
	end

	for _, phase in ipairs({ "pending", "streaming" }) do
		it("tracks the " .. phase .. " target when lines are inserted and deleted above it", function()
			client.feed("ibefore<CR>value = <CR>after<Esc>2GA<C-l><Tab>")
			client.wait("#requests == 1 and accepts == 1")
			if phase == "streaming" then client.update(1, "4") end
			client.feed("<Esc>Oadded<Esc><Cmd>lua _G.line_added = true<CR>")
			client.wait("line_added == true")
			assert.same({ "before", "added", "value = ", "after" }, client.lines())
			assert.is_false(client.lua("return requests[1].cancelled == true"))
			assert.equals(2, client.lua("return marks()[1][2]"))
			client.feed("ggdd<Cmd>lua _G.line_deleted = true<CR>")
			client.wait("line_deleted == true")
			assert.same({ "added", "value = ", "after" }, client.lines())
			assert.is_false(client.lua("return requests[1].cancelled == true"))
			assert.equals(1, client.lua("return marks()[1][2]"))
			client.update(1, "42")
			assert.equals(1, client.lua("return marks()[1][2]"))
			assert.equals("42", client.lua("return marks(true)[1][4].virt_text[1][1]"))
			local cursor = client.lua("return vim.api.nvim_win_get_cursor(0)")
			client.respond(1, "42")
			client.feed("<Cmd>lua _G.commit_checked = true<CR>")
			client.wait("commit_checked == true")
			assert.same({ "added", "value = 42", "after" }, client.lines())
			assert.same(cursor, client.lua("return vim.api.nvim_win_get_cursor(0)"))
			assert.equals(0, client.lua("return #marks()"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("uses the original Tab mapping on another line while keeping queued acceptance", function()
		client.lua([[
			_G.fallbacks = 0
			vim.keymap.set('i', '<Tab>', function() fallbacks = fallbacks + 1; return '  ' end,
				{ buffer = 0, expr = true })
		]])
		client.feed("ibefore<CR>value = <CR>after<Esc>2GA<C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.feed("<Down><End><Tab><Cmd>lua _G.indented = true<CR>")
		client.wait("indented == true")
		assert.same({ "before", "value = ", "after  " }, client.lines())
		assert.same({ 1, 1 }, client.lua("return { accepts, fallbacks }"))
		assert.is_false(client.lua("return requests[1].cancelled == true"))
		client.respond(1, "42")
		client.feed("<Cmd>lua _G.commit_checked = true<CR>")
		client.wait("commit_checked == true")
		assert.same({ "before", "value = 42", "after  " }, client.lines())
		assert.same({ 3, #"after  " }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.same({}, client.lua("return notices"))
	end)

	it("defers a final response during an operator on another line until Normal mode", function()
		client.feed("ivalue = <CR>after<Esc>ggA<C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.feed("<Esc>jd")
		assert.equals("no", client.lua("return vim.api.nvim_get_mode().mode"))
		client.respond(1, "42")
		assert.same({ "value = ", "after" }, client.lines())
		assert.is_false(client.lua("return requests[1].cancelled == true"))
		client.feed("<Esc><Cmd>lua _G.operator_cancelled = true<CR>")
		client.wait("operator_cancelled == true")
		assert.same({ "value = 42", "after" }, client.lines())
		assert.equals("n", client.lua("return vim.api.nvim_get_mode().mode"))
		assert.same({ 2, 4 }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.same({}, client.lua("return notices"))
	end)

	it("preserves queued acceptance through incomplete streamed fences until the final response", function()
		client.lua([[
			_G.fallbacks = 0
			_G.original_tab = function() fallbacks = fallbacks + 1; return '' end
			vim.keymap.set('i', '<Tab>', original_tab, { buffer = 0, expr = true })
		]])
		client.feed("ivalue = ")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		client.feed("<C-l>")
		client.wait("#requests == 1")
		client.feed("<Tab>")
		client.wait("accepts == 1")
		for _, text in ipairs({ "`", "``", "```l", "```lua", "```lua\n42" }) do
			client.update(1, text)
			assert.is_false(client.lua("return visible()"))
			assert.is_false(client.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback == original_tab"))
			assert.same({ "value = " }, client.lines())
		end
		client.update(1, "```lua\n42\n```")
		client.wait("visible() and marks(true)[1][4].virt_text[1][1] == '42'")
		assert.same({ "value = " }, client.lines())
		assert.equals(0, client.lua("return fallbacks"))
		client.respond(1, "```lua\n42\n```")
		client.wait("not visible() and vim.api.nvim_get_current_line() == 'value = 42'")
		assert.same({ "value = 42" }, client.lines())
		assert.is_true(client.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback == original_tab"))
		assert.same({}, client.lua("return notices"))
	end)

	it("accepts the full final response arriving while the streaming Tab mapping runs", function()
		client.feed("ivalue = ")
		client.wait("vim.api.nvim_get_current_line() == 'value = '")
		client.feed("<C-l>")
		client.wait("#requests == 1")
		client.update(1, "42")
		client.wait("visible()")
		client.lua([[
			local actions = require('opencode.actions')
			local accept = actions.accept_completion
			actions.accept_completion = function()
				local accepted = accept()
				requests[1].opts.on_update('43')
				requests[1].callback(nil, '44')
				return accepted
			end
		]])
		client.feed("<Tab>")
		client.wait("not visible() and vim.api.nvim_get_current_line() == 'value = 44'")
		client.update(1, "late update")
		client.respond(1, "late final")
		assert.same({ "value = 44" }, client.lines())
		assert.same({ 1, #"value = 44" }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)


	it("streams and accepts identifier tails and insertions on blank or indented lines", function()
		client.feed("i")
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		for index, case in ipairs({
			{ "", "value = 1" },
			{ '        "-" => number', "1_int - number2_int," },
			{ "    ", "return value" },
			{ "\t", "if ready:\n\t\tpass" },
			{ "", "if ready:\n    pass" },
		}) do
			local prefix, insertion = case[1], case[2]
			client.lua([[
				local prefix = ...
				vim.api.nvim_buf_set_lines(0, 0, -1, false, { prefix, "after" })
				vim.api.nvim_win_set_cursor(0, { 1, #prefix })
				vim.bo.modified = false
			]], { prefix })
			local changedtick = client.lua("return vim.api.nvim_buf_get_changedtick(0)")
			client.feed("<C-l>")
			client.wait("#requests == " .. index)
			client.update(index, insertion)
			client.wait("visible()")
			assert.equals(insertion:match("^[^\n]*"), client.lua("return marks(true)[1][4].virt_text[1][1]"))
			assert.same({ prefix, "after" }, client.lines())
			assert.same({ 1, #prefix }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
			assert.equals(changedtick, client.lua("return vim.api.nvim_buf_get_changedtick(0)"))
			assert.is_false(client.lua("return vim.bo.modified"))
			local expected = vim.split(prefix .. insertion, "\n", { plain = true })
			local cursor = { #expected, #expected[#expected] }
			expected[#expected + 1] = "after"
			client.feed("<Tab>")
			client.wait("accepts == " .. index)
			assert.same({ prefix, "after" }, client.lines())
			client.respond(index, insertion)
			client.wait("not visible() and vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), " .. vim.inspect(expected) .. ")")
			assert.same(expected, client.lines())
			assert.same(cursor, client.lua("return vim.api.nvim_win_get_cursor(0)"))
			assert.is_false(client.lua("return requests[...].cancelled == true", { index }))
		end
		assert.same({}, client.lua("return notices"))
	end)

	it("accepts a multiline block with separate undo and redo steps before and after it", function()
		client.lua([[
			vim.go.undolevels, vim.bo.undolevels = 1000, 2000
			_G.undo_option_changes = 0
			vim.api.nvim_create_autocmd('OptionSet', { pattern = 'undolevels', callback = function()
				undo_option_changes = undo_option_changes + 1
			end })
		]])
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
		assert.same({ 1000, 2000, 0 }, client.lua("return { vim.go.undolevels, vim.bo.undolevels, undo_option_changes }"))
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
		assert.is_true(client.lua("return vim.fn.maparg('<C-l>', 'i', false, true).callback == ordinary_ctrl_l"))
		assert.is_true(client.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback == ordinary_tab"))
		client.feed("<F8>")
		client.wait("accepts == 1")
		assert.same({ "x = " }, client.lines())
		client.respond(1, "1")
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
		client.feed("<Tab><C-l>")
		client.wait("#requests == 2 and requests[1].cancelled == true")
		assert.equals(1, client.lua("return accepts"))
		client.respond(1, "obsolete")
		assert.is_false(client.lua("return visible()"))
		client.respond(2, "1")
		client.wait("visible()")
		assert.same({ "value = " }, client.lines())
		client.feed("<C-l>")
		client.wait("#requests == 3 and not visible()")
		assert.is_truthy(client.lua([[return requests[3].prompt:find('"previous_suggestion":"1"', 1, true)]]))
		client.respond(3, "2")
		client.wait("visible()")
		client.feed("<Tab>")
		client.wait("vim.api.nvim_get_current_line() == 'value = 2'")
	end)

	it("accepts two locations out of order with independent previews and normal Tab elsewhere", function()
		client.lua([[
			_G.fallbacks = 0
			vim.keymap.set('i', '<Tab>', function() fallbacks = fallbacks + 1; return '  ' end,
				{ buffer = 0, expr = true })
		]])
		arm_two_lines()
		local initial_marks = client.lua("return marks(true)")
		assert.equals(2, #initial_marks)
		assert.same({ 0, 2 }, { initial_marks[1][2], initial_marks[2][2] })
		assert.equals("OpenCodeCompletionSpinner", initial_marks[1][4].virt_text[1][2])
		assert.equals("OpenCodeCompletionSpinner", initial_marks[2][4].virt_text[1][2])
		client.update(1, "1")
		local mixed_marks = client.lua("return marks(true)")
		assert.equals("1", mixed_marks[1][4].virt_text[1][1])
		assert.equals("OpenCodeCompletionSpinner", mixed_marks[2][4].virt_text[1][2])
		client.update(2, "2")
		assert.equals("1", client.lua("return marks(true)[1][4].virt_text[1][1]"))
		assert.equals("2", client.lua("return marks(true)[2][4].virt_text[1][1]"))
		client.feed("<Esc>GA<Tab><Cmd>lua _G.indented = true<CR>")
		client.wait("indented == true")
		assert.same({ 2, 1 }, client.lua("return { accepts, fallbacks }"))
		client.respond(2, "2")
		client.feed("<Cmd>lua _G.second_committed = true<CR>")
		client.wait("second_committed == true")
		assert.same({ "alpha = ", "middle", "beta = 2", "after  " }, client.lines())
		assert.equals(1, client.lua("return #marks()"))
		assert.equals(initial_marks[1][1], client.lua("return marks()[1][1]"))
		client.respond(1, "1")
		client.feed("<Cmd>lua _G.first_committed = true<CR>")
		client.wait("first_committed == true")
		assert.same({ "alpha = 1", "middle", "beta = 2", "after  " }, client.lines())
		assert.same({ 4, #"after  " }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)

	it("moves the second completion when a multiline first completion is accepted above it", function()
		arm_two_lines()
		client.update(2, "2")
		client.respond(1, "1\ncontinued")
		client.feed("<Cmd>lua _G.first_committed = true<CR>")
		client.wait("first_committed == true")
		assert.same({ "alpha = 1", "continued", "middle", "beta = ", "after" }, client.lines())
		assert.is_false(client.lua("return requests[2].cancelled == true"))
		assert.equals(1, client.lua("return #marks()"))
		assert.equals(3, client.lua("return marks()[1][2]"))
		assert.same({ 4, #"beta = " }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		client.update(2, "22")
		assert.equals(3, client.lua("return marks()[1][2]"))
		client.respond(2, "22")
		client.feed("<Cmd>lua _G.second_committed = true<CR>")
		client.wait("second_committed == true")
		assert.same({ "alpha = 1", "continued", "middle", "beta = 22", "after" }, client.lines())
		assert.same({ 4, #"beta = 22" }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)

	it("keeps an unarmed second completion when the first completion inserts above it", function()
		client.feed("ialpha = <CR>beta = <Esc>ggA<C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.feed("<Esc>jA<C-l><Cmd>lua _G.second_started = true<CR>")
		client.wait("second_started == true")
		assert.equals(2, client.lua("return #requests"))
		client.respond(1, "1\ncontinued")
		client.feed("<Cmd>lua _G.first_committed = true<CR>")
		client.wait("first_committed == true")
		assert.same({ "alpha = 1", "continued", "beta = " }, client.lines())
		assert.is_false(client.lua("return requests[2].cancelled == true"))
		assert.same({ 3, #"beta = " }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		client.update(2, "2")
		client.respond(2, "2")
		assert.equals(1, client.lua("return #marks()"))
		assert.equals(2, client.lua("return marks()[1][2]"))
		assert.same({ "alpha = 1", "continued", "beta = " }, client.lines())
		client.feed("<Tab><Cmd>lua _G.second_committed = true<CR>")
		client.wait("second_committed == true")
		assert.same({ "alpha = 1", "continued", "beta = 2" }, client.lines())
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)

	for _, case in ipairs({
		{ "editing", "gg0x", { "lpha = ", "middle", "beta = 2", "after" }, 2 },
		{ "deleting", "ggdd", { "middle", "beta = 2", "after" }, 1 },
	}) do
		it("cancels only the first completion after " .. case[1] .. " its target", function()
			arm_two_lines()
			client.feed("<Esc>" .. case[2] .. "<Cmd>lua _G.target_edited = true<CR>")
			client.wait("target_edited == true")
			assert.is_true(client.lua("return requests[1].cancelled == true"))
			assert.is_false(client.lua("return requests[2].cancelled == true"))
			client.update(1, "obsolete")
			client.respond(1, "obsolete")
			client.update(2, "2")
			assert.equals(1, client.lua("return #marks()"))
			assert.equals(case[4], client.lua("return marks()[1][2]"))
			client.respond(2, "2")
			client.feed("<Cmd>lua _G.second_committed = true<CR>")
			client.wait("second_committed == true")
			assert.same(case[3], client.lines())
			assert.equals(0, client.lua("return #marks()"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("regenerates only the completion at the current target while another continues", function()
		arm_two_lines()
		client.update(1, "old")
		client.update(2, "2")
		client.feed("<Esc>ggA<C-l><Tab><Cmd>lua _G.first_restarted = true<CR>")
		client.wait("first_restarted == true")
		assert.equals(3, client.lua("return #requests"))
		assert.is_true(client.lua("return requests[1].cancelled == true"))
		assert.is_false(client.lua("return requests[2].cancelled == true or requests[3].cancelled == true"))
		assert.is_truthy(client.lua([[return requests[3].prompt:find('"previous_suggestion":"old"', 1, true)]]))
		client.update(1, "obsolete")
		client.respond(1, "obsolete")
		assert.equals(2, client.lua("return #marks()"))
		assert.equals("2", client.lua("return marks(true)[2][4].virt_text[1][1]"))
		client.respond(3, "new")
		client.feed("<Cmd>lua _G.first_committed = true<CR>")
		client.wait("first_committed == true")
		assert.equals(1, client.lua("return #marks()"))
		client.respond(2, "2")
		client.feed("<Cmd>lua _G.second_committed = true<CR>")
		client.wait("second_committed == true")
		assert.same({ "alpha = new", "middle", "beta = 2", "after" }, client.lines())
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)

	it("keeps the second completion and preview after the first request fails", function()
		arm_two_lines()
		client.update(2, "2")
		local second_mark = client.lua("return marks()[2][1]")
		client.lua("requests[1].callback({ message = 'Offline' })")
		client.update(1, "obsolete")
		client.respond(1, "obsolete")
		assert.is_false(client.lua("return requests[2].cancelled == true"))
		assert.equals(1, client.lua("return #marks()"))
		assert.equals(second_mark, client.lua("return marks()[1][1]"))
		assert.equals("2", client.lua("return marks(true)[1][4].virt_text[1][1]"))
		assert.equals(1, client.lua("return #notices"))
		assert.is_truthy(client.lua("return notices[1]:find('Offline', 1, true)"))
		client.respond(2, "2")
		client.feed("<Cmd>lua _G.second_committed = true<CR>")
		client.wait("second_committed == true")
		assert.same({ "alpha = ", "middle", "beta = 2", "after" }, client.lines())
		assert.equals(0, client.lua("return #marks()"))
	end)

	it("completes a hidden buffer without changing the active cursor, typing, or undo history", function()
		arm_two_buffers()
		client.feed("<Esc>GA editing<Cmd>lua _G.editing_other = true<CR>")
		client.wait("editing_other == true")
		client.respond(1, "1\ncontinued")
		client.feed("<Cmd>lua _G.first_committed = true<CR>")
		client.wait("first_committed == true")
		assert.is_true(client.lua("return vim.api.nvim_get_current_buf() == other_buffer"))
		assert.same({ "alpha = 1", "continued" }, client.lua("return vim.api.nvim_buf_get_lines(source_buffer, 0, -1, false)"))
		assert.same({ "beta = ", "other editing" }, client.lines())
		assert.same({ 2, #"other editing" }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals("i", client.lua("return vim.api.nvim_get_mode().mode"))
		assert.equals(1, client.lua("return #marks()"))
		assert.is_false(client.lua("return requests[2].cancelled == true"))
		client.feed("!<Esc>u<Cmd>lua _G.other_edit_undone = true<CR>")
		client.wait("other_edit_undone == true")
		assert.same({ "beta = ", "other" }, client.lines())
		client.respond(2, "2")
		client.feed("<Cmd>lua _G.second_committed = true<CR>")
		client.wait("second_committed == true")
		assert.same({ "beta = 2", "other" }, client.lines())
		client.lua("vim.api.nvim_set_current_buf(source_buffer)")
		client.feed("u<Cmd>lua _G.first_undone = true<CR>")
		client.wait("first_undone == true")
		assert.same({ "alpha = " }, client.lines())
		assert.same({ "beta = 2", "other" }, client.lua("return vim.api.nvim_buf_get_lines(other_buffer, 0, -1, false)"))
		assert.same({}, client.lua("return notices"))
	end)

	it("cancels only the request belonging to a wiped hidden buffer", function()
		arm_two_buffers()
		client.lua("vim.api.nvim_buf_delete(source_buffer, { force = true })")
		assert.is_true(client.lua("return requests[1].cancelled == true"))
		assert.is_false(client.lua("return requests[2].cancelled == true"))
		client.update(1, "obsolete")
		client.respond(1, "obsolete")
		client.update(2, "2")
		assert.equals(1, client.lua("return #marks()"))
		assert.equals("2", client.lua("return marks(true)[1][4].virt_text[1][1]"))
		client.respond(2, "2")
		client.feed("<Cmd>lua _G.second_committed = true<CR>")
		client.wait("second_committed == true")
		assert.same({ "beta = 2", "other" }, client.lines())
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)

	for _, case in ipairs({
		{ "part of the target line", "<BS>", { "value =", "after" } },
		{ "the target line contents", "<C-u>", { "", "after" } },
		{ "part of the target line in Normal mode", "x", { "value =", "after" }, true },
		{ "the whole target line", "dd", { "after" }, true },
	}) do
		it("cancels queued acceptance after deleting " .. case[1], function()
			client.lua([[
				_G.original_tab = function() return 'fallback' end
				vim.keymap.set('i', '<Tab>', original_tab, { buffer = 0, expr = true })
			]])
			client.feed("ivalue = ")
			client.wait("vim.api.nvim_get_current_line() == 'value = '")
			client.lua("vim.api.nvim_buf_set_lines(0, 1, 1, false, { 'after' })")
			client.feed("<C-l><Tab>")
			client.wait("#requests == 1 and accepts == 1")
			client.update(1, "4")
			if case[4] then
				client.feed("<Esc>")
				client.wait("vim.api.nvim_get_mode().mode == 'n'")
				assert.is_false(client.lua("return requests[1].cancelled == true"))
			end
			client.feed(case[2])
			client.wait("requests[1].cancelled == true and #marks() == 0")
			client.update(1, "late update")
			client.respond(1, "late final")
			assert.same(case[3], client.lines())
			assert.is_true(client.lua("return vim.fn.maparg('<Tab>', 'i', false, true).callback == original_tab"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	for _, deletion in ipairs({ "x", "dd" }) do
		it("keeps queued acceptance cancelled when undo restores the target after " .. deletion, function()
			client.feed("ivalue = <CR>after<Esc>ggA<C-l><Tab>")
			client.wait("#requests == 1 and accepts == 1")
			client.feed("<Esc>" .. deletion .. "u<Cmd>lua _G.edit_undone = true<CR>")
			client.wait("edit_undone == true")
			assert.same({ "value = ", "after" }, client.lines())
			assert.is_true(client.lua("return requests[1].cancelled == true"))
			client.update(1, "late update")
			client.respond(1, "late final")
			assert.same({ "value = ", "after" }, client.lines())
			assert.equals(0, client.lua("return #marks()"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("allows unrelated edits and row shifts between the final response and queued insertion", function()
		client.feed("ibefore<CR>value = <CR>after<Esc>2GA<C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.feed("<Esc>GA edited")
		client.wait("vim.api.nvim_get_current_line() == 'after edited'")
		client.lua([[
			requests[1].callback(nil, '42')
			vim.api.nvim_buf_set_text(0, 0, 0, 0, 1, { 'B' })
			vim.api.nvim_buf_set_lines(0, 0, 0, false, { 'added' })
		]])
		client.feed("<Cmd>lua _G.commit_checked = true<CR>")
		client.wait("commit_checked == true")
		assert.same({ "added", "Before", "value = 42", "after edited" }, client.lines())
		assert.same({ 4, #"after edited" }, client.lua("return vim.api.nvim_win_get_cursor(0)"))
		assert.equals("i", client.lua("return vim.api.nvim_get_mode().mode"))
		assert.equals(0, client.lua("return #marks()"))
		assert.same({}, client.lua("return notices"))
	end)

	for _, restore in ipairs({ false, true }) do
		it("invalidates a target edit before queued insertion even if restored: " .. tostring(restore), function()
			client.feed("ivalue = <C-l><Tab>")
			client.wait("#requests == 1 and accepts == 1")
			client.lua([[
				requests[1].callback(nil, '42')
				vim.api.nvim_buf_set_text(0, 0, 0, 0, 1, { 'V' })
				if ... then vim.api.nvim_buf_set_text(0, 0, 0, 0, 1, { 'v' }) end
			]], { restore })
			client.feed("<Cmd>lua _G.commit_checked = true<CR>")
			client.wait("commit_checked == true")
			assert.same({ restore and "value = " or "Value = " }, client.lines())
			assert.equals(0, client.lua("return #marks()"))
			assert.same({}, client.lua("return notices"))
		end)
	end

	it("clears queued acceptance on failure without accepting the next request", function()
		client.feed("ivalue = <C-l><Tab>")
		client.wait("#requests == 1 and accepts == 1")
		client.lua("requests[1].callback({ message = 'Offline' })")
		client.wait("#marks() == 0 and #notices == 1")
		client.respond(1, "late")
		assert.same({ "value = " }, client.lines())
		assert.is_true(client.lua("return vim.deep_equal(initial_editor_maps.tab, vim.fn.maparg('<Tab>', 'i', false, true))"))
		client.feed("<C-l>")
		client.wait("#requests == 2")
		client.respond(2, "42")
		client.wait("visible()")
		assert.same({ "value = " }, client.lines())
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
