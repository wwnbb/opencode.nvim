-- opencode.nvim - Neovim frontend for OpenCode AI coding agent
-- Main entry point

local M = {}

-- Plugin version
M.version = "0.1.0"

-- Modules (lazy loaded)
local config = require("opencode.config")
local state = require("opencode.state")
local session_actions = require("opencode.session")
local events
local lifecycle
local client

---@param prompt string
---@param opts? { send?: boolean, separator?: string }
---@param label string
---@return boolean
local function _append_prompt_to_input(prompt, opts, label)
	opts = opts or {}

	local input_ok, input = pcall(require, "opencode.ui.input")
	if not input_ok then
		vim.notify("Failed to load input module: " .. tostring(input), vim.log.levels.ERROR)
		return false
	end

	input.append_pending_text(prompt, { separator = opts.separator or "\n\n" })

	if opts.send ~= true then
		vim.notify("Added " .. label .. " to OpenCode input", vim.log.levels.INFO)
		return true
	end

	if not lifecycle then
		vim.notify("OpenCode not initialized; content was added to draft only", vim.log.levels.WARN)
		return false
	end

	local text = input.get_pending_text()
	if vim.trim(text) == "" then
		vim.notify("OpenCode input is empty", vim.log.levels.WARN)
		return false
	end

	input.set_pending_text("")
	M.send(text)
	vim.notify("Sent OpenCode prompt with " .. label, vim.log.levels.INFO)
	return true
end

---@return boolean
local function _is_visual_mode()
	local mode = vim.api.nvim_get_mode().mode
	return mode == "v" or mode == "V" or mode == "\022"
end

---@return nil
local function _leave_visual_mode()
	local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
	vim.api.nvim_feedkeys(esc, "nx", false)
end

---@param input table
---@return boolean
local function _focus_input_window_at_end(input)
	for _, win in ipairs(input.get_winids()) do
		if vim.api.nvim_win_is_valid(win) then
			local buf = vim.api.nvim_win_get_buf(win)
			if vim.bo[buf].filetype == "opencode_input" then
				local last = vim.api.nvim_buf_line_count(buf)
				if not pcall(vim.api.nvim_set_current_win, win) then
					return false
				end
				vim.api.nvim_win_set_cursor(win, { last, 0 })
				vim.api.nvim_win_call(win, function()
					vim.cmd("normal! zb")
				end)
				vim.cmd("startinsert!")
				return true
			end
		end
	end
	return false
end

---@param input table
---@param max_attempts number
---@param delay number
---@param attempt number
---@return nil
local function _focus_input_window_when_ready(input, max_attempts, delay, attempt)
	if _focus_input_window_at_end(input) then
		return
	end
	if attempt >= max_attempts then
		return
	end
	vim.defer_fn(function()
		_focus_input_window_when_ready(input, max_attempts, delay, attempt + 1)
	end, delay)
end

---@param opts? { context?: string }
---@return string|nil
local function _build_current_line_prompt(opts)
	opts = opts or {}

	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		vim.notify("OpenCode: current buffer has no file path", vim.log.levels.WARN)
		return nil
	end

	local line_num = vim.api.nvim_win_get_cursor(0)[1]
	local line_text = vim.api.nvim_buf_get_lines(bufnr, line_num - 1, line_num, false)[1] or ""
	local display_path = vim.fn.fnamemodify(filepath, ":~:.")
	if display_path == "" then
		display_path = filepath
	end

	local parts = {
		string.format("@%s#%d", display_path, line_num),
	}
	if line_text ~= "" then
		table.insert(parts, line_text)
	end

	local context = opts.context and vim.trim(opts.context) or ""
	if context ~= "" then
		table.insert(parts, "Context: " .. context)
	end

	return table.concat(parts, "\n")
end

---@param opts? { context?: string }
---@return string|nil
local function _build_visual_selection_prompt(opts)
	opts = opts or {}

	local bufnr = vim.api.nvim_get_current_buf()
	local filepath = vim.api.nvim_buf_get_name(bufnr)
	if filepath == "" then
		vim.notify("OpenCode: current buffer has no file path", vim.log.levels.WARN)
		return nil
	end

	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")
	local start_line = start_pos[2]
	local start_col = start_pos[3]
	local end_line = end_pos[2]
	local end_col = end_pos[3]

	if start_line == 0 or end_line == 0 then
		vim.notify("OpenCode: no visual selection found", vim.log.levels.WARN)
		return nil
	end

	if start_line > end_line then
		start_line, end_line = end_line, start_line
		start_col, end_col = end_col, start_col
	elseif start_line == end_line and start_col > end_col then
		start_col, end_col = end_col, start_col
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
	if #lines == 0 then
		vim.notify("OpenCode: selected range is empty", vim.log.levels.WARN)
		return nil
	end

	local visual_mode = vim.fn.visualmode()
	if visual_mode == "\022" then
		local col_start = math.min(start_col, end_col)
		local col_end = math.max(start_col, end_col)
		for i, line in ipairs(lines) do
			lines[i] = line:sub(col_start, col_end)
		end
	elseif visual_mode ~= "V" then
		if #lines == 1 then
			lines[1] = lines[1]:sub(start_col, end_col)
		else
			lines[1] = lines[1]:sub(start_col)
			lines[#lines] = lines[#lines]:sub(1, end_col)
		end
	end

	local display_path = vim.fn.fnamemodify(filepath, ":~:.")
	if display_path == "" then
		display_path = filepath
	end

	local line_ref = tostring(start_line)
	if start_line ~= end_line then
		line_ref = string.format("%d-%d", start_line, end_line)
	end

	local parts = {
		string.format("@%s#%s", display_path, line_ref),
		table.concat(lines, "\n"),
	}

	local context = opts.context and vim.trim(opts.context) or ""
	if context ~= "" then
		table.insert(parts, "Context: " .. context)
	end

	return table.concat(parts, "\n")
end

--- Setup function - called by user to configure the plugin
---@param opts table Configuration options
function M.setup(opts)
	-- Merge user config with defaults
	M._config = config.merge(opts)

	-- Initialize state with config
	state.set_config(M._config)
	state.set_danger_mode(M._config.danger_mode == true)
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
		command = M._config.server.command,
		auto_start = M._config.server.auto_start,
		startup_timeout = M._config.server.startup_timeout,
		health_check_interval = M._config.server.health_check_interval,
		shutdown_on_exit = M._config.server.shutdown_on_exit,
		reuse_running = M._config.server.reuse_running,
		use_shell_env = M._config.server.use_shell_env,
		env = M._config.server.env,
		auth = M._config.server.auth,
		config_dir = M._config.server.config_dir,
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

	-- Setup artifact change tracking before UI modules register commands that depend on it.
	local changes_ok, changes = pcall(require, "opencode.artifact.changes")
	if changes_ok and type(changes.setup) == "function" then
		local changes_setup_ok, changes_err = pcall(changes.setup, M._config.changes or {})
		if changes_setup_ok then
			M.changes = changes
		else
			vim.notify("Failed to setup change tracking: " .. tostring(changes_err), vim.log.levels.WARN)
		end
	elseif not changes_ok then
		vim.notify("Failed to load change tracking: " .. tostring(changes), vim.log.levels.WARN)
	end

	-- Setup command palette (registers default commands)
	local palette_ok, palette = pcall(require, "opencode.ui.palette")
	if palette_ok and type(palette.setup) == "function" then
		local palette_setup_ok, palette_err = pcall(palette.setup)
		if palette_setup_ok then
			M.palette = palette
		else
			vim.notify("Failed to setup command palette: " .. tostring(palette_err), vim.log.levels.WARN)
		end
	elseif not palette_ok then
		vim.notify("Failed to load command palette: " .. tostring(palette), vim.log.levels.WARN)
	end

  -- Setup slash commands (registers default commands like /new)
  local slash_ok, slash = pcall(require, "opencode.slash")
  if slash_ok and type(slash.register_defaults) == "function" then
    slash.register_defaults()
  elseif not slash_ok then
    vim.notify("Failed to load slash commands: " .. tostring(slash), vim.log.levels.WARN)
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

  if km.abort then
    vim.keymap.set("n", km.abort, function()
      require("opencode").abort()
    end, vim.tbl_extend("force", map_opts, { desc = "Abort OpenCode request" }))
  end

  if km.active_sessions then
    vim.keymap.set("n", km.active_sessions, function()
      require("opencode").active_sessions()
    end, vim.tbl_extend("force", map_opts, { desc = "OpenCode active sessions" }))
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

  if M._config.danger_mode == true then
    vim.notify("OpenCode danger mode enabled: permission requests will be auto-approved", vim.log.levels.WARN)
  end

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

--- Focus the OpenCode input, placing the cursor at the end of the draft.
---@param opts? { attempts?: number, delay?: number }
---@return boolean success Whether focusing was requested
function M.open_input_at_end(opts)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return false
	end

	local input_ok, input = pcall(require, "opencode.ui.input")
	if not input_ok then
		vim.notify("Failed to load input module: " .. tostring(input), vim.log.levels.ERROR)
		return false
	end

	local pending = input.get_pending_text()
	if pending ~= "" and not pending:match("\n$") then
		input.set_pending_text(pending .. "\n")
	end

	M.focus_input()

	opts = opts or {}
	local max_attempts = opts.attempts or 20
	local delay = opts.delay or 10
	vim.schedule(function()
		_focus_input_window_when_ready(input, max_attempts, delay, 1)
	end)
	return true
end

--- Paste clipboard content into the OpenCode input.
--- Images are attached as OpenCode file parts when supported by the platform.
---@return nil
function M.paste_clipboard()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local chat = require("opencode.ui.chat")
		chat.focus_input()
		vim.schedule(function()
			require("opencode.ui.input").paste_clipboard()
		end)
	end)
end

--- Add current file/line to the draft input without opening the chat window.
---@param opts? { context?: string, send?: boolean, separator?: string }
---@return boolean
function M.add_current_line_to_input(opts)
	opts = opts or {}

	local prompt = _build_current_line_prompt({ context = opts.context })
	if not prompt then
		return false
	end

	return _append_prompt_to_input(prompt, opts, "current line")
end

--- Add current file/line to the draft input.
---@param opts? { context?: string, send?: boolean, separator?: string, open_input?: boolean }
---@return boolean
function M.add_current_line(opts)
	opts = opts or {}

	local ok = M.add_current_line_to_input(opts)
	if ok and opts.open_input then
		M.open_input_at_end()
	end
	return ok
end

--- Add current file/line to the draft input and focus the input at the end.
---@param opts? { context?: string, send?: boolean, separator?: string }
---@return boolean
function M.add_current_line_and_open_input(opts)
	local merged_opts = vim.tbl_extend("force", opts or {}, {
		open_input = true,
	})
	return M.add_current_line(merged_opts)
end

--- Add the current visual selection to the draft input without opening chat.
---@param opts? { context?: string, send?: boolean, separator?: string }
---@return boolean
function M.add_visual_selection_to_input(opts)
	opts = opts or {}

	local prompt = _build_visual_selection_prompt({ context = opts.context })
	if not prompt then
		return false
	end

	return _append_prompt_to_input(prompt, opts, "selection")
end

--- Add the current visual selection to the draft input.
---@param opts? { context?: string, send?: boolean, separator?: string, open_input?: boolean }
---@return boolean
function M.add_visual_selection(opts)
	opts = opts or {}

	if _is_visual_mode() then
		_leave_visual_mode()
		vim.schedule(function()
			M.add_visual_selection(opts)
		end)
		return true
	end

	local ok = M.add_visual_selection_to_input(opts)
	if ok and opts.open_input then
		M.open_input_at_end()
	end
	return ok
end

--- Add the current visual selection to the draft input and focus the input at the end.
---@param opts? { context?: string, send?: boolean, separator?: string }
---@return boolean
function M.add_visual_selection_and_open_input(opts)
	local merged_opts = vim.tbl_extend("force", opts or {}, {
		open_input = true,
	})
	return M.add_visual_selection(merged_opts)
end

--- Send a message to the chat
---@param message string Message content
---@param opts? table Additional options
function M.send(message, opts)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		require("opencode.send").send(message, opts)
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

			session_actions.set_status("idle", {
				reason = "abort",
				session_id = session_id,
			})
		end)
	end)
end

--- Clear the current chat without changing the active session.
---@param opts? { silent?: boolean }
function M.clear(opts)
	opts = opts or {}

	local chat = require("opencode.ui.chat")
	local sync = require("opencode.sync")
	local current_session = state.get_session()

	if current_session.id then
		if type(sync.clear_session_messages) == "function" then
			sync.clear_session_messages(current_session.id)
		else
			sync.clear_session(current_session.id)
		end
		state.set_message_count(0)
		session_actions.set_message_cache(current_session.id, {}, {
			reason = "clear_chat",
		})
		chat.clear_session_view(current_session.id)
	else
		chat.clear()
	end

	if events and events.emit then
		events.emit("sync_changed", {
			kind = "session_messages",
			action = "clear_chat",
			session_id = current_session.id,
		})
	end

	if not opts.silent then
		vim.notify("Cleared current OpenCode chat", vim.log.levels.INFO)
	end
end

--- Start a new root session and make it active.
---@param opts? { silent?: boolean }
function M.new_session(opts)
	opts = opts or {}

	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		local sync = require("opencode.sync")
		local current_session = state.get_session()
		local cfg = state.get_config() or {}
		local parallel = cfg.session and cfg.session.parallel or {}
		local preserve_cache = parallel.enabled ~= false

		if current_session.id and not preserve_cache then
			sync.clear_session(current_session.id)
		end

		client.create_session({}, function(err, session)
			vim.schedule(function()
				if err then
					vim.notify("Failed to create new session: " .. tostring(err.message or err.error or err), vim.log.levels.ERROR)
					return
				end

				session_actions.set_active(session.id, session.title or "New session", {
					reason = "new_session",
					preserve_cache = preserve_cache,
				})

				local render_ok, render_coordinator = pcall(require, "opencode.ui.chat.render_coordinator")
				if render_ok then
					render_coordinator.request({
						session_id = session.id,
						reason = "new_session",
					})
				end

				if not opts.silent then
					vim.notify("Started new session", vim.log.levels.INFO)
				end
			end)
		end)
	end)
end

--- Close the current active session tab without deleting the backend session.
---@param opts? { session_id?: string, notify?: boolean, silent?: boolean }
---@return boolean closed Whether a runtime session tab was closed
function M.close_session(opts)
	opts = opts or {}
	return session_actions.close(opts.session_id, {
		notify = opts.notify ~= false,
		silent = opts.silent == true,
		reason = "session_close",
	})
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

---@param enabled boolean
---@param opts? { silent?: boolean }
---@return boolean enabled Current danger mode state
function M.set_danger_mode(enabled, opts)
	opts = opts or {}
	local current = enabled == true
	state.set_danger_mode(current)

	local pending_count = 0
	if current then
		local danger_ok, danger = pcall(require, "opencode.permission.danger")
		if danger_ok and type(danger.approve_pending) == "function" then
			pending_count = danger.approve_pending()
		end
	else
		local danger_ok, danger = pcall(require, "opencode.permission.danger")
		if danger_ok and type(danger.clear) == "function" then
			danger.clear()
		end
	end

	if events and type(events.emit) == "function" then
		events.emit("status_change", { danger_mode = current })
	end

	if opts.silent ~= true then
		if current then
			local suffix = pending_count > 0 and ("; auto-approving " .. pending_count .. " pending request(s)") or ""
			vim.notify("OpenCode danger mode enabled" .. suffix, vim.log.levels.WARN)
		else
			vim.notify("OpenCode danger mode disabled", vim.log.levels.INFO)
		end
	end

	return current
end

---@param opts? { silent?: boolean }
---@return boolean enabled Current danger mode state
function M.enable_danger_mode(opts)
	return M.set_danger_mode(true, opts)
end

---@param opts? { silent?: boolean }
---@return boolean enabled Current danger mode state
function M.disable_danger_mode(opts)
	return M.set_danger_mode(false, opts)
end

---@param opts? { silent?: boolean }
---@return boolean enabled Current danger mode state
function M.toggle_danger_mode(opts)
	return M.set_danger_mode(not state.is_danger_mode_enabled(), opts)
end

---@return boolean
function M.is_danger_mode_enabled()
	return state.is_danger_mode_enabled()
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

--- Show active/recent sessions with per-session status.
function M.active_sessions()
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	lifecycle.ensure_connected(function()
		require("opencode.ui.active_sessions").show()
	end)
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
