-- opencode.nvim - User commands and default loader keymaps.

local M = {}

local actions = require("opencode.actions")

local function run_add_line_context_command(send_now, raw_context)
	local context = vim.trim(raw_context or "")
	if context ~= "" then
		actions.add_current_line_to_input({
			context = context,
			send = send_now,
		})
		return
	end

	vim.ui.input({ prompt = "OpenCode context: " }, function(input)
		if input == nil then
			return
		end
		actions.add_current_line_to_input({
			context = vim.trim(input),
			send = send_now,
		})
	end)
end

local function run_add_selection_context_command(send_now, raw_context)
	local context = vim.trim(raw_context or "")
	if context ~= "" then
		actions.add_visual_selection_to_input({
			context = context,
			send = send_now,
		})
		return
	end

	vim.ui.input({ prompt = "OpenCode context: " }, function(input)
		if input == nil then
			return
		end
		actions.add_visual_selection_to_input({
			context = vim.trim(input),
			send = send_now,
		})
	end)
end

local function run_danger_mode_command(raw_mode)
	local mode = vim.trim(raw_mode or ""):lower()
	if mode == "" or mode == "toggle" then
		actions.toggle_danger_mode()
		return
	end

	if mode == "on" or mode == "enable" or mode == "enabled" or mode == "true" then
		actions.enable_danger_mode()
		return
	end

	if mode == "off" or mode == "disable" or mode == "disabled" or mode == "false" then
		actions.disable_danger_mode()
		return
	end

	vim.notify("Usage: :OpenCodeDangerMode [on|off|toggle]", vim.log.levels.ERROR)
end

local function run_close_session_command(raw_session_id)
	local session_id = vim.trim(raw_session_id or "")
	actions.close_session({
		session_id = session_id ~= "" and session_id or nil,
		notify = true,
	})
end

local function create_commands()
	vim.api.nvim_create_user_command("OpenCode", function()
		actions.open()
	end, {
		desc = "Open OpenCode chat window",
	})

	vim.api.nvim_create_user_command("OpenCodeToggle", function()
		actions.toggle()
	end, {
		desc = "Toggle OpenCode chat window",
	})

	vim.api.nvim_create_user_command("OpenCodeClose", function()
		actions.close()
	end, {
		desc = "Close OpenCode chat window",
	})

	vim.api.nvim_create_user_command("OpenCodeClear", function()
		actions.clear()
	end, {
		desc = "Clear current OpenCode chat",
	})

	vim.api.nvim_create_user_command("OpenCodeNew", function()
		actions.new_session()
	end, {
		desc = "Start a new OpenCode session",
	})

	vim.api.nvim_create_user_command("OpenCodeCloseSession", function(args)
		run_close_session_command(args.args)
	end, {
		nargs = "?",
		desc = "Close the current active OpenCode session tab",
	})

	vim.api.nvim_create_user_command("OpenCodeCloseTab", function(args)
		run_close_session_command(args.args)
	end, {
		nargs = "?",
		desc = "Close the current active OpenCode session tab",
	})

	vim.api.nvim_create_user_command("OpenCodeStart", function()
		actions.start()
	end, {
		desc = "Start OpenCode server",
	})

	vim.api.nvim_create_user_command("OpenCodeStop", function()
		actions.stop()
	end, {
		desc = "Stop OpenCode server",
	})

	vim.api.nvim_create_user_command("OpenCodeRestart", function()
		actions.restart()
	end, {
		desc = "Restart OpenCode server",
	})

	vim.api.nvim_create_user_command("OpenCodeAbort", function()
		actions.abort()
	end, {
		desc = "Abort/stop current generation",
	})

	vim.api.nvim_create_user_command("OpenCodeDangerMode", function(args)
		run_danger_mode_command(args.args)
	end, {
		nargs = "?",
		complete = function()
			return { "on", "off", "toggle" }
		end,
		desc = "Toggle OpenCode danger mode permission auto-approval",
	})

	vim.api.nvim_create_user_command("OpenCodePaste", function()
		actions.paste_clipboard()
	end, {
		desc = "Paste clipboard into OpenCode input (supports screenshots)",
	})

	vim.api.nvim_create_user_command("OpenCodeLog", function()
		actions.toggle_logs()
	end, {
		desc = "Toggle OpenCode log viewer",
	})

	vim.api.nvim_create_user_command("OpenCodePalette", function()
		actions.command_palette()
	end, {
		desc = "Open OpenCode command palette",
	})

	vim.api.nvim_create_user_command("OpenCodeActiveSessions", function()
		actions.active_sessions()
	end, {
		desc = "Show active OpenCode sessions",
	})

	vim.api.nvim_create_user_command("OpenCodeAddLine", function()
		actions.add_current_line_to_input({ send = false })
	end, {
		desc = "Add current file/line to OpenCode input draft",
	})

	vim.api.nvim_create_user_command("OpenCodeSendLine", function()
		actions.add_current_line_to_input({ send = true })
	end, {
		desc = "Add current file/line to OpenCode input and send immediately",
	})

	vim.api.nvim_create_user_command("OpenCodeAddLineContext", function(args)
		run_add_line_context_command(false, args.args)
	end, {
		nargs = "*",
		desc = "Add current file/line plus extra context to OpenCode input draft",
	})

	vim.api.nvim_create_user_command("OpenCodeSendLineContext", function(args)
		run_add_line_context_command(true, args.args)
	end, {
		nargs = "*",
		desc = "Add current file/line plus context and send immediately",
	})

	vim.api.nvim_create_user_command("OpenCodeAddSelection", function()
		actions.add_visual_selection_to_input({ send = false })
	end, {
		range = true,
		desc = "Add visual selection with file/line range to OpenCode input draft",
	})

	vim.api.nvim_create_user_command("OpenCodeSendSelection", function()
		actions.add_visual_selection_to_input({ send = true })
	end, {
		range = true,
		desc = "Add visual selection with file/line range and send immediately",
	})

	vim.api.nvim_create_user_command("OpenCodeAddSelectionContext", function(args)
		run_add_selection_context_command(false, args.args)
	end, {
		range = true,
		nargs = "*",
		desc = "Add visual selection plus extra context to OpenCode input draft",
	})

	vim.api.nvim_create_user_command("OpenCodeSendSelectionContext", function(args)
		run_add_selection_context_command(true, args.args)
	end, {
		range = true,
		nargs = "*",
		desc = "Add visual selection plus context and send immediately",
	})
end

local function create_default_keymaps()
	vim.keymap.set("n", "<leader>oo", function()
		actions.toggle()
	end, { desc = "Toggle OpenCode", noremap = true, silent = true })

	vim.keymap.set("n", "<leader>op", function()
		actions.command_palette()
	end, { desc = "OpenCode command palette", noremap = true, silent = true })

	vim.keymap.set("n", "<leader>ol", function()
		actions.toggle_logs()
	end, { desc = "Toggle OpenCode logs", noremap = true, silent = true })

	vim.keymap.set("n", "<leader>oS", function()
		actions.active_sessions()
	end, { desc = "OpenCode active sessions", noremap = true, silent = true })

	vim.keymap.set("n", "<leader>oq", function()
		actions.close_session({ notify = true })
	end, { desc = "Close OpenCode session tab", noremap = true, silent = true })
end

function M.setup()
	create_commands()
	create_default_keymaps()
end

return M
