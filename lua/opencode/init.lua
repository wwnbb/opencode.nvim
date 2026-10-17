-- opencode.nvim - Neovim frontend for OpenCode AI coding agent

local M = {}

M.version = "0.1.0"

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

---@param bufnr number
---@param text string
---@return string
local function _fence_code(bufnr, text)
	local language = vim.bo[bufnr].filetype
	if language == "" then
		language = vim.filetype.match({ filename = vim.api.nvim_buf_get_name(bufnr) }) or ""
	end

	return require("opencode.util.text").fence_code(text, language)
end

local function _format_code_prompt(bufnr, filepath, line_ref, text, opts)
	local display_path = vim.fn.fnamemodify(filepath, ":~:.")
	if display_path == "" then display_path = filepath end
	local parts = { string.format("@%s#%s", display_path, line_ref), _fence_code(bufnr, text) }
	local context = opts.context and vim.trim(opts.context) or ""
	if context ~= "" then table.insert(parts, "Context: " .. context) end
	return table.concat(parts, "\n")
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
	return _format_code_prompt(bufnr, filepath, line_num, line_text, opts)
end

---@param opts? { context?: string }
---@return string|nil
local function _build_visual_selection_prompt(opts)
	opts = opts or {}
	local selection, selection_err = require("opencode.util.visual_selection").capture()
	if not selection then
		vim.notify("OpenCode: " .. selection_err, vim.log.levels.WARN)
		return nil
	end
	local bufnr, filepath = selection.bufnr, selection.path
	if filepath == "" then
		vim.notify("OpenCode: current buffer has no file path", vim.log.levels.WARN)
		return nil
	end

	local line_ref = tostring(selection.start_line)
	if selection.start_line ~= selection.end_line then
		line_ref = string.format("%d-%d", selection.start_line, selection.end_line)
	end

	return _format_code_prompt(bufnr, filepath, line_ref, selection.text, opts)
end

--- Setup function - called by user to configure the plugin
---@param opts table Configuration options
function M.setup(opts)
	M._config = config.merge(opts)

	M._config = require("opencode.settings").setup(M._config)
	state.set_config(M._config)
	require("opencode.commands").configure_keymaps(M._config.keymaps)
	require("opencode.editor_context").setup()
	state.set_danger_mode(M._config.danger_mode == true)
	state.set_server_info({
		host = M._config.server.host,
		port = M._config.server.port,
		url = M._config.server.url or false,
	})

	-- Initialize events module (before client/lifecycle for bridge setup)
	local events_ok
	events_ok, events = pcall(require, "opencode.events")
	if not events_ok then
		vim.notify("Failed to load opencode events: " .. tostring(events), vim.log.levels.ERROR)
		return
	end

	events.setup()

	local client_ok
	client_ok, client = pcall(require, "opencode.client")
	if not client_ok then
		vim.notify("Failed to load opencode client: " .. tostring(client), vim.log.levels.ERROR)
		return
	end

	client.setup({
		url = M._config.server.url or false,
		host = M._config.server.host,
		port = M._config.server.port,
		tls = M._config.server.tls,
		auth = M._config.server.auth,
		timeout = M._config.server.timeout,
		reconnect = true,
	})
	require("opencode.session.tabs").setup(events)

	local lifecycle_ok
	lifecycle_ok, lifecycle = pcall(require, "opencode.lifecycle")
	if not lifecycle_ok then
		vim.notify("Failed to load opencode lifecycle: " .. tostring(lifecycle), vim.log.levels.ERROR)
		lifecycle = nil
		return
	end

	lifecycle.setup({
		command = M._config.server.command,
		url = M._config.server.url or false,
		managed = M._config.server.managed,
		service_file = M._config.server.service_file or false,
		tls = M._config.server.tls,
		port = M._config.server.port,
		auto_start = M._config.server.auto_start,
		startup_timeout = M._config.server.startup_timeout,
		health_check_interval = M._config.server.health_check_interval,
		shutdown_on_exit = M._config.server.shutdown_on_exit,
		use_shell_env = M._config.server.use_shell_env,
		env = M._config.server.env,
		auth = M._config.server.auth,
		config_dir = M._config.server.config_dir,
		completion = M._config.completion,
		explanation = M._config.explanation,
	})
	require("opencode.completion").setup(M._config.completion)
	require("opencode.explanation").setup(M._config.explanation)

	M.state = state

  if M._config.lualine and M._config.lualine.enabled ~= false then
    local lualine_ok, lualine = pcall(require, "opencode.components.lualine")
    if lualine_ok then
      lualine.setup(M._config.lualine)
      M.lualine = lualine
    end
  end

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

  -- blend only hides the background; matching Normal's background also hides the cursor foreground.
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

  local highlight_augroup = vim.api.nvim_create_augroup("OpenCodeHighlights", { clear = true })
  local function refresh_highlights_after_colorscheme()
    setup_hidden_cursor_highlight()
    local chat = package.loaded["opencode.ui.chat"]
    if chat and type(chat.handle_colorscheme) == "function" then
      chat.handle_colorscheme()
    end
  end

  setup_hidden_cursor_highlight()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = highlight_augroup,
    callback = refresh_highlights_after_colorscheme,
    desc = "Update OpenCode highlights on colorscheme change",
  })

  vim.api.nvim_create_autocmd("FileType", {
    group = highlight_augroup,
    pattern = "opencode",
    callback = function()
      local cursor_hls = "Cursor:OpenCodeHiddenCursor,lCursor:OpenCodeHiddenCursor,CursorLine:OpenCodeHiddenCursor,CursorColumn:OpenCodeHiddenCursor"
      vim.wo.winhighlight = (vim.wo.winhighlight ~= "" and vim.wo.winhighlight .. "," or "") .. cursor_hls
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

-- A session response must not take focus back after the user leaves its owner.
local function with_session_focus(owner, create)
	local cs = require("opencode.ui.chat.state")
	local workspace = require("opencode.ui.chat.workspace")
	local window, previous = vim.api.nvim_get_current_win(), workspace.current()
	local input = require("opencode.ui.input")
	local in_input = vim.tbl_contains(input.get_winids(), window)
	local background = cs.for_window(window) ~= owner
		and not (input.owner_view() == owner and in_input)
	local restore_input = background and in_input and input.suspend()
	local ok, err = xpcall(create, debug.traceback)
	if background then
		if previous and workspace.current() ~= previous then workspace.select(previous.id) end
		if restore_input then restore_input()
		elseif vim.api.nvim_win_is_valid(window) then vim.api.nvim_set_current_win(window) end
	end
	if not ok then error(err) end
end

--- Create an independent chat beside the focused chat in the OpenCode tab.
---@param direction "vertical"|"horizontal"
function M.split(direction, opts)
	if direction ~= "vertical" and direction ~= "horizontal" then
		vim.notify("OpenCode split expects vertical or horizontal", vim.log.levels.ERROR)
		return false
	end
	if ((state.get_config() or {}).chat or {}).layout ~= "tab" then
		vim.notify('Set chat.layout = "tab" to split OpenCode chats', vim.log.levels.INFO)
		return false
	end
	if not lifecycle then return false end
	local cs = require("opencode.ui.chat.state")
	local chat = require("opencode.ui.chat")
	if not (opts and opts.view) then chat.open() end
	local owner = opts and opts.view or chat.get_view()
	if not cs.valid(owner, opts and opts.generation) or not (owner.visible or owner.suspended) then return false end
	local generation = owner.generation
	local session = cs.session(owner)
	local directory = state.get_session_directory(session.id) or vim.fn.getcwd()
	local pending = require("opencode.session.pending")
	local token = pending.token(session.id)
	lifecycle.ensure_connected(function()
		if not pending.is_current(token) or not cs.valid(owner, generation) or not (owner.visible or owner.suspended) then return end
		client.create_session({ location = { directory = directory } }, function(err, created)
			vim.schedule(function()
				if not pending.is_current(token) then return end
				if err then
					vim.notify("Failed to create split session: " .. tostring(err.message or err), vim.log.levels.ERROR)
					return
				end
				session_actions.remember(created)
				if not pending.is_current(token) or not cs.valid(owner, generation) or not (owner.visible or owner.suspended) then return end
				with_session_focus(owner, function() chat.create_split(owner, created, direction) end)
			end)
		end)
	end)
	return true
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

	local input = require("opencode.ui.input")
	local cs = require("opencode.ui.chat.state")
	local view, snapshot, context_error = cs.current()
	local generation = view.generation
	if not input.is_visible() then snapshot, context_error = input.capture_context(cs.session(view).id) end
	lifecycle.ensure_connected(function()
		if not cs.valid(view, generation) then return end
		local chat = require("opencode.ui.chat")
		local target = view.session_bound and chat.for_view(view) or chat
		target.focus_input(snapshot, context_error)
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

	local prompt = _build_current_line_prompt(opts)
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

	local prompt = _build_visual_selection_prompt(opts)
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
---@param opts? table Additional options; range = { start_line, end_line } uses inclusive 1-based source lines.
function M.send(message, opts)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	local cs = require("opencode.ui.chat.state")
	local owner = opts and opts.view or cs.current()
	local captured = vim.deepcopy(vim.tbl_extend("force", opts or {}, { view = false }))
	captured.view, captured._view_id, captured._view_generation = nil, nil, nil
	if owner and owner.session_bound then
		captured._view_id, captured._view_generation = owner.id, owner.generation
	end
	if captured.mode ~= "shell" and type(message) == "string" and not message:match("^%s*/") then
		local context = require("opencode.context")
		if not captured._context_snapshot and not captured._context_error and (captured.range ~= nil or context.has(message, captured)) then
			captured._context_snapshot, captured._context_error = context.capture({ range = captured.range })
		end
	end
	if captured.session_id == nil then captured.session_id = (owner and cs.session(owner).id) or state.get_session().id or false end
	captured.directory = captured.directory or state.get_session_directory(captured.session_id) or vim.fn.getcwd()
	captured._token = require("opencode.session.pending").token(captured.session_id or nil)
	captured._selection = require("opencode.selectors").send_selection(captured)
	lifecycle.ensure_connected(function()
		require("opencode.send").send(message, captured)
	end)
end

--- Request a new inline code completion at the Insert-mode cursor.
function M.complete()
	return require("opencode.completion").complete()
end

--- Ask for an instruction to complete at the Insert cursor or edit a Visual selection.
function M.complete_with_prompt()
	return require("opencode.completion").complete_with_prompt()
end

--- Accept the suggestion at the cursor, waiting if needed; safe for expr/snippet mappings.
function M.accept_completion()
	return require("opencode.completion").accept()
end

--- Cancel all editor completion requests.
function M.dismiss_completion()
	return require("opencode.completion").dismiss()
end

--- Whether the current buffer has a visible editor completion suggestion.
function M.completion_visible()
	return require("opencode.completion").visible()
end

--- Explain the current Visual selection in a temporary popup.
function M.explain_selection()
	return require("opencode.explanation").explain_selection()
end

--- Ask a transient question using the active session's context and model.
---@param question string
---@param owner_session_id? string Session that opened a question dialog.
---@return boolean
function M.ask_btw(question, owner_session_id)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return false
	end
	local session_id = owner_session_id or state.get_session().id
	if not session_id then
		vim.notify("No active session for /btw", vim.log.levels.WARN)
		return false
	end
	if owner_session_id and not state.get_session_record(session_id) then
		vim.notify("Session was deleted before /btw was submitted", vim.log.levels.WARN)
		return false
	end
	if vim.trim(question or "") == "" then
		vim.notify("Usage: /btw <question>", vim.log.levels.WARN)
		return false
	end
	local pending = require("opencode.session.pending")
	local token = pending.token(session_id)
	lifecycle.ensure_connected(function()
		if not pending.is_current(token) then return end
		if not state.get_session_record(session_id) then
			vim.notify("Session was deleted before /btw could start", vim.log.levels.WARN)
			return
		end
		require("opencode.btw").ask(session_id, question)
	end)
	return true
end

--- Abort/stop the current generation
--- Similar to pressing Escape or clicking stop in the TUI
function M.abort(opts)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	local session_id
	if opts and (opts.session_id ~= nil or opts.view) then session_id = opts.session_id
	else session_id = state.get_session().id end
	if not session_id then
		vim.notify("No active session to abort", vim.log.levels.WARN)
		return
	end

	local pending = require("opencode.session.pending")
	local token = pending.token(session_id)
	require("opencode.client").abort_session(session_id, function(err)
		if not pending.is_current(token) then return end
		if err then
			vim.notify("Failed to interrupt: " .. tostring(err.message or err.error or err), vim.log.levels.ERROR)
		end
		-- Interrupt acknowledges a request; SSE and active recovery establish
		-- completion. Queued inbox items remain pending (resume=false).
		require("opencode.events").emit("session_reconcile", { session_id = session_id })
		session_actions.refresh_status()
	end)
end

--- Start a fresh chat and close the previous tab after creation succeeds.
---@param opts? { silent?: boolean }
function M.clear(opts)
	local input = require("opencode.ui.input")
	local sid = opts and opts.session_id or state.get_session().id or ""
	local history = require("opencode.ui.input.history")
	local draft = { token = input.draft_token(), session_id = sid,
		text = history.get_pending(sid), parts = history.get_pending_parts(sid) }
	return M.new_session(vim.tbl_extend("force", opts or {}, {
		close_previous = true, reason = "clear", clear_draft = draft,
	}))
end

--- Start a new root session and make it active.
---@param opts? { silent?: boolean, close_previous?: boolean, reason?: string, clear_draft?: table, location?: table }
function M.new_session(opts)
	local cs = require("opencode.ui.chat.state")
	local owner = opts and opts.view or cs.current()
	if not (owner and owner.session_bound) then owner = nil end
	local generation = owner and owner.generation
	local owner_was_visible = owner and owner.visible
	local current_session = owner and cs.session(owner) or state.get_session()
	local directory = owner and state.get_session_directory(current_session.id)
	opts = vim.deepcopy(vim.tbl_extend("force", opts or {}, { view = false }))
	opts.view = nil

	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	local pending = require("opencode.session.pending")
	local token = pending.token()
	lifecycle.ensure_connected(function()
		if not pending.is_current(token) then return end
		local sync = require("opencode.sync")
		if owner and not cs.valid(owner, generation) then return end
		local cfg = state.get_config() or {}
		local parallel = cfg.session and cfg.session.parallel or {}
		local preserve_cache = parallel.enabled ~= false

		local location = opts.location or (directory and { directory = directory })
		client.create_session(location and { location = location } or {}, function(err, session)
			vim.schedule(function()
				if not pending.is_current(token) then return end
				if err then
					vim.notify("Failed to create new session: " .. tostring(err.message or err.error or err), vim.log.levels.ERROR)
					return
				end

				session_actions.remember(session)
				if owner and (not cs.valid(owner, generation) or (owner_was_visible and not owner.visible and not owner.suspended)) then return end
				local activate_opts = { reason = opts.reason or "new_session", preserve_cache = true }
				if owner and owner.config.layout == "tab" and owner.workspace_id and not opts.close_previous then
					with_session_focus(owner, function() require("opencode.ui.chat").create_layout(session) end)
				elseif owner then
					require("opencode.ui.chat").bind_session(owner, session, activate_opts)
				else
					session_actions.set_active(session.id, session.title or "New session", activate_opts)
				end
				if current_session.id and current_session.id ~= session.id then
					if opts.close_previous then
						session_actions.close(current_session.id, { silent = true, reason = opts.reason or "clear" })
					elseif not preserve_cache and not cs.for_session(current_session.id) then
						sync.clear_session(current_session.id)
					end
				end
				if opts.clear_draft then
					local input = require("opencode.ui.input")
					local history = require("opencode.ui.input.history")
					local draft = opts.clear_draft
					if input.draft_token() == draft.token and history.get_pending(draft.session_id) == draft.text
						and vim.deep_equal(history.get_pending_parts(draft.session_id), draft.parts) then
						history.clear_pending(draft.session_id)
					end
				end

				local render_ok, render_coordinator = pcall(require, "opencode.ui.chat.render_coordinator")
				if render_ok then
					render_coordinator.request({
						session_id = session.id,
						reason = opts.reason or "new_session",
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
	if opts.view and not opts.session_id then return require("opencode.ui.chat").close_view(opts.view) end
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
	return lifecycle and state.is_connected() or false
end

--- Check if currently streaming
---@return boolean
function M.is_streaming()
	return state.get_status() == "streaming"
end

--- Get the project directory for the active session, falling back to the
--- current working directory when no session is active or the session has
--- no directory recorded.
---@return string directory Absolute directory path
function M.get_directory()
	local session = state.get_session()
	if session and session.id then
		local dir = state.get_session_directory(session.id)
		if dir and dir ~= "" then
			return dir
		end
	end
	return vim.fn.getcwd()
end

---@param enabled boolean
---@param opts? { silent?: boolean }
---@return boolean enabled Current danger mode state
function M.set_danger_mode(enabled, opts)
	opts = opts or {}
	local current = enabled == true
	state.set_danger_mode(current)

	local pending_count = 0
	local danger_ok, danger = pcall(require, "opencode.permission.danger")
	if current then
		if danger_ok and type(danger.approve_pending) == "function" then
			pending_count = danger.approve_pending()
		end
	else
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

	local palette = require("opencode.ui.palette")
	local context = palette.capture_context()
	local tabpage = vim.api.nvim_get_current_tabpage()
	lifecycle.ensure_connected(function()
		if vim.api.nvim_get_current_tabpage() ~= tabpage then return end
		local owner = context.view
		if owner and (not owner.visible or not owner.winid or not vim.api.nvim_win_is_valid(owner.winid)) then return end
		if palette.context_valid(context) then palette.show(context) end
	end)
end

--- Show active/recent sessions with per-session status.
function M.active_sessions(context)
	if not lifecycle then
		vim.notify("OpenCode not initialized", vim.log.levels.ERROR)
		return
	end

	local palette = require("opencode.ui.palette")
	context = palette.capture_context(context)
	lifecycle.ensure_connected(function()
		if palette.context_valid(context) then require("opencode.ui.active_sessions").show(context) end
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
