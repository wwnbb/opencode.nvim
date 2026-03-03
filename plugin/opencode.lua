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

vim.api.nvim_create_user_command("OpenCodeAbort", function()
	require("opencode").abort()
end, {
	desc = "Abort/stop current generation",
})

vim.api.nvim_create_user_command("OpenCodeLog", function()
	require("opencode.ui.log_viewer").toggle()
end, {
	desc = "Toggle OpenCode log viewer",
})

vim.api.nvim_create_user_command("OpenCodePalette", function()
	require("opencode").command_palette()
end, {
	desc = "Open OpenCode command palette",
})

local function run_add_line_context_command(send_now, raw_context)
	local context = vim.trim(raw_context or "")
	if context ~= "" then
		require("opencode").add_current_line_to_input({
			context = context,
			send = send_now,
		})
		return
	end

	vim.ui.input({ prompt = "OpenCode context: " }, function(input)
		if input == nil then
			return
		end
		require("opencode").add_current_line_to_input({
			context = vim.trim(input),
			send = send_now,
		})
	end)
end

local function run_add_selection_context_command(send_now, raw_context)
	local context = vim.trim(raw_context or "")
	if context ~= "" then
		require("opencode").add_visual_selection_to_input({
			context = context,
			send = send_now,
		})
		return
	end

	vim.ui.input({ prompt = "OpenCode context: " }, function(input)
		if input == nil then
			return
		end
		require("opencode").add_visual_selection_to_input({
			context = vim.trim(input),
			send = send_now,
		})
	end)
end

vim.api.nvim_create_user_command("OpenCodeAddLine", function()
	require("opencode").add_current_line_to_input({ send = false })
end, {
	desc = "Add current file/line to OpenCode input draft",
})

vim.api.nvim_create_user_command("OpenCodeSendLine", function()
	require("opencode").add_current_line_to_input({ send = true })
end, {
	desc = "Add current file/line to OpenCode input and send immediately",
})

vim.api.nvim_create_user_command("OpenCodeAddLineContext", function(args)
	run_add_line_context_command(false, args.args)
end, {
	nargs = "*",
	desc = "Add current file/line plus extra context to OpenCode input draft",
})

vim.api.nvim_create_user_command("OpenCodeSendLineContext", function(args)
	run_add_line_context_command(true, args.args)
end, {
	nargs = "*",
	desc = "Add current file/line plus context and send immediately",
})

vim.api.nvim_create_user_command("OpenCodeAddSelection", function()
	require("opencode").add_visual_selection_to_input({ send = false })
end, {
	range = true,
	desc = "Add visual selection with file/line range to OpenCode input draft",
})

vim.api.nvim_create_user_command("OpenCodeSendSelection", function()
	require("opencode").add_visual_selection_to_input({ send = true })
end, {
	range = true,
	desc = "Add visual selection with file/line range and send immediately",
})

vim.api.nvim_create_user_command("OpenCodeAddSelectionContext", function(args)
	run_add_selection_context_command(false, args.args)
end, {
	range = true,
	nargs = "*",
	desc = "Add visual selection plus extra context to OpenCode input draft",
})

vim.api.nvim_create_user_command("OpenCodeSendSelectionContext", function(args)
	run_add_selection_context_command(true, args.args)
end, {
	range = true,
	nargs = "*",
	desc = "Add visual selection plus context and send immediately",
})

-- Setup default keymaps (user can override in setup())
-- These will be replaced when user calls setup()
vim.keymap.set("n", "<leader>oo", function()
	require("opencode").toggle()
end, { desc = "Toggle OpenCode", noremap = true, silent = true })

vim.keymap.set("n", "<leader>op", function()
	require("opencode").command_palette()
end, { desc = "OpenCode command palette", noremap = true, silent = true })

vim.keymap.set("n", "<leader>ol", function()
	require("opencode.ui.log_viewer").toggle()
end, { desc = "Toggle OpenCode logs", noremap = true, silent = true })
