local function press(ctx, key, mode)
	local bufnr = ctx.input and ctx.input.bufnr or ctx.popup.bufnr
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode or "n")) do
		if mapping.lhs == key then
			assert(type(mapping.callback) == "function", "missing callback for " .. key)
			return mapping.callback()
		end
	end
	error("missing menu mapping " .. key)
end

local function search(ctx, query)
	vim.api.nvim_buf_set_lines(ctx.input.bufnr, 0, 1, false, { query })
	vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ctx.input.bufnr })
end

describe("opencode searchable menu", function()

	it("matches all query terms while preserving Unicode, punctuation and case folding", function()
		local ctx = require("opencode.ui.menu").open({
			searchable = true, refocus_chat = false, sort = false,
			items = {
				{ label = "Обзор кода", value = "review" },
				{ label = "[ollama-cloud] kimi-k3", value = "kimi" },
				{ label = "猫の説明", value = "cat" },
				{ label = "犬の説明", value = "dog" },
				{ label = "🐈 pet", value = "emoji" },
				{ label = ".env.example", value = "hidden" },
				{ label = "env.example", value = "plain" },
				{ label = "Alias", description = "ПРОВЕРКА", value = "desc" },
				{ label = "Provider", value = "МОДЕЛЬ", key = "КЛЮЧ" },
			},
		})
		local ok, err = pcall(function()
			for _, case in ipairs({
				{ "Обзор", "review" }, { "ОБЗОР", "review" }, { "  обзор кода  ", "review" },
				{ "ollama-cloud kimi", "kimi" }, { "猫", "cat" }, { "🐈", "emoji" }, { ".env", "hidden" },
				{ "проверка", "desc" }, { "модель", "МОДЕЛЬ" }, { "ключ", "МОДЕЛЬ" },
			}) do
				vim.api.nvim_buf_set_lines(ctx.input.bufnr, 0, 1, false, { case[1] })
				vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ctx.input.bufnr })
				assert.equals(1, vim.api.nvim_buf_line_count(ctx.popup.bufnr), case[1])
				assert.equals(case[2], ctx.current().value, case[1])
			end
		end)
		ctx.close()
		if not ok then error(err) end
	end)

end)

describe("Switch Session popup border", function()
	local config = require("opencode.config")
	local state = require("opencode.state")
	local old_config, old_columns, old_lines, old_win
	local ctx

	before_each(function()
		old_config = state.get_config()
		old_columns, old_lines = vim.o.columns, vim.o.lines
		old_win = vim.api.nvim_get_current_win()
		state.set_config(config.merge({ popup = { border = "rounded" } }))
	end)

	after_each(function()
		if ctx then ctx.close() end
		ctx = nil
		state.set_config(old_config)
		vim.o.columns, vim.o.lines = old_columns, old_lines
		if vim.api.nvim_win_is_valid(old_win) then vim.api.nvim_set_current_win(old_win) end
	end)

	local function assert_outer_border(searchable)
		assert.equals("rounded", ctx.frame.border._.style)
		assert.equals("╭", vim.api.nvim_win_get_config(ctx.frame.winid).border[1][1])
		assert.equals("none", vim.api.nvim_win_get_config(ctx.popup.winid).border)
		assert.equals(ctx.frame.winid, vim.api.nvim_win_get_config(ctx.popup.winid).win)
		if searchable then
			assert.equals("none", vim.api.nvim_win_get_config(ctx.input.winid).border)
			assert.equals(ctx.frame.winid, vim.api.nvim_win_get_config(ctx.input.winid).win)
		else
			assert.is_nil(ctx.input)
		end
	end

	it("keeps search, selection, and resize inside one framed window", function()
		local selected
		vim.o.columns, vim.o.lines = 52, 22
		ctx = require("opencode.ui.menu").open({
			title = " Switch Session ", searchable = true, refocus_chat = false, sort = false,
			items = { "First session", "Review session", "Third session" },
			on_select = function(item) selected = item end,
		})
		assert_outer_border(true)
		search(ctx, "Review")
		assert.equals("Review session", ctx.current())
		vim.o.columns, vim.o.lines = 38, 17
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert_outer_border(true)
		local frame = vim.api.nvim_win_get_config(ctx.frame.winid)
		local list = vim.api.nvim_win_get_config(ctx.popup.winid)
		local input = vim.api.nvim_win_get_config(ctx.input.winid)
		assert.is_true(frame.row >= 0 and frame.row + frame.height + 2 <= vim.o.lines - vim.o.cmdheight)
		assert.is_true(frame.col >= 0 and frame.col + frame.width + 2 <= vim.o.columns)
		assert.is_true(list.row + list.height <= frame.height)
		assert.is_true(input.row + input.height <= frame.height)
		local frame_win, list_win, input_win = ctx.frame.winid, ctx.popup.winid, ctx.input.winid
		press(ctx, "<CR>", "i")
		assert.equals("Review session", selected)
		for _, winid in ipairs({ frame_win, list_win, input_win }) do
			assert.is_false(vim.api.nvim_win_is_valid(winid))
		end
	end)

	it("keeps a plain selector borderless and cancels ordered confirmation without selecting", function()
		local selected
		ctx = require("opencode.ui.menu").open({
			title = " Delete session? ", searchable = false, refocus_chat = false, sort = false,
			items = { "Delete", "Cancel" },
			on_select = function(item) selected = item end,
		})
		assert_outer_border(false)
		assert.equals("Delete", ctx.current())
		local frame_win, list_win = ctx.frame.winid, ctx.popup.winid
		press(ctx, "<Esc>")
		ctx.close()
		assert.is_nil(selected)
		assert.is_false(vim.api.nvim_win_is_valid(frame_win))
		assert.is_false(vim.api.nvim_win_is_valid(list_win))
	end)
end)

describe("opencode selector interactions", function()
	it("notifies the highlighted item while moving and narrowing a searchable list", function()
		local moved = {}
		local ctx = require("opencode.ui.menu").open({
			items = { "First", "Second", "Third" }, searchable = true, sort = false,
			refocus_chat = false,
			on_move = function(item) moved[#moved + 1] = item end,
		})
		press(ctx, "<Down>")
		assert.same({ "Second" }, moved)
		search(ctx, "Third")
		assert.same({ "Second", "Third" }, moved)
		ctx.close()
	end)

	it("fires the opener's BufLeave when the search field gains focus", function()
		local opener = vim.api.nvim_get_current_win()
		local left = 0
		local leave_id = vim.api.nvim_create_autocmd("BufLeave", {
			buffer = vim.api.nvim_get_current_buf(),
			callback = function()
				left = left + 1
			end,
		})
		local ctx = require("opencode.ui.menu").open({
			items = { "Review" },
			searchable = true,
			refocus_chat = false,
		})
		local focused = vim.api.nvim_get_current_win()
		local input_win = ctx.input.winid
		ctx.close()
		vim.api.nvim_del_autocmd(leave_id)
		assert.equals(input_win, focused)
		assert.equals(1, left)
		assert(vim.api.nvim_win_is_valid(opener))
	end)

	it("dispatches actions for the visible search result", function()
		local action_item, selected_item
		local ctx = require("opencode.ui.menu").open({
			title = " Select Agent ",
			searchable = true,
			refocus_chat = false,
			sort = false,
			items = {
				{ label = "Build", key = "build", description = "local" },
				{ label = "Review", key = "remote-review", description = "remote" },
				{ label = "Explore", key = "remote-explore", description = "remote" },
			},
			keys = {
				{ key = "x", label = "x:inspect", handler = function(_, item)
					action_item = item.key
				end },
			},
			on_select = function(item)
				selected_item = item.key
			end,
		})
		vim.wait(20)
		search(ctx, "remote")
		assert(ctx.current().key == "remote-review")
		press(ctx, "<Down>")
		assert(ctx.current().key == "remote-explore")
		press(ctx, "x")
		assert(action_item == "remote-explore")
		local winid = ctx.popup.winid
		press(ctx, "<CR>", "i")
		assert(selected_item == "remote-explore")
		assert(not vim.api.nvim_win_is_valid(winid))
	end)

	it("shows a complete confirmation message after narrowing and resizing", function()
		local previous_columns, previous_lines = vim.o.columns, vim.o.lines
		local ctx
		local selected
		local message = "Reload cancels pending forms, permissions and plugin reviews in every project."
		local ok, err = pcall(function()
			vim.o.columns, vim.o.lines = 50, 30
			local options = {
				title = "Reload Server Configuration",
				message = message,
				items = { "Reload all locations", "Cancel" },
				sort = false,
				refocus_chat = false,
				on_select = function(item) selected = item end,
			}
			ctx = require("opencode.ui.menu").open(options)
			local function assert_message_visible()
				local frame_lines = vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false)
				local text = table.concat(frame_lines, " "):gsub("%s+", " ")
				assert.is_truthy(text:find(message, 1, true))
				local frame_config = vim.api.nvim_win_get_config(ctx.frame.winid)
				assert.is_true(frame_config.row + frame_config.height <= vim.o.lines - vim.o.cmdheight)
				assert.is_true(vim.api.nvim_win_get_config(ctx.popup.winid).row > 3)
			end
			assert_message_visible()
			vim.o.columns = 38
			vim.api.nvim_exec_autocmds("VimResized", {})
			assert_message_visible()
			assert.equals("Reload all locations", ctx.current())
			press(ctx, "<Down>")
			assert.equals("Cancel", ctx.current())
			local frame_win = ctx.frame.winid
			press(ctx, "<Esc>")
			assert.is_nil(selected)
			assert.is_false(vim.api.nvim_win_is_valid(frame_win))
			ctx = require("opencode.ui.menu").open(options)
			press(ctx, "<CR>")
			assert.equals("Reload all locations", selected)
		end)
		if ctx then ctx.close() end
		vim.o.columns, vim.o.lines = previous_columns, previous_lines
		if not ok then error(err) end
	end)

	it("cleans up its frame when the list window is closed externally", function()
		local ctx = require("opencode.ui.menu").open({
			items = { "First", "Second" },
			refocus_chat = false,
		})
		local frame_win = ctx.frame.winid
		vim.api.nvim_win_close(ctx.popup.winid, true)
		ctx.refresh()
		ctx.close()
		assert(not vim.api.nvim_win_is_valid(frame_win))
	end)

	it("keeps a confirmation open when selected from a searchable menu", function()
		local confirmation
		local ctx = require("opencode.ui.menu").open({
			items = { "Disconnect" }, searchable = true, refocus_chat = false,
			on_select = function()
				confirmation = require("opencode.ui.menu").open({
					items = { "Disconnect", "Cancel" }, sort = false, refocus_chat = false,
				})
			end,
		})
		search(ctx, "Disconnect")
		press(ctx, "<CR>")
		assert.is_not_nil(confirmation)
		assert.is_true(vim.api.nvim_win_is_valid(confirmation.popup.winid))
		vim.wait(50)
		assert.is_true(vim.api.nvim_win_is_valid(confirmation.popup.winid))
		confirmation.close()
	end)

	it("preserves the current item when a custom action reorders the list", function()
		local selected
		local ctx = require("opencode.ui.menu").open({
			title = " Select Model ",
			searchable = true,
			refocus_chat = false,
			items = { { label = "Alpha", key = "a" }, { label = "Beta", key = "b" } },
			close_on_select = false,
			on_select = function(item)
				selected = item.key
			end,
			keys = {
				{
					key = "f",
					label = "f:favorite",
					handler = function(_, item)
						item.priority = 10
					end,
				},
			},
		})
		vim.wait(20)
		press(ctx, "<Down>")
		assert(ctx.current().key == "b")
		press(ctx, "f")
		local item, index = ctx.current()
		assert(item.key == "b" and index == 1, "favorite must stay selected after sorting")
		press(ctx, "<CR>")
		assert(selected == "b" and vim.api.nvim_win_is_valid(ctx.popup.winid))
		ctx.close()
		vim.wait(120)
	end)

	it("keeps multiple selections across searches and returns original item order", function()
		local selected
		local ctx = require("opencode.ui.menu").open({
			searchable = true,
			multi_select = true,
			refocus_chat = false,
			items = { { label = "Beta", key = "b" }, { label = "Alpha", key = "a" } },
			on_select = function(items)
				selected = items
			end,
		})
		vim.wait(20)
		press(ctx, "<Tab>", "i")
		search(ctx, "Beta")
		press(ctx, "<Tab>", "i")
		search(ctx, "no match")
		press(ctx, "<CR>")
		assert(selected == nil, "empty results must not confirm")
		search(ctx, "")
		local wins = { ctx.popup.winid, ctx.input.winid, ctx.frame.winid }
		press(ctx, "<CR>")
		assert(#selected == 2 and selected[1].key == "b" and selected[2].key == "a")
		for _, win in ipairs(wins) do
			assert(not vim.api.nvim_win_is_valid(win), "selector leaked a window")
		end
		vim.wait(120)
	end)

	it("uses the same multi-selection payload for a number as for Enter", function()
		local selected
		local ctx = require("opencode.ui.menu").open({
			multi_select = true, sort = false, refocus_chat = false,
			items = { { label = "First", value = "a" }, { label = "Second", value = "b" } },
			on_select = function(items) selected = items end,
		})
		local winid = ctx.popup.winid
		local ok, err = pcall(function()
			press(ctx, "2")
			assert.same({ { label = "Second", value = "b" } }, selected)
			assert.is_false(vim.api.nvim_win_is_valid(winid))
		end)
		ctx.close()
		if not ok then error(err) end
	end)

	it("preserves numeric selection, custom order, and refresh for plain selectors", function()
		local selected
		local ctx = require("opencode.ui.menu").open({
			title = " Active Sessions ",
			width = 32,
			refocus_chat = false,
			sort = false,
			items = { { label = "Zulu", value = "z" }, { label = "Alpha", value = "a" } },
			close_on_select = false,
			on_select = function(item)
				selected = item.value
			end,
			keys = { { key = "x", label = "x:close-tab", handler = function() end } },
		})
		press(ctx, "2")
		assert(selected == "a" and vim.api.nvim_win_is_valid(ctx.popup.winid))
		assert.equals("a", ctx.current().value)
		assert.equals(2, vim.api.nvim_win_get_cursor(ctx.popup.winid)[1])
		ctx.close()
		vim.wait(120)
	end)
end)
