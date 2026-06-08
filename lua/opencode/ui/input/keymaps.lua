-- opencode.nvim - Input keymaps

local M = {}

local function map(bufnr, modes, lhs, rhs, opts)
	if not lhs or lhs == "" or not rhs then
		return
	end

	vim.keymap.set(modes, lhs, rhs, vim.tbl_extend("force", {
		buffer = bufnr,
		noremap = true,
		silent = true,
	}, opts or {}))
end

local function is_escape_key(lhs)
	return type(lhs) == "string" and lhs:lower() == "<esc>"
end

local function is_key(lhs, rhs)
	return type(lhs) == "string" and type(rhs) == "string" and lhs:lower() == rhs:lower()
end

local function termcodes(keys)
	return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

function M.setup(bufnr, cfg, handlers)
	local keys = cfg.keymaps or {}
	local function cancel()
		if handlers.mention_close and handlers.mention_close() then
			return
		end
		handlers.cancel()
	end

	map(bufnr, "i", keys.send, handlers.send)
	map(bufnr, "n", keys.send, handlers.send)
	map(bufnr, "i", keys.send_alt, handlers.send)
	map(bufnr, "n", keys.send_alt, handlers.send)

	map(bufnr, "n", keys.cancel, cancel)
	if not is_escape_key(keys.cancel) then
		map(bufnr, "i", keys.cancel, cancel)
	end
	map(bufnr, "n", "q", cancel)
	map(bufnr, { "i", "n" }, "<C-c>", cancel)

	map(bufnr, "i", keys.history_prev, function()
		if handlers.mention_prev and handlers.mention_prev() then
			return
		end
		handlers.history_prev()
	end)
	map(bufnr, "i", keys.history_next, function()
		if handlers.mention_next and handlers.mention_next() then
			return
		end
		handlers.history_next()
	end)

	map(bufnr, "i", "<Tab>", function()
		if handlers.mention_select and handlers.mention_select() then
			return ""
		end
		return termcodes("<Tab>")
	end, { expr = true, replace_keycodes = false })

	map(bufnr, "i", "<CR>", function()
		if handlers.mention_select and handlers.mention_select() then
			return ""
		end
		if is_key(keys.send, "<CR>") or is_key(keys.send_alt, "<CR>") then
			handlers.send()
			return ""
		end
		return termcodes("<CR>")
	end, { expr = true, replace_keycodes = false })

	map(bufnr, { "i", "n" }, keys.paste, handlers.paste)
	map(bufnr, { "i", "n" }, keys.stash, handlers.stash)
	map(bufnr, { "i", "n" }, keys.restore, handlers.restore)

	map(bufnr, { "i", "n" }, keys.variant_cycle, handlers.cycle_variant)
	map(bufnr, { "i", "n" }, keys.agent_cycle, handlers.cycle_agent)
	map(bufnr, { "i", "n" }, keys.model_cycle, handlers.cycle_model)
end

return M
