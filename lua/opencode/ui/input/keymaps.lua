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

local function termcodes(keys)
	return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

function M.setup(bufnr, cfg, handlers)
	local keys = cfg.keymaps or {}

	local function schedule(handler)
		if not handler then
			return
		end
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				handler()
			end
		end)
	end

	local function autocomplete_visible()
		return handlers.autocomplete_visible and handlers.autocomplete_visible()
	end

	local function confirm_autocomplete()
		schedule(handlers.autocomplete_confirm)
		return ""
	end

	local function send_or_confirm()
		if autocomplete_visible() then
			return confirm_autocomplete()
		end
		schedule(handlers.send)
		return ""
	end

	map(bufnr, "i", keys.send, send_or_confirm, { expr = true, replace_keycodes = false })
	map(bufnr, "n", keys.send, handlers.send)
	map(bufnr, "i", keys.send_alt, send_or_confirm, { expr = true, replace_keycodes = false })
	map(bufnr, "n", keys.send_alt, handlers.send)

	map(bufnr, "n", keys.cancel, handlers.cancel)
	if not is_escape_key(keys.cancel) then
		map(bufnr, "i", keys.cancel, handlers.cancel)
	end
	map(bufnr, "n", "q", handlers.cancel)
	map(bufnr, { "i", "n" }, "<C-c>", handlers.cancel)

	map(bufnr, "i", keys.history_prev, function()
		if autocomplete_visible() then
			schedule(handlers.autocomplete_prev)
			return ""
		end
		schedule(handlers.history_prev)
		return ""
	end, { expr = true, replace_keycodes = false })
	map(bufnr, "i", keys.history_next, function()
		if autocomplete_visible() then
			schedule(handlers.autocomplete_next)
			return ""
		end
		schedule(handlers.history_next)
		return ""
	end, { expr = true, replace_keycodes = false })

	map(bufnr, "i", "<C-p>", function()
		if autocomplete_visible() then
			schedule(handlers.autocomplete_prev)
			return ""
		end
		return termcodes("<C-p>")
	end, { expr = true, replace_keycodes = false })
	map(bufnr, "i", "<C-n>", function()
		if autocomplete_visible() then
			schedule(handlers.autocomplete_next)
			return ""
		end
		return termcodes("<C-n>")
	end, { expr = true, replace_keycodes = false })
	map(bufnr, "i", "<Tab>", function()
		if autocomplete_visible() then
			return confirm_autocomplete()
		end
		return termcodes("<Tab>")
	end, { expr = true, replace_keycodes = false })
	map(bufnr, "i", "<S-Tab>", function()
		if autocomplete_visible() then
			schedule(handlers.autocomplete_prev)
			return ""
		end
		return termcodes("<S-Tab>")
	end, { expr = true, replace_keycodes = false })
	map(bufnr, "i", "<CR>", function()
		if autocomplete_visible() then
			return confirm_autocomplete()
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
