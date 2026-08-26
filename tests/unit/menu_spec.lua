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

		vim.api.nvim_buf_set_lines(ctx.input.bufnr, 0, 1, false, { "ollama-cloud kimi" })
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = ctx.input.bufnr })

		local lines = vim.api.nvim_buf_get_lines(ctx.popup.bufnr, 0, -1, false)
		assert(#lines == 1, "only the matching model should remain")
		assert(lines[1]:find("%[ollama%-cloud%] kimi%-k3"), "provider and model terms should match together")

		ctx.close()
	end)
end)
