-- opencode.nvim - Input keymaps

local M = {}
local app_state = require("opencode.state")
local keymaps = require("opencode.util.keymap")

local function termcodes(keys)
	return vim.api.nvim_replace_termcodes(keys, true, false, true)
end

function M.setup(bufnr, cfg, handlers)
	local map, apply = keymaps.mapper("input", bufnr, cfg.keymaps)
	local keys = keymaps.get("input", cfg.keymaps)
	local queue_send = handlers.send_queue or handlers.send
	local steer_send = handlers.send_steer or handlers.send
	local function steer_key(key) return not keymaps.matches(keys.send_alt, key) end

	local function schedule(handler)
		if not handler then
			return
		end
		local session_id = app_state.get_session().id
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) and app_state.get_session().id == session_id then
				handler()
			end
		end)
	end

	local function autocomplete_visible()
		return handlers.autocomplete_visible and handlers.autocomplete_visible()
	end

	local function confirm_autocomplete()
		if handlers.autocomplete_confirm then
			schedule(handlers.autocomplete_confirm)
		end
		return ""
	end

	local function send_or_confirm(handler)
		return function()
			if autocomplete_visible() then
				return confirm_autocomplete()
			end
			if handlers.command_enter_mode and handlers.command_enter_mode() == "select" then
				schedule(handlers.command_enter_select)
				return ""
			end
			schedule(handler)
			return ""
		end
	end

	local send_options = { expr = true, replace_keycodes = false, aliases = { "autocomplete_confirm", "command_enter" } }
	map("i", "send", send_or_confirm(queue_send), send_options)
	map("n", "send", queue_send)
	map("i", "send_steer", send_or_confirm(steer_send), vim.tbl_extend("force", send_options, { filter = steer_key }))
	map("n", "send_steer", steer_send, { filter = steer_key })
	-- An explicitly retained legacy send_alt binding keeps its queue behavior
	-- even when it shares the new default steer key.
	map("i", "send_alt", send_or_confirm(queue_send), send_options)
	map("n", "send_alt", queue_send)

	map("n", "cancel", handlers.cancel)
	map("i", "cancel", handlers.cancel, { filter = function(key)
		return not keymaps.matches({ "<Esc>", "q" }, key)
	end })

	map("i", "history_prev", function()
		if autocomplete_visible() then
			schedule(handlers.autocomplete_prev)
			return ""
		end
		schedule(handlers.history_prev)
		return ""
	end, { expr = true, replace_keycodes = false, aliases = { "autocomplete_prev" } })
	map("i", "history_next", function()
		if autocomplete_visible() then
			schedule(handlers.autocomplete_next)
			return ""
		end
		schedule(handlers.history_next)
		return ""
	end, { expr = true, replace_keycodes = false, aliases = { "autocomplete_next" } })

	map({ "i", "n" }, "history_search", function() schedule(handlers.history_search) end)

	map("i", "autocomplete_prev", function(key)
		if autocomplete_visible() then
			schedule(handlers.autocomplete_prev)
			return ""
		end
		return termcodes(key)
	end, { expr = true, replace_keycodes = false })
	map("i", "autocomplete_next", function(key)
		if autocomplete_visible() then
			schedule(handlers.autocomplete_next)
			return ""
		end
		return termcodes(key)
	end, { expr = true, replace_keycodes = false })
	map("i", "autocomplete_confirm", function(key)
		if autocomplete_visible() then
			return confirm_autocomplete()
		end
		return termcodes(key)
	end, { expr = true, replace_keycodes = false })
	map("i", "command_enter", function(key)
		if autocomplete_visible() then
			return confirm_autocomplete()
		end
		local command_mode = handlers.command_enter_mode and handlers.command_enter_mode()
		if command_mode == "select" then
			schedule(handlers.command_enter_select)
			return ""
		end
		if command_mode == "submit" then
			schedule(handlers.send)
			return ""
		end
		return termcodes(key)
	end, { expr = true, replace_keycodes = false, aliases = { "autocomplete_confirm" } })

	map({ "i", "n" }, "variant_cycle", handlers.cycle_variant)
	map({ "i", "n" }, "agent_cycle", handlers.cycle_agent)
	map({ "i", "n" }, "model_cycle", handlers.cycle_model)
	map({ "i", "n" }, "toggle_mode", handlers.toggle_mode)
	if handlers.fold then
		for action, command in pairs({ fold_toggle = "za", fold_open = "zo", fold_close = "zc",
			fold_open_all = "zR", fold_close_all = "zM" }) do
			map("n", action, function() handlers.fold(command) end)
		end
	end
	apply()
end

return M
