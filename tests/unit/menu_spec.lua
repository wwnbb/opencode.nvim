-- Regression tests for the shared searchable menu.
-- Run with: ./tests/run.sh tests/unit/menu_spec.lua

describe("opencode searchable menu", function()
	it("matches every whitespace-separated query term", function()
		local menu = require("opencode.ui.menu")
		local ctx = menu.open({
			items = {
				{
					label = "[ollama-cloud] kimi-k3",
					value = "kimi-k3",
					key = "ollama-cloud/kimi-k3",
				},
				{
					label = "[openai] gpt-5",
					value = "gpt-5",
					key = "openai/gpt-5",
				},
			},
			searchable = true,
			list_height = 2,
			refocus_chat = false,
		})

		vim.wait(20)
		vim.api.nvim_buf_set_lines(ctx.input.bufnr, 0, 1, false, { "ollama-cloud kimi" })
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ctx.input.bufnr })

		local lines = vim.api.nvim_buf_get_lines(ctx.popup.bufnr, 0, -1, false)
		assert(#lines == 1, "only the matching model should remain")
		assert(lines[1]:find("%[ollama%-cloud%] kimi%-k3"), "provider and model terms should match together")

		ctx.close()
	end)
end)

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

describe("opencode selector interactions", function()
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
		ctx.close()
		vim.wait(120)
	end)
end)
