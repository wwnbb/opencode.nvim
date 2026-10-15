local function editor(options)
	local client = require("tests.helpers.embedded_editor").new()
	client.request("nvim_ui_attach", { 100, 32, { rgb = true, ext_linegrid = true } })
	client.lua([[
		local options = ...
		require('opencode.state').set_config(require('opencode.config').merge(options or {}))
		_G.events, _G.selected = {}, nil
		_G.ctx = require('opencode.ui.menu').open({
			searchable = true, sort = false, width = 88, refocus_chat = false,
			title = 'Sessions', keymap_scope = 'session_menu',
			items = {
				{ value = 'first', label = 'jr alpha' },
				{ value = 'second', label = 'jr beta' },
				{ value = 'third', label = 'jr gamma' },
			},
			on_select = function(item) selected = item.value end,
			keys = {
				{ action = 'rename', label = 'rename', handler = function(_, item)
					events[#events + 1] = { action = 'rename', value = item.value }
				end },
				{ action = 'delete', label = 'delete', handler = function(_, item)
					events[#events + 1] = { action = 'delete', value = item.value }
				end },
			},
		})
		_G.input_buf, _G.list_buf = ctx.input.bufnr, ctx.popup.bufnr
		_G.query = function() return vim.api.nvim_buf_get_lines(ctx.input.bufnr, 0, 1, false)[1] end
		_G.frame = function() return table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), '\n') end
		_G.current = function() local item = ctx.current(); return item and item.value end
	]], { options or {} })
	function client.wait(expression)
		assert.is_true(vim.wait(1500, function() return client.lua("return " .. expression) end, 5), expression
			.. "\n" .. vim.inspect(client.lua([[return { mode = vim.api.nvim_get_mode().mode,
				lines = vim.api.nvim_buf_get_lines(0, 0, -1, false), cursor = vim.api.nvim_win_get_cursor(0),
				selected = selected, events = events }]])))
	end
	return client
end

describe("searchable menu with real editor input", function()
	local client
	after_each(function() if client then client.close(); client = nil end end)

	it("starts in search, types action letters as a query, and selects with insert navigation", function()
		client = editor()
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		local initial_frame = client.lua("return frame()")
		assert.is_truthy(initial_frame:find("Search:", 1, true))
		assert.is_truthy(initial_frame:find("<CR>:select", 1, true))
		assert.is_truthy(initial_frame:find("<Esc>:actions", 1, true))
		assert.is_nil(initial_frame:find("r:rename", 1, true))
		client.feed("jr")
		client.wait("query() == 'jr' and current() == 'first'")
		assert.same({}, client.lua("return events"))
		client.feed("<Down>")
		client.wait("current() == 'second'")
		client.feed("<C-n>")
		client.wait("current() == 'third'")
		assert.equals("i", client.lua("return vim.api.nvim_get_mode().mode"))
		assert.equals("jr", client.lua("return query()"))
		client.feed("<CR>")
		client.wait("selected == 'third' and not vim.api.nvim_buf_is_valid(input_buf)")
	end)

	it("enters actions with Escape and returns to the preserved query with slash", function()
		client = editor()
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		client.feed("jr")
		client.wait("query() == 'jr' and current() == 'first'")
		client.feed("<Down>")
		client.wait("query() == 'jr' and current() == 'second'")
		client.feed("<Esc>")
		client.wait("vim.api.nvim_get_mode().mode == 'n'")
		assert.is_truthy(client.lua("return frame()"):find("Actions", 1, true))
		assert.is_truthy(client.lua("return frame()"):find("r:rename", 1, true))
		client.feed("rd")
		client.wait("#events == 2")
		assert.same({ { action = "rename", value = "second" }, { action = "delete", value = "second" } },
			client.lua("return events"))
		assert.equals("jr", client.lua("return query()"))
		client.feed("/")
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		assert.equals("jr", client.lua("return query()"))
		assert.is_truthy(client.lua("return frame()"):find("Search:", 1, true))
		client.feed(" ")
		client.wait("query() == 'jr '")
	end)

	it("uses the visible native cursor row for actions and closes on the second Escape", function()
		client = editor()
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		client.feed("<Esc>")
		client.wait("vim.api.nvim_get_mode().mode == 'n'")
		client.feed("G")
		client.wait("current() == 'third'")
		client.feed("r")
		client.wait("#events == 1")
		assert.equals("third", client.lua("return events[1].value"))
		client.feed("<Esc>")
		client.wait("not vim.api.nvim_buf_is_valid(list_buf)")
	end)

	it("uses configured mode keys in real input and in the current mode hints", function()
		client = editor({ menu = { keymaps = { normal_mode = "<C-x>", search = "s" } } })
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		local initial_frame = client.lua("return frame()")
		assert.is_truthy(initial_frame:find("<C-x>:actions", 1, true), initial_frame)
		client.feed("jr")
		client.wait("query() == 'jr'")
		client.feed("<C-x>")
		client.wait("vim.api.nvim_get_mode().mode == 'n' and vim.api.nvim_get_current_buf() == list_buf")
		assert.is_truthy(client.lua("return frame()"):find("s:search", 1, true))
		assert.is_nil(client.lua("return frame()"):find("/:search", 1, true))
		client.feed("s")
		client.wait("vim.api.nvim_get_mode().mode == 'i' and vim.api.nvim_get_current_buf() == input_buf")
		client.feed(" ")
		client.wait("query() == 'jr '")
	end)

	it("uses the cursor row when movement and an action arrive in the same input batch", function()
		client = editor()
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		client.feed("<Esc>Gr")
		client.wait("#events == 1")
		assert.equals("third", client.lua("return events[1].value"))
	end)

	it("leaves insert mode when the result window receives focus before an action", function()
		client = editor()
		client.wait("vim.api.nvim_get_mode().mode == 'i'")
		client.feed("jr")
		client.wait("query() == 'jr'")
		client.lua("vim.api.nvim_set_current_win(ctx.popup.winid)")
		client.wait("vim.api.nvim_get_mode().mode == 'n' and vim.api.nvim_get_current_buf() == list_buf")
		assert.is_truthy(client.lua("return frame()"):find("Actions", 1, true))
		client.feed("Gr")
		client.wait("#events == 1")
		assert.equals("third", client.lua("return events[1].value"))
		assert.equals("jr", client.lua("return query()"))
	end)
end)
