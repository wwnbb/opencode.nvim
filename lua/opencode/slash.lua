-- opencode.nvim - Slash command module
-- Handles /commands like TUI's slash commands

local M = {}

-- Registered slash commands
local commands = {}

-- Register a slash command
-- opts: { name, aliases, description, category, handler, enabled? }
function M.register(opts)
	if not opts.name or not opts.handler then
		error("Slash command must have name and handler")
	end
	
	commands[opts.name] = {
		name = opts.name,
		aliases = opts.aliases or {},
		description = opts.description or "",
		category = opts.category or "general",
		handler = opts.handler,
		enabled = opts.enabled,
	}
end

-- Unregister a slash command
function M.unregister(name)
	commands[name] = nil
end

-- Check if command is enabled
local function is_enabled(cmd)
	if cmd.enabled == nil then
		return true
	end
	if type(cmd.enabled) == "function" then
		local ok, result = pcall(cmd.enabled)
		return ok and result
	end
	return cmd.enabled
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
	local cmd_name, args_str = text:match("^/(%S+)%s*(.*)$")
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
function M.execute(parsed)
	if not parsed or not parsed.command then
		return false
	end
	
	-- Find command (check name and aliases)
	local cmd = nil
	for name, def in pairs(commands) do
		if name == parsed.command then
			cmd = def
			break
		end
		for _, alias in ipairs(def.aliases or {}) do
			if alias == parsed.command then
				cmd = def
				break
			end
		end
		if cmd then break end
	end
	
	if not cmd then
		vim.notify("Unknown command: /" .. parsed.command, vim.log.levels.WARN)
		return false
	end
	
	if not is_enabled(cmd) then
		vim.notify("Command not available: /" .. parsed.command, vim.log.levels.WARN)
		return false
	end
	
	-- Execute handler
	local ok, err = pcall(cmd.handler, parsed.args, parsed)
	if not ok then
		vim.notify("Command error: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	
	return true
end

-- Get all available commands (for completion)
function M.get_commands()
	local result = {}
	for name, cmd in pairs(commands) do
		if is_enabled(cmd) then
			table.insert(result, {
				name = name,
				description = cmd.description,
				category = cmd.category,
				aliases = cmd.aliases,
			})
		end
	end
	
	-- Sort by name
	table.sort(result, function(a, b)
		return a.name < b.name
	end)
	
	return result
end

-- Check if text is a slash command
function M.is_slash_command(text)
	return M.parse(text) ~= nil
end

-- Register default slash commands
function M.register_defaults()
	local opencode = require("opencode")
	local lifecycle = require("opencode.lifecycle")
	local state = require("opencode.state")
	
	-- /sessions, /resume, /continue - List and switch sessions
	M.register({
		name = "sessions",
		aliases = { "resume", "continue" },
		description = "List and switch between sessions",
		category = "session",
		handler = function()
			local palette = require("opencode.ui.palette")
			palette.trigger("session.list")
		end,
	})
	
	-- /new, /clear - Start new session
	M.register({
		name = "new",
		aliases = { "clear" },
		description = "Start a new session",
		category = "session",
		handler = function()
			opencode.clear()
		end,
	})
	
	-- /models - Switch model
	M.register({
		name = "models",
		description = "Switch AI model",
		category = "model",
		handler = function()
			local palette = require("opencode.ui.palette")
			palette.trigger("model.switch")
		end,
	})
	
	-- /agents - Switch agent
	M.register({
		name = "agents",
		description = "Switch AI agent",
		category = "agent",
		handler = function()
			local palette = require("opencode.ui.palette")
			palette.trigger("agent.switch")
		end,
	})
	
	-- /connect - Connect provider
	M.register({
		name = "connect",
		description = "Connect an AI provider",
		category = "provider",
		handler = function()
			local palette = require("opencode.ui.palette")
			palette.trigger("provider.connect")
		end,
	})
	
	-- /compact - Compact session
	M.register({
		name = "compact",
		aliases = { "summarize" },
		description = "Compact session messages",
		category = "session",
		handler = function()
			local palette = require("opencode.ui.palette")
			palette.trigger("action.compact")
		end,
		enabled = function()
			return state.get_session().id ~= nil
		end,
	})
	
	-- /help - Show help
	M.register({
		name = "help",
		description = "Show available commands",
		category = "system",
		handler = function()
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
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
			vim.bo[bufnr].modifiable = false
			
			float.setup_close_keymaps(bufnr, function()
				popup:unmount()
			end)
		end,
	})
	
	-- /undo - Undo last message
	M.register({
		name = "undo",
		description = "Undo last message and changes",
		category = "session",
		handler = function()
			local session_id = state.get_session().id
			if not session_id then
				vim.notify("No active session", vim.log.levels.WARN)
				return
			end
			
			local client = require("opencode.client")
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
			
			client.revert_message(session_id, last_user_msg.id, {}, function(err)
				vim.schedule(function()
					if err then
						vim.notify("Failed to undo: " .. tostring(err.message or err), vim.log.levels.ERROR)
						return
					end
					vim.notify("Undone last message", vim.log.levels.INFO)
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
	
	-- /redo - Redo undone message
	M.register({
		name = "redo",
		description = "Redo previously undone message",
		category = "session",
		handler = function()
			-- Note: Redo functionality depends on server implementation
			-- This is a placeholder
			vim.notify("Redo not yet implemented", vim.log.levels.INFO)
		end,
	})
	
	-- /share - Share current session
	M.register({
		name = "share",
		description = "Share current session",
		category = "session",
		handler = function()
			local session_id = state.get_session().id
			if not session_id then
				vim.notify("No active session to share", vim.log.levels.WARN)
				return
			end
			
			local client = require("opencode.client")
			client.execute_command(session_id, "share", {}, {}, function(err, result)
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
