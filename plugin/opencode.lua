if vim.g.opencode_loaded then
	return
end
vim.g.opencode_loaded = true

require("opencode.commands").setup()
