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

local ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
local id_last_timestamp = 0
local id_counter = 0

---@return number
local function current_time_ms()
	if vim.uv and type(vim.uv.gettimeofday) == "function" then
		local ok, seconds, microseconds = pcall(vim.uv.gettimeofday)
		if ok and type(seconds) == "number" then
			return (seconds * 1000) + math.floor((microseconds or 0) / 1000)
		end
	end
	return os.time() * 1000
end

---@param len number
---@return string
local function random_base62(len)
	local out = {}
	for i = 1, len do
		local idx = math.random(#ID_CHARS)
		out[i] = ID_CHARS:sub(idx, idx)
	end
	return table.concat(out)
end

---@param prefix string
---@return string
local function ascending_id(prefix)
	local timestamp = current_time_ms()
	if timestamp ~= id_last_timestamp then
		id_last_timestamp = timestamp
		id_counter = 0
	end
	id_counter = (id_counter % 0xfff) + 1

	local value = (timestamp * 0x1000) + id_counter
	local hex = {}
	for shift = 40, 0, -8 do
		local byte = math.floor(value / (2 ^ shift)) % 256
		table.insert(hex, string.format("%02x", byte))
	end
	return prefix .. "_" .. table.concat(hex) .. random_base62(14)
end

---@param sync_module table
---@param session_id string
---@param message_id string
---@param part_id string
---@param text string
---@param agent string|nil
---@param model table|nil
---@param variant string|nil
local function seed_user_message(sync_module, session_id, message_id, part_id, text, agent, model, variant)
	local info = {
		id = message_id,
		sessionID = session_id,
		role = "user",
		time = {
			created = current_time_ms(),
		},
		agent = agent,
	}
	if model then
		info.model = {
			providerID = model.providerID,
			modelID = model.modelID,
			variant = variant,
		}
		info.providerID = model.providerID
		info.modelID = model.modelID
	end

	sync_module.handle_message_updated(info)
	sync_module.handle_part_updated({
		id = part_id,
		messageID = message_id,
		sessionID = session_id,
		type = "text",
		text = text,
	})
end

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

--- Add current file/line plus extra context to the draft input.
---@param context string
---@param opts? { send?: boolean, separator?: string }
---@return boolean
function M.add_current_line_to_input_with_context(context, opts)
	local merged_opts = vim.tbl_extend("force", opts or {}, {
		context = context,
	})
	return M.add_current_line_to_input(merged_opts)
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

--- Add current visual selection plus extra context to the draft input.
---@param context string
---@param opts? { send?: boolean, separator?: string }
---@return boolean
function M.add_visual_selection_to_input_with_context(context, opts)
	local merged_opts = vim.tbl_extend("force", opts or {}, {
		context = context,
	})
	return M.add_visual_selection_to_input(merged_opts)
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
			local logger = require("opencode.logger")

			-- Build message payload
			-- Get model/agent/variant from: 1) opts, 2) local state (user selection), 3) config default
			local model = opts.model
			local agent = opts.agent
			local variant = opts.variant
			local sync_ok, sync = pcall(require, "opencode.sync")

			local function summarize_model_ref(ref)
				if type(ref) ~= "table" then
					return {
						kind = ref == vim.NIL and "vim.NIL" or type(ref),
					}
				end
				return {
					kind = "table",
					providerID = ref.providerID,
					modelID = ref.modelID,
					variant = ref.variant,
				}
			end

			local function resolve_model_ref(ref, source)
				if type(ref) ~= "table" or type(ref.providerID) ~= "string" or type(ref.modelID) ~= "string" then
					logger.debug("Send model candidate skipped", {
						source = source,
						reason = "malformed",
						model = summarize_model_ref(ref),
					})
					return nil
				end
				if ref.providerID == "" or ref.modelID == "" then
					logger.debug("Send model candidate skipped", {
						source = source,
						reason = "empty",
						model = summarize_model_ref(ref),
					})
					return nil
				end
				if not sync_ok or not sync.get_model(ref.providerID, ref.modelID) then
					logger.debug("Send model candidate skipped", {
						source = source,
						reason = sync_ok and "not_in_sync" or "sync_unavailable",
						model = summarize_model_ref(ref),
					})
					return nil
				end
				logger.debug("Send model candidate accepted", {
					source = source,
					model = summarize_model_ref(ref),
				})
				return {
					providerID = ref.providerID,
					modelID = ref.modelID,
				}
			end

			if model then
				local resolved = resolve_model_ref(model, "opts")
				if resolved then
					model = resolved
				else
					logger.debug("Explicit send model dropped after validation miss", {
						model = summarize_model_ref(model),
					})
					model = nil
				end
			end

			-- Try to get from local module (like TUI's local.tsx)
			local local_ok, lc = pcall(require, "opencode.local")
			if local_ok then
				if not model then
					local current_model = lc.model.current()
					model = resolve_model_ref(current_model, "local_current")
				end
				if not agent then
					local current_agent = lc.agent.current()
					if current_agent then
						agent = current_agent.name
						logger.debug("Send agent selected", {
							source = "local_current",
							agent = agent,
						})
					else
						logger.debug("Send agent candidate missing", {
							source = "local_current",
						})
					end
				end
				if not variant then
					variant = lc.variant.current()
				end
			else
				logger.debug("Send local state unavailable", {
					error = tostring(lc),
				})
			end

			-- Fallback to old state module
			if not model then
				local state_model = state.get_model()
				if type(state_model.provider) == "string" and type(state_model.id) == "string" then
					model = resolve_model_ref({
						providerID = state_model.provider,
						modelID = state_model.id,
					}, "legacy_state")
				else
					logger.debug("Send legacy state model skipped", {
						provider = state_model.provider,
						id = state_model.id,
					})
				end

				if not model then
					local default_model = M._config.session.default_model
					model = resolve_model_ref(default_model, "plugin_config_default")
				end
			end

			if not agent then
				local configured_agent = M._config.session.default_agent
				local configured = sync_ok and configured_agent and sync.get_agent(configured_agent) or nil
				if configured and sync.is_visible_agent(configured) then
					agent = configured.name
					logger.debug("Send agent selected", {
						source = "plugin_config_default",
						agent = agent,
					})
				else
					logger.debug("Send configured agent skipped", {
						agent = configured_agent,
						reason = not sync_ok and "sync_unavailable"
							or (not configured and "not_in_sync" or "not_visible"),
					})
				end
			end

			local prompt_message_id = ascending_id("msg")
			local prompt_part_id = ascending_id("prt")
			local payload = {
				messageID = prompt_message_id,
				parts = {
					{ id = prompt_part_id, type = "text", text = message }
				},
				agent = agent,
				model = model,
				variant = variant,
			}

			logger.debug("Resolved prompt payload", {
				session_id = sid,
				agent = agent,
				model = summarize_model_ref(model),
				variant = variant,
				message_id = prompt_message_id,
				text_length = type(message) == "string" and #message or nil,
			})
			local before_message_count = nil
			local before_assistant_count = nil
			if sync_ok then
				local before_messages = sync.get_messages(sid)
				before_message_count = #before_messages
				before_assistant_count = 0
				for _, msg in ipairs(before_messages) do
					if msg.role == "assistant" then
						before_assistant_count = before_assistant_count + 1
					end
				end
			end

			-- Add context if provided
			if opts.context then
				for _, ctx in ipairs(opts.context) do
					table.insert(payload.parts, ctx)
				end
			end

			if sync_ok then
				seed_user_message(sync, sid, prompt_message_id, prompt_part_id, message, agent, model, variant)
				if events and events.emit then
					events.emit("chat_render", { session_id = sid })
				end
			end

			local function handle_prompt_response(response)
				if type(response) ~= "table" then
					return
				end
				local sync_response_ok, sync_response = pcall(require, "opencode.sync")
				if not sync_response_ok then
					return
				end
				if response.info then
					sync_response.handle_message_updated(response.info)
				end
				if type(response.parts) == "table" then
					for _, part in ipairs(response.parts) do
						sync_response.handle_part_updated(part)
					end
				end
				local events_ok, response_events = pcall(require, "opencode.events")
				if events_ok then
					response_events.emit("chat_render", { session_id = sid })
				end
			end

			logger.debug("Sending prompt request", {
				route = "/session/:id/message",
				session_id = sid,
				message_id = prompt_message_id,
			})
			state.set_status("streaming")

			client.send_message(sid, payload, { timeout = 0 }, function(err, response)
				if err then
					logger.debug("Prompt request rejected", {
						session_id = sid,
						error = err.message or err.error or tostring(err),
					})
					vim.schedule(function()
						state.set_status("idle")
						vim.notify("Failed to send message: " .. tostring(err.message or err.error or err), vim.log.levels.ERROR)
						chat.add_message("system", "Error: Failed to send message")
					end)
					return
				end

				logger.debug("Prompt request completed", {
					session_id = sid,
					agent = agent,
					model = summarize_model_ref(model),
					variant = variant,
					has_response = type(response) == "table",
					part_count = type(response) == "table" and type(response.parts) == "table" and #response.parts or nil,
				})

				vim.schedule(function()
					handle_prompt_response(response)
					state.set_status("idle")
				end)

				vim.defer_fn(function()
					local current = state.get_session()
					if current.id ~= sid then
						return
					end
					local current_status = state.get_status()
					if current_status ~= "streaming" then
						return
					end
					local sync_after_ok, sync_after = pcall(require, "opencode.sync")
					local messages = sync_after_ok and sync_after.get_messages(sid) or {}
					local assistant_count = 0
					for _, msg in ipairs(messages) do
						if msg.role == "assistant" then
							assistant_count = assistant_count + 1
						end
					end
					if before_assistant_count and assistant_count <= before_assistant_count then
						logger.warn("No assistant message observed after prompt request", {
							session_id = sid,
							wait_ms = 3000,
							status = current_status,
							before_message_count = before_message_count,
							after_message_count = #messages,
							before_assistant_count = before_assistant_count,
							after_assistant_count = assistant_count,
						})
					end
				end, 3000)
			end)
		end

		if session_id then
			-- Use existing session
			send_with_session(session_id)
		else
			-- Create new session first
			local session_opts = vim.empty_dict()
			if type(opts.title) == "string" and opts.title ~= "" then
				session_opts.title = opts.title
			end

			client.create_session(session_opts, function(err, session)
				if err or not session then
					vim.schedule(function()
						local message = err and (err.message or err.error) or "unknown"
						vim.notify("Failed to create session: " .. tostring(message), vim.log.levels.ERROR)
						chat.add_message("system", "Error: Failed to create session")
					end)
					return
				end

				-- Store session info
				vim.schedule(function()
					state.set_session(session.id, session.title or "New session")
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
				state.set_session(session.id, session.title or "New session")
				
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
