-- opencode.nvim - Slash command module
-- Handles /commands like TUI's slash commands

local M = {}
local registry = require("opencode.command_registry")

-- Register a slash command
-- opts: { name, aliases, description, category, handler, enabled?, on_select? }
function M.register(opts)
	if not opts.name or not opts.handler then
		error("Slash command must have name and handler")
	end
	return registry.register({
		id = "slash." .. opts.name,
		title = "/" .. opts.name,
		description = opts.description or "",
		category = opts.category or "general",
		palette = false,
		slash = { name = opts.name, aliases = opts.aliases or {} },
		run = function(context)
			return opts.handler(context.args or "", context.parsed)
		end,
		enabled = opts.enabled,
		on_select = opts.on_select,
		enter_with_args = opts.enter_with_args,
		with_parts = opts.with_parts,
	})
end

-- Unregister a slash command
function M.unregister(name)
	local record = registry.get_slash(name)
	if not record or record.slash.name ~= name then
		return false
	end
	if record.palette == false then
		return registry.unregister(record.id)
	end
	-- A shared command may still be available in the palette after its
	-- slash entry point is removed.
	local replacement = {}
	for key, value in pairs(record) do
		if key ~= "slash" and key ~= "_serial" then
			replacement[key] = value
		end
	end
	registry.register(replacement)
	return true
end

-- Parse slash command from text
-- Returns: { command, args, raw } or nil if not a slash command
function M.parse(text)
	if not text or text == "" then
		return nil
	end
	
	-- Check if text starts with /
	if not text:match("^/") then
		return nil
	end
	
	-- Extract command name and arguments
	-- Format: /command arg1 arg2 ...
	local cmd_name, args_str = text:match("^/(%S+)%s*([%s%S]*)$")
	if not cmd_name then
		return nil
	end
	
	return {
		command = cmd_name,
		args = args_str,
		raw = text,
	}
end

-- Execute a slash command
-- Returns: true if handled, false otherwise
function M.execute(parsed, context)
	if not parsed or not parsed.command then
		return false
	end
	local record = registry.get_slash(parsed.command)
	if not record then
		vim.notify("Unknown command: /" .. parsed.command, vim.log.levels.WARN)
		return false
	end
	local command_context = {
		source = "slash",
		args = parsed.args or "",
		parsed = parsed,
	}
	for key, value in pairs(context or {}) do
		command_context[key] = value
	end
	if not registry.enabled(record, command_context) then
		vim.notify("Command not available: /" .. parsed.command, vim.log.levels.WARN)
		return false
	end
	return registry.run(record.id, command_context)
end

-- Get all available commands (for completion)
function M.get_commands()
	return registry.list_slash()
end

-- Check if text is a slash command
function M.is_slash_command(text)
	return M.parse(text) ~= nil
end

-- Register default slash commands
function M.register_defaults()
	-- Palette definitions provide the shared slash and palette commands.
	require("opencode.ui.palette").register_defaults()
	local actions = require("opencode.actions")
	local state = require("opencode.state")

	registry.register({
		id = "session.stats",
		title = "Usage Statistics",
		description = "Usage statistics",
		category = "session",
		palette = false,
		slash = { name = "stats" },
		run = function(_context)
			actions.get_usage_stats(function(err, data)
				if err then
					vim.notify("Could not load usage statistics: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				local view, stats_error = require("opencode.stats").from_api(data)
				if not view then
					vim.notify("Could not show usage statistics: " .. stats_error, vim.log.levels.ERROR)
					return
				end
				require("opencode.ui.stats").show(view)
			end)
		end,
	})
	-- /help - Show help
	registry.register({
		id = "system.help",
		title = "Slash Command Help",
		description = "Show available commands",
		category = "system",
		palette = false,
		slash = { name = "help" },
		run = function(_context)
			-- Create help buffer
			local lines = { "Available Commands:", "" }
			local current_category = nil
			
			for _, cmd in ipairs(M.get_commands()) do
				if cmd.category ~= current_category then
					current_category = cmd.category
					table.insert(lines, "")
					table.insert(lines, current_category:upper() .. ":")
				end
				
				local aliases = ""
				if cmd.aliases and #cmd.aliases > 0 then
					aliases = " (" .. table.concat(cmd.aliases, ", ") .. ")"
				end
				
				table.insert(lines, string.format("  /%-15s %s%s", cmd.name, cmd.description, aliases))
			end
			
			local float = require("opencode.ui.float")
			local popup, bufnr = float.create_centered_popup({
				width = 60,
				height = math.min(#lines + 2, 25),
				title = " Slash Commands ",
			})
			
			popup:mount()
			popup:render(lines)
			
			float.setup_close_keymaps(bufnr, function()
				popup:close()
			end)
		end,
	})
	
	-- /undo - Undo last message
	registry.register({
		id = "session.undo",
		title = "Undo Last Message",
		description = "Undo last message and changes",
		category = "session",
		palette = false,
		slash = { name = "undo" },
		run = function(_context)
			local session_id = state.get_session().id
			if not session_id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end
			
			local sync = require("opencode.sync")
			local messages = sync.get_messages(session_id)
			
			if #messages == 0 then
				vim.notify("No messages to undo", vim.log.levels.INFO)
				return
			end
			
			-- Find last user message to revert from
			local last_user_msg = nil
			for i = #messages, 1, -1 do
				if messages[i].role == "user" then
					last_user_msg = messages[i]
					break
				end
			end
			
			if not last_user_msg then
				vim.notify("No user message to undo", vim.log.levels.WARN)
				return
			end
			
			actions.revert_message(session_id, last_user_msg.id, {}, function(err)
				vim.schedule(function()
					if err then
						vim.notify("Failed to undo: " .. tostring(err.message or err), vim.log.levels.ERROR)
						return
					end
					vim.notify("Undo staged. Use /redo to restore the turn.", vim.log.levels.INFO)
				end)
			end)
		end,
		enabled = function()
			local sync = require("opencode.sync")
			local session_id = state.get_session().id
			if not session_id then return false end
			return #sync.get_messages(session_id) > 0
		end,
	})
	
	registry.register({ id = "session.redo", title = "Redo Staged Undo", description = "Clear staged undo and restore the turn", category = "session",
		palette = false, slash = { name = "redo" },
		run = function(_context)
			local sid = state.get_session().id
			if not sid then return end
			actions.clear_revert(sid, function(err)
				vim.notify(err and ("Could not restore turn: " .. err.message) or "Staged undo cleared", err and vim.log.levels.ERROR or vim.log.levels.INFO)
			end)
		end })

	-- /share - Share current session
	registry.register({
		id = "session.share",
		title = "Share Session",
		description = "Share current session",
		category = "session",
		palette = false,
		slash = { name = "share" },
		run = function(_context)
			local session_id = state.get_session().id
			if not session_id then
				vim.notify("No active session to share", vim.log.levels.WARN)
				return
			end
			
			actions.execute_command(session_id, "share", {}, {}, function(err, result)
				vim.schedule(function()
					if err then
						vim.notify("Failed to share: " .. tostring(err.message or err), vim.log.levels.ERROR)
						return
					end
					
					if result and result.url then
						vim.fn.setreg("+", result.url)
						vim.notify("Share URL copied to clipboard: " .. result.url, vim.log.levels.INFO)
					else
						vim.notify("Session shared", vim.log.levels.INFO)
					end
				end)
			end)
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
end

return M
