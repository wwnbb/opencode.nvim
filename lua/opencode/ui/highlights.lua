-- opencode.nvim - Shared UI highlight defaults

local M = {}

-- Render modules register their highlight setups here once (at require time).
-- Setups run immediately on registration and are re-run on colorscheme changes,
-- so render paths no longer call nvim_set_hl on every frame.
local registered = {}

function M.setup_message_backgrounds()
	vim.api.nvim_set_hl(0, "OpenCodeUserMessageBg", { link = "CursorLine", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "OpenCodeUserMessageBg", default = true })
end

---Register a widget highlight setup. Runs it now and re-runs it on ColorScheme.
---Idempotent: re-registering the same function is a no-op.
---@param owner string Unique key, e.g. "opencode.ui.chat.bash"
---@param setup fun()
function M.register(owner, setup)
	if registered[owner] == setup then
		return
	end
	registered[owner] = setup
	setup()
end

---Re-run all registered highlight setups (after colorscheme or config changes).
function M.refresh()
	for _, setup in pairs(registered) do
		setup()
	end
end

vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("OpenCodeWidgetHighlights", { clear = true }),
	callback = M.refresh,
	desc = "Re-apply OpenCode widget highlight setups after colorscheme change",
})

return M
