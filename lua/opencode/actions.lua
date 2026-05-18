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

function M.open_input_at_end(opts)
	return api().open_input_at_end(opts)
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

function M.set_danger_mode(enabled, opts)
	return api().set_danger_mode(enabled, opts)
end

function M.enable_danger_mode(opts)
	return api().enable_danger_mode(opts)
end

function M.disable_danger_mode(opts)
	return api().disable_danger_mode(opts)
end

function M.toggle_danger_mode(opts)
	return api().toggle_danger_mode(opts)
end

function M.is_danger_mode_enabled()
	return api().is_danger_mode_enabled()
end

function M.clear(opts)
	return api().clear(opts)
end

function M.new_session(opts)
	return api().new_session(opts)
end

function M.close_session(opts)
	return api().close_session(opts)
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

function M.active_sessions()
	return api().active_sessions()
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

function M.add_current_line(opts)
	return api().add_current_line(opts)
end

function M.add_current_line_and_open_input(opts)
	return api().add_current_line_and_open_input(opts)
end

function M.add_visual_selection_to_input(opts)
	return api().add_visual_selection_to_input(opts)
end

function M.add_visual_selection(opts)
	return api().add_visual_selection(opts)
end

function M.add_visual_selection_and_open_input(opts)
	return api().add_visual_selection_and_open_input(opts)
end

function M.trigger_palette(id)
	return require("opencode.ui.palette").trigger(id)
end

return M
