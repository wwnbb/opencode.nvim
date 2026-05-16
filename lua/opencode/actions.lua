-- opencode.nvim - Internal action boundary.
-- UI modules and command declarations call this module instead of reaching
-- directly through the public API. The public API remains source-compatible.

local M = {}

local function api()
	return require("opencode")
end

function M.open()
	return api().open()
end

function M.toggle()
	return api().toggle()
end

function M.close()
	return api().close()
end

function M.focus()
	return api().focus()
end

function M.focus_input()
	return api().focus_input()
end

function M.start()
	return api().start()
end

function M.stop()
	return api().stop()
end

function M.restart()
	return api().restart()
end

function M.abort()
	return api().abort()
end

function M.clear(opts)
	return api().clear(opts)
end

function M.send(message, opts)
	return api().send(message, opts)
end

function M.paste_clipboard()
	return api().paste_clipboard()
end

function M.command_palette()
	return api().command_palette()
end

function M.toggle_logs()
	return require("opencode.ui.log_viewer").toggle()
end

function M.open_logs()
	return require("opencode.ui.log_viewer").open()
end

function M.close_logs()
	return require("opencode.ui.log_viewer").close()
end

function M.add_current_line_to_input(opts)
	return api().add_current_line_to_input(opts)
end

function M.add_visual_selection_to_input(opts)
	return api().add_visual_selection_to_input(opts)
end

function M.trigger_palette(id)
	return require("opencode.ui.palette").trigger(id)
end

return M
