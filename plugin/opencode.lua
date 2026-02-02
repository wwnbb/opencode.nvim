-- opencode.nvim - Neovim frontend for OpenCode AI coding agent
-- Plugin loader

-- Guard against multiple loads
if vim.g.opencode_loaded then
	return
end
vim.g.opencode_loaded = true

-- Create user commands
vim.api.nvim_create_user_command("OpenCode", function()
	require("opencode").open()
end, {
	desc = "Open OpenCode chat window",
})

vim.api.nvim_create_user_command("OpenCodeToggle", function()
	require("opencode").toggle()
end, {
	desc = "Toggle OpenCode chat window",
})

vim.api.nvim_create_user_command("OpenCodeClose", function()
	require("opencode").close()
end, {
	desc = "Close OpenCode chat window",
})

vim.api.nvim_create_user_command("OpenCodeStart", function()
	require("opencode").start()
end, {
	desc = "Start OpenCode server",
})

vim.api.nvim_create_user_command("OpenCodeStop", function()
	require("opencode").stop()
end, {
	desc = "Stop OpenCode server",
})

vim.api.nvim_create_user_command("OpenCodeRestart", function()
	require("opencode").restart()
end, {
	desc = "Restart OpenCode server",
})

vim.api.nvim_create_user_command("OpenCodeLog", function()
	require("opencode.ui.log_viewer").toggle()
end, {
	desc = "Toggle OpenCode log viewer",
})

-- Setup default keymaps (user can override in setup())
-- These will be replaced when user calls setup()
vim.keymap.set("n", "<leader>oo", function()
	require("opencode").toggle()
end, { desc = "Toggle OpenCode", noremap = true, silent = true })

vim.keymap.set("n", "<leader>ol", function()
	require("opencode.ui.log_viewer").toggle()
end, { desc = "Toggle OpenCode logs", noremap = true, silent = true })
