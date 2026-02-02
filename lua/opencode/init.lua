-- opencode.nvim - Neovim frontend for OpenCode AI coding agent
-- Main entry point

local M = {}

-- Plugin version
M.version = "0.1.0"

-- Modules (lazy loaded)
local config = require("opencode.config")
local state = require("opencode.state")
local events
local lifecycle
local client

--- Setup function - called by user to configure the plugin
---@param opts table Configuration options
function M.setup(opts)
	-- Merge user config with defaults
	M._config = config.merge(opts)

	-- Initialize state with config
	state.set_config(M._config)
	state.set_server_info({
		host = M._config.server.host,
		port = M._config.server.port,
	})

	-- Initialize events module (before client/lifecycle for bridge setup)
	local events_ok
	events_ok, events = pcall(require, "opencode.events")
	if not events_ok then
		vim.notify("Failed to load opencode events: " .. tostring(events), vim.log.levels.ERROR)
		return
	end

	events.setup()

	-- Initialize client with config
	local client_ok
	client_ok, client = pcall(require, "opencode.client")
	if not client_ok then
		vim.notify("Failed to load opencode client: " .. tostring(client), vim.log.levels.ERROR)
		return
	end

	client.setup({
		host = M._config.server.host,
		port = M._config.server.port,
		auth = M._config.server.auth,
		timeout = M._config.server.timeout,
		reconnect = true,
	})

	-- Initialize lifecycle module
	local lifecycle_ok
	lifecycle_ok, lifecycle = pcall(require, "opencode.lifecycle")
	if not lifecycle_ok then
		vim.notify("Failed to load opencode lifecycle: " .. tostring(lifecycle), vim.log.levels.ERROR)
		return
	end

	lifecycle.setup({
		auto_start = M._config.server.auto_start,
		startup_timeout = M._config.server.startup_timeout,
		health_check_interval = M._config.server.health_check_interval,
		shutdown_on_exit = M._config.server.shutdown_on_exit,
		reuse_running = M._config.server.reuse_running,
		auth = M._config.server.auth,
	})

	-- Expose state module
	M.state = state

	-- Setup lualine component if configured
  if M._config.lualine and M._config.lualine.enabled ~= false then
    local lualine_ok, lualine = pcall(require, "opencode.components.lualine")
    if lualine_ok then
      lualine.setup(M._config.lualine)
      M.lualine = lualine
    end
  end

  -- Setup command palette (registers default commands)
  local palette_ok, palette = pcall(require, "opencode.ui.palette")
  if palette_ok and type(palette.setup) == "function" then
    pcall(function()
      palette.setup()
      M.palette = palette
    end)
  else
    if not palette_ok then
      vim.notify("Failed to load command palette: " .. tostring(palette), vim.log.levels.WARN)
    end
  end

  -- Apply keymaps from user config (overrides plugin defaults)
  local km = M._config.keymaps or {}
  local map_opts = { noremap = true, silent = true }
  vim.keymap.set("n", km.toggle or "<leader>oo", function()
    require("opencode").toggle()
  end, vim.tbl_extend("force", map_opts, { desc = "Toggle OpenCode" }))

  vim.keymap.set("n", km.command_palette or "<leader>op", function()
    require("opencode").command_palette()
  end, vim.tbl_extend("force", map_opts, { desc = "OpenCode command palette" }))

  vim.keymap.set("n", km.show_diff or "<leader>od", function()
    require("opencode").show_diff()
  end, vim.tbl_extend("force", map_opts, { desc = "Show OpenCode diff" }))

  vim.keymap.set("n", km.abort or "<leader>ox", function()
    require("opencode").abort()
  end, vim.tbl_extend("force", map_opts, { desc = "Abort OpenCode request" }))

  vim.notify("OpenCode.nvim v" .. M.version .. " loaded", vim.log.levels.INFO)
end

--- Toggle chat window
function M.toggle()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local chat = require("opencode.ui.chat")
		chat.toggle()
	end)
end

--- Open chat window
function M.open()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local chat = require("opencode.ui.chat")
		chat.open()
	end)
end

--- Close chat window
function M.close()
	local chat = require("opencode.ui.chat")
	chat.close()
end

--- Focus chat window
function M.focus()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local chat = require("opencode.ui.chat")
		chat.focus()
	end)
end

--- Focus input area
function M.focus_input()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local chat = require("opencode.ui.chat")
		chat.focus_input()
	end)
end

--- Send a message to the chat
---@param message string Message content
---@param opts? table Additional options
function M.send(message, opts)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	opts = opts or {}

	lifecycle.ensure_connected(function()
		local chat = require("opencode.ui.chat")
		local client = require("opencode.client")

		-- Show user message in chat
		chat.add_message("user", message)

		-- Get or create session
		local session_id = state.get_session().id

		local function send_with_session(sid)
			-- Build message payload
			local payload = {
				parts = {
					{ type = "text", text = message }
				},
				agent = opts.agent or M._config.session.default_agent,
				model = opts.model or M._config.session.default_model,
			}

			-- Add context if provided
			if opts.context then
				for _, ctx in ipairs(opts.context) do
					table.insert(payload.parts, ctx)
				end
			end

			-- Send to server asynchronously
			client.send_message_async(sid, payload, function(err)
				if err then
					vim.schedule(function()
						vim.notify("Failed to send message: " .. tostring(err.message or err.error or err), vim.log.levels.ERROR)
						chat.add_message("system", "Error: Failed to send message")
					end)
					return
				end

				-- Message sent successfully, server will respond via SSE
				vim.schedule(function()
					state.set_status("streaming")
				end)
			end)
		end

		if session_id then
			-- Use existing session
			send_with_session(session_id)
		else
			-- Create new session first
			client.create_session({ title = opts.title or "Neovim Chat" }, function(err, session)
				if err or not session then
					vim.schedule(function()
						vim.notify("Failed to create session: " .. tostring(err and (err.message or err.error) or "unknown"), vim.log.levels.ERROR)
						chat.add_message("system", "Error: Failed to create session")
					end)
					return
				end

				-- Store session info
				vim.schedule(function()
					state.set_session(session.id, session.title or "Neovim Chat")
					send_with_session(session.id)
				end)
			end)
		end
	end)
end

--- Clear chat history
function M.clear()
	local chat = require("opencode.ui.chat")
	chat.clear()
end

--- Get chat messages
function M.get_messages()
	local chat = require("opencode.ui.chat")
	return chat.get_messages()
end

--- Manually start server
function M.start()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return false
	end
	return lifecycle.start()
end

--- Stop server (if plugin started it)
function M.stop()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return false
	end
	return lifecycle.stop()
end

--- Restart server
function M.restart()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end
	lifecycle.restart()
end

--- Disconnect from server (keep running)
function M.disconnect()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end
	lifecycle.disconnect()
end

--- Get current OpenCode status
---@return table Status information
function M.get_status()
	return state.get_status_summary()
end

--- Check if connected to OpenCode server
---@return boolean
function M.is_connected()
	return lifecycle and lifecycle.is_connected() or false
end

--- Check if currently streaming
---@return boolean
function M.is_streaming()
	return state.get_status() == "streaming"
end

--- Ensure connected (for lazy init)
---@param callback function Called when connected
function M.ensure_connected(callback)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return false
	end
	return lifecycle.ensure_connected(callback)
end

-- Event system methods

--- Subscribe to an event
---@param event_type string Event type (e.g., "message", "connected", "status_change")
---@param callback function Callback function(data)
function M.on(event_type, callback)
	if not events then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return nil
	end
	return events.on(event_type, callback)
end

--- Subscribe to an event (one-time only)
---@param event_type string Event type
---@param callback function Callback function(data)
function M.once(event_type, callback)
	if not events then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return nil
	end
	return events.once(event_type, callback)
end

--- Unsubscribe from an event
---@param event_type string Event type
---@param callback function Callback to remove
function M.off(event_type, callback)
	if not events then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end
	events.off(event_type, callback)
end

--- Manually emit an event (for testing or custom events)
---@param event_type string Event type
---@param data any Event data
function M.emit(event_type, data)
	if not events then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end
	events.emit(event_type, data)
end

-- UI Components

--- Open command palette
function M.command_palette()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local palette = require("opencode.ui.palette")
		palette.show()
	end)
end

--- Show diff viewer
function M.show_diff()
	local diff = require("opencode.ui.diff")
	local changes = require("opencode.artifact.changes")
	local all_changes = changes.get_all()

	if #all_changes == 0 then
		vim.notify("No pending changes to show", vim.log.levels.INFO)
		return
	end

	-- Show the first pending change
	for _, change in ipairs(all_changes) do
		if change.status == "pending" then
			diff.show(change.id)
			return
		end
	end

	vim.notify("No pending changes to show", vim.log.levels.INFO)
end

--- Abort current request
function M.abort()
	local client = require("opencode.client")
	client.abort()
	state.set_status("idle")
	vim.notify("Request aborted", vim.log.levels.INFO)
end

--- Toggle log viewer window
function M.toggle_logs()
	local viewer = require("opencode.ui.log_viewer")
	viewer.toggle()
end

--- Open log viewer window
function M.open_logs()
	local viewer = require("opencode.ui.log_viewer")
	viewer.open()
end

--- Close log viewer window
function M.close_logs()
	local viewer = require("opencode.ui.log_viewer")
	viewer.close()
end

--- Clear all logs
function M.clear_logs()
	local logger = require("opencode.logger")
	logger.clear()
	vim.notify("OpenCode logs cleared", vim.log.levels.INFO)
end

-- Lualine component (for direct use in lualine setup)
M.lualine_component = function()
	local lualine_ok, lualine = pcall(require, "opencode.components.lualine")
	if not lualine_ok then
		return ""
	end
	return lualine.component()
end

-- Expose config for other modules
M._get_config = function()
	return M._config
end

return M
