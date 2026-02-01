-- test.lua - Basic configuration for testing opencode.nvim
-- Usage: ./test.sh -u test.lua

-- Set leader key to comma
vim.g.mapleader = ","

-- Load opencode.nvim plugin
require("opencode").setup({
	server = {
		host = "localhost",
		port = 9099,
	},
	chat = {
		layout = "vertical",
		position = "right",
		width = 80,
	},
})

-- Keymaps
vim.keymap.set("n", "<leader>ot", function()
	require("opencode").toggle()
end, { desc = "Toggle OpenCode chat", noremap = true, silent = true })

vim.notify("Test config loaded! Leader is 'comma', use ,ot to toggle OpenCode", vim.log.levels.INFO)
