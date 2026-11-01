-- opencode.nvim - Shared UI highlight defaults

local M = {}

-- Render modules register their highlight setups here once (at require time).
-- Setups run immediately on registration and are re-run on colorscheme changes,
-- so render paths no longer call nvim_set_hl on every frame.
local registered = {}

function M.setup_message_backgrounds()
	vim.api.nvim_set_hl(0, "OpenCodeUserMessageBg", { link = "CursorLine", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeInputBg", { link = "OpenCodeUserMessageBg", default = true })
	-- Prompts not yet delivered (pending steers, the queue dock) use a neutral border.
	vim.api.nvim_set_hl(0, "OpenCodePendingPromptBorder", { link = "NonText", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeQueueDockMuted", { link = "Comment", default = true })
end

-- Cursor groups a window maps to OpenCodeHiddenCursor to hide its cursor.
M.HIDDEN_CURSOR_WINHIGHLIGHT =
	"Cursor:OpenCodeHiddenCursor,lCursor:OpenCodeHiddenCursor,CursorLine:OpenCodeHiddenCursor,CursorColumn:OpenCodeHiddenCursor"

-- blend only hides the background; matching Normal's background also hides the cursor foreground.
function M.setup_hidden_cursor()
	local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal" })
	local bg = normal_hl.bg or 0x000000
	vim.api.nvim_set_hl(0, "OpenCodeHiddenCursor", {
		fg = bg,
		bg = bg,
		blend = 100,
		nocombine = true,
	})
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
