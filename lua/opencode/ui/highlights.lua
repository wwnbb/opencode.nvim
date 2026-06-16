-- opencode.nvim - Shared UI highlight defaults

local M = {}

function M.setup_message_backgrounds()
	vim.api.nvim_set_hl(0, "OpenCodeUserMessageBg", { link = "CursorLine", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "OpenCodeUserMessageBg", default = true })
end

return M
