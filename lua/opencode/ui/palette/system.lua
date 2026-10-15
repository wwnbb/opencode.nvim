-- opencode.nvim - System palette commands

local M = {}
local bindings = require("opencode.util.keymap")

local actions = require("opencode.actions")
local state = require("opencode.state")
local pending = require("opencode.session.pending")
function M.register(palette)
	local keymaps = (state.get_config() or require("opencode.config").defaults).keymaps or {}
	palette.register({ id = "system.reload", title = "Reload Server Configuration", category = "system",
		description = "Reload all locations and cancel pending interactions", run = function()
			local token = pending.token()
			local prompt = "Reload cancels pending forms, permissions and plugin reviews in every project."
			require("opencode.ui.menu").open({
				items = { "Reload all locations", "Cancel" },
				title = "Reload Server Configuration",
				message = prompt,
				width = vim.fn.strdisplaywidth(prompt) + 12,
				sort = false,
				on_select = function(choice)
					if choice ~= "Reload all locations" or not pending.is_current(token) then return end
					actions.reload_locations(function(err)
						vim.notify(err and ("Reload was not confirmed: " .. err.message) or "Server configuration reloaded", err and vim.log.levels.ERROR or vim.log.levels.INFO)
					end)
				end,
			})
		end })

	palette.register({
		id = "system.restart",
		title = "Restart Server",
		description = "Restart the OpenCode server",
		category = "system",
		run = function()
			actions.restart()
		end,
	})
	palette.register({
		id = "system.disconnect",
		title = "Disconnect",
		description = "Disconnect from server (keep running)",
		category = "system",
		run = function()
			actions.disconnect()
			vim.notify("Disconnected from OpenCode server", vim.log.levels.INFO)
		end,
		enabled = function()
			return state.is_connected()
		end,
	})
	palette.register({
		id = "system.reconnect",
			title = "Reconnect",
		description = "Reconnect to the OpenCode server",
		category = "system",
			run = function()
				actions.reconnect(function()
					vim.notify("Reconnected to OpenCode server", vim.log.levels.INFO)
				end)
			end,
		enabled = function()
			return not state.is_connected()
		end,
	})
	palette.register({
		id = "system.logs",
		title = "View Logs",
		description = "Open the log viewer",
		category = "system",
		keybind = keymaps.toggle_logs,
		run = function()
			actions.toggle_logs()
		end,
	})
	palette.register({
		id = "system.help",
		title = "Help",
		description = "Show keybinding help",
		category = "system",
		keybind = bindings.get("chat").help,
		run = function()
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.show_help then
				chat.show_help()
			else
				-- Fallback: show basic help
				local function hint(scope, action, description)
					return " " .. bindings.label(scope, action) .. " - " .. description
				end
				local lines = {
					" OpenCode Keymaps ", "",
					hint("global", "toggle", "Toggle chat"),
					hint("global", "command_palette", "Command palette"),
					hint("global", "abort", "Abort request"),
					"", " In chat:",
					hint("chat", "focus_input", "Focus input"),
					hint("chat", "close", "Close chat"),
					hint("chat", "help", "This help"),
					"", " In input:",
					hint("input", "send", "Queue message"),
					hint("input", "send_steer", "Steer active agent"),
					hint("input", "cancel", "Cancel"),
					hint("input", "history_prev", "Previous history"),
					hint("input", "history_next", "Next history"),
					hint("input", "history_search", "Search prompt history"),
				}
				vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
			end
		end,
	})
end

return M
