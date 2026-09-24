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
	},

	session = {
		default_model = {
			providerID = "github-copilot",
			modelID = "gpt-5-mini",
		},
	},

	chat = {
		layout = "float",
		float = {
			width = 0.9,
			height = 0.9,
			border = "rounded",
			title = " OpenCode ",
			title_pos = "center",
		},
	},

	lualine = {
		enabled = true,
		show_attention = true,
		attention_icon = "◈",
		show_diff_stats = true,
	},

	keymaps = {
		toggle = "<leader>ot",
		command_palette = "<leader>op",
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
vim.notify("Keymaps: ,ot=toggle ,op=palette ,ox=abort", vim.log.levels.INFO)
