-- opencode.nvim - Input keymaps

local M = {}

local function map(bufnr, modes, lhs, rhs)
	if not lhs or lhs == "" or not rhs then
		return
	end

	vim.keymap.set(modes, lhs, rhs, {
		buffer = bufnr,
		noremap = true,
		silent = true,
	})
end

local function is_escape_key(lhs)
	return type(lhs) == "string" and lhs:lower() == "<esc>"
end

function M.setup(bufnr, cfg, handlers)
	local keys = cfg.keymaps or {}

	map(bufnr, "i", keys.send, handlers.send)
	map(bufnr, "n", keys.send, handlers.send)
	map(bufnr, "i", keys.send_alt, handlers.send)
	map(bufnr, "n", keys.send_alt, handlers.send)

	map(bufnr, "n", keys.cancel, handlers.cancel)
	if not is_escape_key(keys.cancel) then
		map(bufnr, "i", keys.cancel, handlers.cancel)
	end
	map(bufnr, "n", "q", handlers.cancel)
	map(bufnr, { "i", "n" }, "<C-c>", handlers.cancel)

	map(bufnr, "i", keys.history_prev, handlers.history_prev)
	map(bufnr, "i", keys.history_next, handlers.history_next)

	map(bufnr, { "i", "n" }, keys.paste, handlers.paste)
	map(bufnr, { "i", "n" }, keys.stash, handlers.stash)
	map(bufnr, { "i", "n" }, keys.restore, handlers.restore)

	map(bufnr, { "i", "n" }, keys.variant_cycle, handlers.cycle_variant)
	map(bufnr, { "i", "n" }, keys.agent_cycle, handlers.cycle_agent)
	map(bufnr, { "i", "n" }, keys.model_cycle, handlers.cycle_model)
end

return M
