-- test.lua - Test configuration for opencode.nvim
-- Usage: ./test.sh -u test.lua

-- Set leader key to comma
vim.g.mapleader = ","

-- Load opencode.nvim plugin with full configuration
require("opencode").setup({
	server = {
		host = "localhost",
		port = 9099,
		auto_start = true,
		lazy = true,
	},
	
	chat = {
		layout = "vertical",
		position = "right",
		width = 80,
		input = {
			height = 5,
			prompt = "> ",
		},
	},
	
	lualine = {
		enabled = true,
		mode = "normal",
		show_model = true,
		show_agent = true,
		show_status = true,
		show_message_count = true,
	},
	
	diff = {
		layout = "vertical",
		file_list_width = 30,
	},
	
	keymaps = {
		toggle = "<leader>ot",
		command_palette = "<leader>op",
		show_diff = "<leader>od",
		abort = "<leader>ox",
	},
})

-- Core keymaps
vim.keymap.set("n", "<leader>ot", function()
	require("opencode").toggle()
end, { desc = "Toggle OpenCode chat", noremap = true, silent = true })

vim.keymap.set("n", "<leader>op", function()
	require("opencode").command_palette()
end, { desc = "OpenCode command palette", noremap = true, silent = true })

vim.keymap.set("n", "<leader>od", function()
	require("opencode").show_diff()
end, { desc = "OpenCode diff viewer", noremap = true, silent = true })

vim.keymap.set("n", "<leader>ox", function()
	require("opencode").abort()
end, { desc = "Abort OpenCode request", noremap = true, silent = true })

-- Setup lualine with opencode component (if lualine is installed)
local lualine_ok, lualine = pcall(require, "lualine")
if lualine_ok then
	lualine.setup({
		sections = {
			lualine_x = {
				{
					require("opencode").lualine_component,
					color = function()
						local status = require("opencode").get_status()
						local colors = {
							streaming = "DiagnosticInfo",
							thinking = "DiagnosticWarn",
							idle = "Comment",
							paused = "DiagnosticWarn",
							error = "DiagnosticError",
							disconnected = "Comment",
						}
						return { fg = colors[status.status] or colors.idle }
					end,
				},
			},
		},
	})
end

vim.notify("Test config loaded! Leader is 'comma'", vim.log.levels.INFO)
vim.notify("Keymaps: ,ot=toggle ,op=palette ,od=diff ,ox=abort", vim.log.levels.INFO)
