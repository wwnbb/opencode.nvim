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

  -- Setup local state module (agent/model/variant selection)
  local local_ok, local_module = pcall(require, "opencode.local")
  if local_ok then
    local_module.setup()
    M.local_state = local_module
  else
    vim.notify("Failed to load local state module: " .. tostring(local_module), vim.log.levels.WARN)
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

  -- Apply keymaps from user config (only if user explicitly configures them)
  -- Users who want keymaps should add them to their config, e.g.:
  -- keymaps = { toggle = "<leader>oo", command_palette = "<leader>op" }
  local km = M._config.keymaps or {}
  local map_opts = { noremap = true, silent = true }
  
  if km.toggle then
    vim.keymap.set("n", km.toggle, function()
      require("opencode").toggle()
    end, vim.tbl_extend("force", map_opts, { desc = "Toggle OpenCode" }))
  end

  if km.command_palette then
    vim.keymap.set("n", km.command_palette, function()
      require("opencode").command_palette()
    end, vim.tbl_extend("force", map_opts, { desc = "OpenCode command palette" }))
  end

  if km.show_diff then
    vim.keymap.set("n", km.show_diff, function()
      require("opencode").show_diff()
    end, vim.tbl_extend("force", map_opts, { desc = "Show OpenCode diff" }))
  end

  if km.abort then
    vim.keymap.set("n", km.abort, function()
      require("opencode").abort()
    end, vim.tbl_extend("force", map_opts, { desc = "Abort OpenCode request" }))
  end

  -- Setup cursor hiding for opencode buffers
  -- We need to hide the cursor completely in the chat buffer to avoid visual distractions
  -- during streaming/thinking animations. Using blend=100 alone doesn't fully hide the cursor
  -- because it only affects the highlight background. We also set fg/bg to match Normal background.
  local function setup_hidden_cursor_highlight()
    local normal_hl = vim.api.nvim_get_hl(0, { name = "Normal" })
    local bg = normal_hl.bg or 0x000000
    vim.api.nvim_set_hl(0, "OpenCodeHiddenCursor", {
      fg = bg,
      bg = bg,
      blend = 100,
      nocombine = true,
    })
  end

  -- Set up initially and on colorscheme change
  setup_hidden_cursor_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = setup_hidden_cursor_highlight,
    desc = "Update OpenCode hidden cursor highlight on colorscheme change",
  })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "opencode",
    callback = function()
      -- Hide cursor in opencode buffers using transparent highlight
      -- Include all cursor-related highlight groups for comprehensive hiding
      local cursor_hls = "Cursor:OpenCodeHiddenCursor,lCursor:OpenCodeHiddenCursor,CursorLine:OpenCodeHiddenCursor,CursorColumn:OpenCodeHiddenCursor"
      vim.wo.winhighlight = (vim.wo.winhighlight ~= "" and vim.wo.winhighlight .. "," or "") .. cursor_hls
      -- Also disable cursorline/cursorcolumn visual indicators
      vim.wo.cursorline = false
      vim.wo.cursorcolumn = false
    end,
    desc = "Hide cursor in OpenCode chat buffer",
  })

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

		-- NOTE: We don't add the user message locally anymore.
		-- The server will echo it back via SSE (message.updated event) with
		-- the correct server-assigned ID. This prevents duplicate messages
		-- that occurred when local IDs didn't match server IDs.

		-- Get or create session
		local session_id = state.get_session().id

		local function send_with_session(sid)
			-- Build message payload
			-- Get model/agent/variant from: 1) opts, 2) local state (user selection), 3) config default
			local model = opts.model
			local agent = opts.agent
			local variant = opts.variant

			-- Try to get from local module (like TUI's local.tsx)
			local local_ok, lc = pcall(require, "opencode.local")
			if local_ok then
				if not model then
					local current_model = lc.model.current()
					if current_model then
						model = {
							providerID = current_model.providerID,
							modelID = current_model.modelID,
						}
					end
				end
				if not agent then
					local current_agent = lc.agent.current()
					if current_agent then
						agent = current_agent.name
					end
				end
				if not variant then
					variant = lc.variant.current()
				end
			end

			-- Fallback to old state module
			if not model then
				local state_model = state.get_model()
				if state_model.id and state_model.provider then
					model = {
						providerID = state_model.provider,
						modelID = state_model.id,
					}
				else
					model = M._config.session.default_model
				end
			end

			if not agent then
				agent = M._config.session.default_agent
			end

			local payload = {
				parts = {
					{ type = "text", text = message }
				},
				agent = agent,
				model = model,
				variant = variant,
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

--- Abort/stop the current generation
--- Similar to pressing Escape or clicking stop in the TUI
function M.abort()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	local session_id = state.get_session().id
	if not session_id then
		vim.notify("No active session to abort", vim.log.levels.WARN)
		return
	end

	local current_status = state.get_status()
	if current_status ~= "streaming" then
		vim.notify("Not currently streaming", vim.log.levels.INFO)
		return
	end

	local client = require("opencode.client")
	client.abort_session(session_id, function(err, result)
		vim.schedule(function()
			if err then
				vim.notify("Failed to abort: " .. tostring(err.message or err.error or err), vim.log.levels.ERROR)
				return
			end

			state.set_status("idle")
			vim.notify("Generation stopped", vim.log.levels.INFO)
		end)
	end)
end

--- Clear chat / Start new session (like TUI's /clear or /new)
--- This creates a new session, clears the chat display, and clears sync data
---@param opts? { silent?: boolean }
function M.clear(opts)
	opts = opts or {}
	
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local chat = require("opencode.ui.chat")
		local sync = require("opencode.sync")
		local current_session = state.get_session()

		-- Clear sync data for current session
		if current_session.id then
			sync.clear_session(current_session.id)
		end

		-- Create a new session
		client.create_session({}, function(err, session)
			vim.schedule(function()
				if err then
					vim.notify("Failed to create new session: " .. tostring(err.message or err.error or err), vim.log.levels.ERROR)
					-- Still clear the UI even if session creation fails
					chat.clear()
					state.set_session(nil, nil)
					return
				end

				-- Update state with new session
				state.set_session(session.id, session.title or "New Session")
				
				-- Clear chat display
				chat.clear()
				
				if not opts.silent then
					vim.notify("Started new session", vim.log.levels.INFO)
				end
			end)
		end)
	end)
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

-- Agent/Model/Variant selection functions (like TUI's ctrl+t, ctrl+a, etc.)

--- Cycle to next model variant (like TUI's ctrl+t)
function M.cycle_variant()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		lc.variant.cycle()
		-- Update input info bar if visible
		local input_ok, input = pcall(require, "opencode.ui.input")
		if input_ok and input.is_visible() then
			input.update_info_bar()
		end
	else
		vim.notify("Local state module not loaded", vim.log.levels.WARN)
	end
end

--- Cycle to next agent (like TUI's agent cycling)
function M.cycle_agent()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		lc.agent.move(1)
		-- Update input info bar if visible
		local input_ok, input = pcall(require, "opencode.ui.input")
		if input_ok and input.is_visible() then
			input.update_info_bar()
		end
	else
		vim.notify("Local state module not loaded", vim.log.levels.WARN)
	end
end

--- Cycle to next model from recent list
function M.cycle_model()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		lc.model.cycle(1)
		-- Update input info bar if visible
		local input_ok, input = pcall(require, "opencode.ui.input")
		if input_ok and input.is_visible() then
			input.update_info_bar()
		end
	else
		vim.notify("Local state module not loaded", vim.log.levels.WARN)
	end
end

--- Get current agent info
function M.get_current_agent()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		return lc.agent.current()
	end
	return nil
end

--- Get current model info
function M.get_current_model()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		return lc.model.parsed()
	end
	return nil
end

--- Get current variant
function M.get_current_variant()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		return lc.variant.current()
	end
	return nil
end

--- Get available variants for current model
function M.get_variants()
	local ok, lc = pcall(require, "opencode.local")
	if ok then
		return lc.variant.list()
	end
	return {}
end

return M
