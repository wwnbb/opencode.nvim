-- opencode.nvim - System palette commands

local M = {}

local actions = require("opencode.actions")
local state = require("opencode.state")
function M.register(palette)
	palette.register({
		id = "system.restart",
		title = "Restart Server",
		description = "Restart the OpenCode server",
		category = "system",
		action = function()
			actions.restart()
		end,
	})
	palette.register({
		id = "system.disconnect",
		title = "Disconnect",
		description = "Disconnect from server (keep running)",
		category = "system",
		action = function()
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
			action = function()
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
		action = function()
			actions.toggle_logs()
		end,
	})
	palette.register({
		id = "system.help",
		title = "Help",
		description = "Show keybinding help",
		category = "system",
		keybind = "?",
		action = function()
			local chat_ok, chat = pcall(require, "opencode.ui.chat")
			if chat_ok and chat.show_help then
				chat.show_help()
			else
				-- Fallback: show basic help
				local lines = {
					" OpenCode Keymaps ",
					"",
					" <leader>oo - Toggle chat",
					" <leader>op - Command palette",
					" <leader>od - Show diff",
					" <leader>ox - Abort request",
					"",
					" In chat:",
					"   i - Focus input",
					"   q - Close chat",
					"   ? - This help",
					"",
					" In input:",
					"   <C-g> - Send",
					"   <Esc> - Cancel",
					"   ↑/↓ - History",
				}
				vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
			end
		end,
	})
end

return M
