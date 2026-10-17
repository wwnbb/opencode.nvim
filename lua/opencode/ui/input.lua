-- opencode.nvim - Input area facade

local M = {}

local attachments = require("opencode.ui.input.attachments")
local autocomplete = require("opencode.ui.input.autocomplete")
local autocmds = require("opencode.ui.input.autocmds")
local command_registry = require("opencode.command_registry")
local history = require("opencode.ui.input.history")
local history_search = require("opencode.ui.input.history_search")
local info_bar = require("opencode.ui.input.info_bar")
local keymaps = require("opencode.ui.input.keymaps")
local layout = require("opencode.ui.input.layout")
local mentions = require("opencode.ui.input.mentions")
local popups = require("opencode.ui.input.popups")
local syntax = require("opencode.ui.input.syntax")

local state = {
	bufnr = nil,
	winid = nil,
	parent_winid = nil,
	view = nil,
	view_generation = nil,
	explicit_session = false,
	popup = nil,
	info_popup = nil,
	info_bufnr = nil,
	visible = false,
	on_send = nil,
	on_cancel = nil,
	close_on_send = true,
	allow_chat_commands = false,
	allow_context = false,
	persist_pending = true,
	session_bound = false,
	add_history = true,
	config = nil,
	layout = nil,
	parts = {},
	session_id = nil,
	mode = "normal",
	send_options = nil,
	editor_context = nil,
	context_snapshot = nil,
	context_error = nil,
	autocomplete = nil,
	mentions = nil,
	normalizing_paste = false,
	resize_scheduled = false,
}

local function refresh_context_snapshot(snapshot, err)
	state.context_snapshot, state.context_error = nil, nil
	if not state.allow_context then return end
	local range = state.send_options and state.send_options.range
	if err or (snapshot and vim.deep_equal(snapshot.range, range)) then
		state.context_snapshot, state.context_error = snapshot, err
	else
		state.context_snapshot, state.context_error = require("opencode.context").capture({ range = range })
	end
end
local pending_cursor
local draft_epoch = 0

local function copy_parts(parts)
	return history.copy_parts(parts)
end

local function get_input_text()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return ""
	end

	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	return table.concat(lines, "\n")
end

local function current_session_id()
	return require("opencode.state").get_session().id
end

local function owner_valid()
	if not state.view then return true end
	local views = require("opencode.ui.chat.state")
	return views.valid(state.view, state.view_generation) and views.session(state.view).id == state.session_id
end

local function draft_parts()
	local parts = copy_parts(state.parts)
	for _, part in ipairs(mentions.active_parts(state)) do
		local copy = vim.deepcopy(part)
		local source = type(copy.source) == "table" and (copy.source.text or copy.source) or nil
		copy._marker = type(source) == "table" and source.value or nil
		parts[#parts + 1] = copy
	end
	return parts
end

local function skill_id(part)
	local id = type(part) == "table" and (part.skillID or part.id) or nil
	return type(id) == "string" and id ~= "" and id or nil
end

local function skill_session_error(parts, session_id)
	for _, part in ipairs(parts) do
		if type(part) == "table" and part.type == "skill" and part._session_id and part._session_id ~= session_id then
			return "Selected skills belong to another session; return to that session before sending or selecting skills"
		end
	end
end

local function marker_range(text, marker, source)
	if type(marker) ~= "string" or marker == "" then return nil end
	local function boundary(index, direction)
		local char = text:sub(index, index)
		-- A terminal period is punctuation; a dot within an identifier is not.
		while char == "." do index = index + direction; char = text:sub(index, index) end
		return index < 1 or index > #text or char:match("[%s,;:!?%(%){%}%[%]<>\"']") ~= nil
	end
	local first = type(source) == "table" and source.start
	local last = type(source) == "table" and source["end"]
	if type(first) == "number" and type(last) == "number" and first >= 0 and last <= #text
		and first % 1 == 0 and last - first == #marker and text:sub(first + 1, last) == marker
		and boundary(first, -1) and boundary(last + 1, 1) then return first + 1, last end
	local from = 1
	while true do
		local first, last = text:find(marker, from, true)
		if not first then return nil end
		if boundary(first - 1, -1) and boundary(last + 1, 1) then return first, last end
		from = last + 1
	end
end
state.marker_range = marker_range

local function remember_cursor(text)
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then return end
	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, cursor[1] - 1, false)
	local offset = cursor[2]
	for _, line in ipairs(lines) do offset = offset + #line + 1 end
	pending_cursor = { text = text, session_id = state.session_id, offset = math.min(offset, #text) }
	history.set_pending_cursor(pending_cursor.offset, state.session_id)
end

local function saved_cursor(text, session_id)
	if pending_cursor and pending_cursor.text == text and pending_cursor.session_id == session_id then
		return pending_cursor.offset
	end
	if history.get_pending(session_id) == text then return history.get_pending_cursor(session_id) end
end

local function restore_cursor(text)
	local offset = saved_cursor(text, state.session_id)
	if offset == nil then return false end
	local lines = vim.split(text:sub(1, offset), "\n", { plain = true })
	vim.api.nvim_win_set_cursor(state.winid, { #lines, #lines[#lines] })
	return true
end

local function save_pending()
	if not state.visible or not state.persist_pending or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
	local search = state.history_search and state.history_search.draft
	local text = search and search.text or get_input_text()
	history.set_pending(text, search and search.parts or draft_parts(), state.session_id)
	history.set_pending_mode(search and search.mode or state.mode, state.session_id)
	history.set_pending_options(search and search.options or state.send_options, state.session_id)
	local offset = saved_cursor(text, state.session_id)
	if not search and not (pending_cursor and pending_cursor.locked and offset ~= nil)
		and (vim.api.nvim_get_current_win() == state.winid or offset == nil) then
		remember_cursor(text)
	else
		history.set_pending_cursor(offset, state.session_id)
	end
end

local function refresh_completion()
	if not history_search.refresh(state) and autocomplete.is_visible(state) then autocomplete.refresh(state) end
end

local function resize_input()
	layout.resize(state)
	refresh_completion()
end

local function schedule_resize_input()
	layout.schedule_resize(state, refresh_completion)
end

local function set_input_text(text)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local content = text or ""
	local lines = vim.split(content, "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end
	if state.paste_folds and state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_call(state.winid, function() vim.cmd("silent! normal! zE") end)
		state.paste_folds = nil
	end

	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_set_cursor(state.winid, { #lines, #lines[#lines] })
	end
	resize_input()
end

local function clear_input()
	state.parts = {}
	autocomplete.reset(state)
	mentions.reset(state)
	set_input_text("")
	info_bar.update(state)
end

local function focus_parent_before_unmount()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end
	if vim.api.nvim_get_current_win() ~= state.winid then
		return
	end
	if state.parent_winid and vim.api.nvim_win_is_valid(state.parent_winid) then
		pcall(vim.api.nvim_set_current_win, state.parent_winid)
	end
end

local function resolve_config()
	local config_defaults = require("opencode.config").defaults.input
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}

	return vim.tbl_deep_extend("force", vim.deepcopy(config_defaults), full_config.input or {})
end

local function resume_chat_input(session_id)
	local view, generation = state.view, state.view_generation
	return function()
		if current_session_id() ~= session_id then return end
		if view then
			local views = require("opencode.ui.chat.state")
			if not views.valid(view, generation) or views.session(view).id ~= session_id then return end
		end
		local chat = require("opencode.ui.chat")
		if chat.is_visible() then chat.focus_input() end
	end
end

local function selected_command_context()
	local session_id = state.session_id
	return { source = "slash_select", session_id = session_id, view = state.view, generation = state.view_generation,
		args = "", resume_input = resume_chat_input(session_id) }
end

local function command_enter_mode()
	if state.mode == "shell" then return nil end
	if not state.allow_chat_commands or not owner_valid() or state.session_id ~= current_session_id() then return nil end
	local parsed = require("opencode.slash").parse(get_input_text())
	if not parsed then return nil end
	local command = command_registry.get_slash(parsed.command)
	if not command or not command_registry.enabled(command) then return nil end
	local has_args = vim.trim(parsed.args or "") ~= ""
	if not has_args and command.on_select then
		if command.with_parts == "reject" and #draft_parts() > 0 then return "submit" end
		return "select"
	end
	if has_args and command.enter_with_args then return "submit" end
	return nil
end

local function select_typed_command()
	if command_enter_mode() ~= "select" then return false end
	local original = get_input_text()
	local parsed = require("opencode.slash").parse(original)
	local command = parsed and command_registry.get_slash(parsed.command)
	if not command then return false end
	set_input_text("")
	autocomplete.close(state)
	local ok = command_registry.select(command.id, selected_command_context())
	if not ok and state.visible then set_input_text(original) end
	return ok
end

local function send_message(delivery)
	if not owner_valid() then return end
	if history_search.confirm(state) then return end
	if state.session_id ~= current_session_id() then
		vim.notify("The active session changed; reopen this draft in its session", vim.log.levels.WARN)
		return
	end
	local text = get_input_text()
	if state.mode ~= "shell" and attachments.has_image_file_hint(text) then
		attachments.normalize_pasted_image_paths(state, resize_input)
		text = get_input_text()
	end

	local parts = vim.tbl_filter(function(part)
		if part.type == "skill" and part._session_id then return marker_range(text, "@" .. (skill_id(part) or "")) ~= nil end
		if part.type == "agent" then
			local source = type(part.source) == "table" and (part.source.text or part.source) or nil
			return type(source) ~= "table" or type(source.value) ~= "string" or marker_range(text, source.value) ~= nil
		end
		return true
	end, attachments.active_parts_for_text(state, text))
	for _, part in ipairs(mentions.active_parts(state)) do
		table.insert(parts, part)
	end
	if text == "" and #parts == 0 then
		if delivery == "steer" and state.mode ~= "shell" and current_session_id() then
			require("opencode.actions").promote_queued_input(current_session_id(), function(err)
				if err then vim.notify("Could not promote queued prompt: " .. tostring(err.message or err), vim.log.levels.WARN) end
			end)
		end
		return
	end
	local session_error = skill_session_error(parts, current_session_id())
	if session_error then
		vim.notify(session_error, vim.log.levels.WARN)
		return
	end
	-- Markers can move while a draft is edited. Resolve their current byte range
	-- just before the native request converts it into display-cell coordinates.
	for _, part in ipairs(parts) do
		local source = type(part.source) == "table" and (part.source.text or part.source) or nil
		local marker = part.type == "skill" and skill_id(part) and ("@" .. skill_id(part))
			or part.type == "agent" and type(source) == "table" and source.value
		if type(marker) == "string" then
			local first, last = marker_range(text, marker, source)
			part.source = first and { text = { start = first - 1, ["end"] = last, value = marker } } or nil
		end
	end
	draft_epoch, pending_cursor = draft_epoch + 1, nil

	if state.add_history then
		history.add(text, parts, state.mode, state.session_id)
	end
	local send_options = state.send_options and vim.deepcopy(state.send_options) or nil
	local normal_prompt = state.mode ~= "shell" and not text:match("^%s*/")
	local explicit_context = normal_prompt and state.allow_context
		and require("opencode.context").has(text, { parts = parts, context = send_options and send_options.context })
	if normal_prompt and state.allow_context and (explicit_context or (send_options and send_options.range ~= nil)) then
		send_options = send_options or {}
		send_options._context_snapshot = state.context_snapshot
		send_options._context_error = state.context_error
	end
	if normal_prompt and not explicit_context and state.editor_context then
		send_options = send_options or {}
		send_options.context = send_options.context or {}
		local found
		for _, part in ipairs(send_options.context) do if part._editor_context then found = part; break end end
		if not found then send_options.context[#send_options.context + 1] = vim.deepcopy(state.editor_context) end
		require("opencode.actions").mark_editor_context(state.session_id, found or state.editor_context, "sent")
		state.editor_context = nil
	end
	if state.mode == "shell" then
		send_options = send_options or {}
		send_options.mode = "shell"
	end
	if delivery then
		send_options = send_options or {}
		send_options.delivery = delivery
	end
	if state.persist_pending then
		history.clear_pending(state.session_id)
	end

	local bufnr, close_on_send, on_send = state.bufnr, state.close_on_send, state.on_send
	clear_input()

	if on_send then
		on_send(text, parts, send_options)
	end
	if close_on_send and state.bufnr == bufnr then
		M.close(false)
	end
end

local function cancel_input()
	if history_search.cancel(state) then return end
	local bufnr = state.bufnr
	local text = get_input_text()
	if state.on_cancel then
		state.on_cancel(text)
	end
	if state.bufnr == bufnr then M.close() end
end

local function recall_history(text, parts, mode)
	if text == nil then return end
	draft_epoch, pending_cursor = draft_epoch + 1, nil
	state.parts = copy_parts(parts)
	state.mode = mode == "shell" and "shell" or "normal"
	for _, part in ipairs(state.parts) do
		if part.type == "skill" then part._session_id = current_session_id() end
	end
	autocomplete.reset(state)
	mentions.reset(state)
	set_input_text(text)
	info_bar.update(state)
end

local function history_prev()
	recall_history(history.previous(get_input_text(), draft_parts(), state.mode, state.session_id))
end

local function history_next()
	recall_history(history.next(get_input_text(), draft_parts(), state.mode, state.session_id))
end

local function insert_text_at_cursor(text)
	return attachments.insert_text_at_cursor(state, text, schedule_resize_input)
end

local function mount_input(chat_winid, float_dims, cfg)
	local frame = layout.build(chat_winid, float_dims, cfg, state.view and state.view.session_bound)
	state.layout = frame.layout
	state.popup, state.info_popup = popups.mount(frame)
	state.bufnr = state.popup.bufnr
	state.winid = state.popup.winid
	state.info_bufnr = state.info_popup.bufnr
	state.visible = true
	state.mentions = {
		parts = {},
	}
	state.autocomplete = {}

	vim.api.nvim_buf_set_var(state.bufnr, "completion", false)
	syntax.attach(state.bufnr)
end

local function session_changed(session_id)
	if not state.visible or state.session_id == session_id then return end
	history_search.cancel(state)
	if (state.view and state.view.session_bound) or state.explicit_session or not state.persist_pending or state.session_bound then M.close(state.persist_pending); return end
	save_pending()
	pending_cursor = nil
	state.session_id = session_id
	state.parts = history.get_pending_parts(session_id)
	state.mode = history.get_pending_mode(session_id)
	state.send_options = history.get_pending_options(session_id)
	refresh_context_snapshot(state.context_snapshot)
	state.editor_context = require("opencode.editor_context").pending(session_id)
	autocomplete.reset(state)
	mentions.reset(state)
	local next_text = history.get_pending(session_id)
	set_input_text(next_text)
	info_bar.update(state)
	restore_cursor(next_text)
end

-- Usage metadata changes independently of typing. Observe only while mounted,
-- and coalesce SSE bursts without taking focus or retaining history.
local info_refresh_scheduled = false
local function refresh_info()
	if not state.visible or info_refresh_scheduled then return end
	info_refresh_scheduled = true
	vim.schedule(function()
		info_refresh_scheduled = false
		info_bar.update(state)
	end)
end

-- Capture before chat layout/focus changes, including a deferred prompt edit.
function M.capture_context(session_id)
	session_id = session_id or current_session_id()
	local options = history.get_pending_options(session_id)
	if history.get_pending(session_id) == "" and #history.get_pending_parts(session_id) == 0 then
		local deferred = history.peek_deferred(session_id)
		if deferred then options = deferred.options end
	end
	return require("opencode.context").capture({ range = options and options.range })
end

function M.show(opts)
	opts = opts or {}
	local view = opts.view
	local session_id = opts.session_id or (view and require("opencode.ui.chat.state").session(view).id) or current_session_id()
	if view then
		local views = require("opencode.ui.chat.state")
		if not views.valid(view) or views.session(view).id ~= session_id then return false end
	end

	if state.visible then
		if (view and (view ~= state.view or view.generation ~= state.view_generation or session_id ~= state.session_id))
			or (opts.session_id ~= nil and session_id ~= state.session_id) then
			M.close()
		else
			return M.focus()
		end
	end
	if opts.text ~= nil then draft_epoch, pending_cursor = draft_epoch + 1, nil end

	local cfg = resolve_config()
	history.configure(cfg)
	history.load()
	local chat_winid = opts.winid or (view and view.winid)
	if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
		chat_winid = vim.api.nvim_get_current_win()
	end
	if view and view.session_bound and not opts.float_dims and not layout.can_fit(chat_winid) then
		if opts.persist_pending ~= false and opts.text ~= nil then
			history.set_pending(opts.text, copy_parts(opts.parts), session_id)
			history.set_pending_mode(opts.mode or "normal", session_id)
			history.set_pending_options(opts.send_options, session_id)
		end
		vim.notify("Enlarge the chat pane before opening input", vim.log.levels.INFO)
		return false
	end

	state.config = cfg
	state.on_send = opts.on_send
	state.on_cancel = opts.on_cancel or function() end
	state.close_on_send = opts.close_on_send ~= false
	state.allow_chat_commands = opts.allow_chat_commands == true or opts.allow_skill_picker == true
	state.allow_context = opts.allow_chat_commands == true or opts.allow_context == true
	state.persist_pending = opts.persist_pending ~= false
	state.session_bound = opts.session_bound == true
	state.add_history = opts.add_history ~= false
	state.view, state.view_generation = view, view and view.generation
	state.explicit_session = opts.session_id ~= nil and not (view and not view.session_bound)
	state.session_id = session_id
	state.parts = opts.text ~= nil and copy_parts(opts.parts) or history.get_pending_parts(state.session_id)
	state.mode = opts.mode or (opts.text ~= nil and "normal" or history.get_pending_mode(state.session_id))
	state.send_options = opts.send_options or (opts.text == nil and history.get_pending_options(state.session_id)) or nil
	refresh_context_snapshot(opts.context_snapshot, opts.context_error)
	state.editor_context = opts.session_bound ~= true and require("opencode.editor_context").pending(state.session_id) or nil

	autocomplete.setup_highlights()
	info_bar.setup_highlights()
	mentions.setup_highlights()

	state.parent_winid = chat_winid

	mount_input(chat_winid, opts.float_dims, cfg)
	require("opencode.state").on("session.id", session_changed)
	for _, event in ipairs({ "sync_changed", "sessions_changed", "config_change" }) do require("opencode.events").on(event, refresh_info) end

	autocmds.setup(state, {
		schedule_resize = schedule_resize_input,
		reflow = function()
			if state.layout.constrain_to_parent and state.parent_winid and vim.api.nvim_win_is_valid(state.parent_winid)
				and not layout.can_fit(state.parent_winid) then M.close(); return end
			layout.reflow(state); refresh_completion(); info_bar.update(state)
		end,
		input_changed = function()
			if not history_search.refresh(state) and state.mode ~= "shell" then autocomplete.refresh(state) end
			info_bar.update(state)
		end,
		cursor_moved = function()
			if not history_search.refresh(state) and state.mode ~= "shell" then autocomplete.refresh(state) end
			if state.paste_folds then schedule_resize_input() end
		end,
		insert_leave = function()
			history_search.cancel(state)
			autocomplete.close(state)
			if state.paste_folds then schedule_resize_input() end
		end,
		lock_scroll = function()
			layout.lock_scroll(state)
		end,
		close = function()
			M.close()
		end,
	})
	-- Native tab closure wipes the draft before scheduled popup teardown runs.
	vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
		buffer = state.bufnr,
		callback = function(args)
			if args.buf ~= state.bufnr then return end
			if args.event == "BufLeave" then history_search.cancel(state) end
			save_pending()
		end,
	})

	local handlers = {
		send = send_message,
		send_queue = function() send_message("queue") end,
		send_steer = function() send_message("steer") end,
		cancel = cancel_input,
		history_prev = history_prev,
		history_next = history_next,
		history_search = M.search_history,
		autocomplete_visible = function()
			return state.history_search ~= nil or autocomplete.is_visible(state)
		end,
		autocomplete_next = function()
			local selected = autocomplete.select_next(state)
			history_search.preview(state)
			return selected
		end,
		autocomplete_prev = function()
			local selected = autocomplete.select_prev(state)
			history_search.preview(state)
			return selected
		end,
		autocomplete_confirm = function()
			if history_search.confirm(state) then return true end
			local ok, selection = autocomplete.confirm(state)
			if ok then
				schedule_resize_input()
			end
			if ok and selection and selection.kind == "command" then
				local selected = command_registry.select(selection.id, selected_command_context())
				if not selected and state.visible then set_input_text(selection.original) end
			end
			return ok
		end,
		command_enter_mode = command_enter_mode,
		command_enter_select = select_typed_command,
		cycle_variant = function()
			info_bar.cycle_variant(state)
		end,
		cycle_agent = function()
			info_bar.cycle_agent(state)
		end,
		cycle_model = function()
			info_bar.cycle_model(state)
		end,
		toggle_mode = function() M.set_mode(state.mode == "shell" and "normal" or "shell") end,
		fold = function(command)
			vim.cmd("normal! " .. command)
			schedule_resize_input()
		end,
	}
	local bufnr = state.bufnr
	for name, handler in pairs(handlers) do
		handlers[name] = function(...)
			if state.visible and state.bufnr == bufnr and owner_valid() then return handler(...) end
		end
	end
	keymaps.setup(bufnr, cfg, handlers)

	local text = opts.text
	if text == nil then
		text = history.get_pending(state.session_id)
	end
	if text and text ~= "" then
		set_input_text(text)
	end
	info_bar.update(state)

	local restored = opts.text == nil and restore_cursor(text or "")
	if restored and pending_cursor then pending_cursor.locked = nil end
	vim.cmd(restored and "startinsert" or "startinsert!")
end

function M.close(save_draft)
	if not state.visible then
		return
	end
	history_search.cancel(state)

	if save_draft ~= false then save_pending() end
	state.visible = false
	require("opencode.state").off("session.id", session_changed)
	for _, event in ipairs({ "sync_changed", "sessions_changed", "config_change" }) do require("opencode.events").off(event, refresh_info) end

	autocomplete.clear(state)
	mentions.clear(state)
	focus_parent_before_unmount()
	popups.unmount(state)

	state.winid = nil
	state.parent_winid = nil
	state.view = nil
	state.view_generation = nil
	state.explicit_session = false
	state.bufnr = nil
	state.popup = nil
	state.info_popup = nil
	state.info_bufnr = nil
	state.layout = nil
	state.parts = {}
	state.session_id = nil
	state.mode = "normal"
	state.send_options = nil
	state.context_snapshot = nil
	state.context_error = nil
	state.autocomplete = nil
	state.mentions = nil
	state.on_send = nil
	state.on_cancel = nil
	state.close_on_send = true
	state.allow_chat_commands = false
	state.allow_context = false
	state.persist_pending = true
	state.session_bound = false
	state.add_history = true
	state.normalizing_paste = false
	state.resize_scheduled = false

	vim.cmd("stopinsert")
end

function M.is_visible()
	return state.visible
end

function M.owner_view()
	return state.visible and state.view or nil
end

function M.close_for_view(view)
	if state.visible and state.view == view then M.close() end
end

-- Retain temporary review callbacks as well as drafts across background layout work.
function M.suspend()
	if not state.visible or not state.view or not owner_valid() then return end
	history_search.cancel(state)
	local opts = { text = get_input_text(), parts = draft_parts() }
	for _, key in ipairs({ "view", "session_id", "on_send", "on_cancel", "close_on_send", "allow_chat_commands",
		"allow_context", "persist_pending", "session_bound", "add_history", "mode", "send_options", "context_snapshot", "context_error" }) do
		opts[key] = state[key]
	end
	local generation, cursor = state.view_generation, vim.api.nvim_win_get_cursor(state.winid)
	local parent = state.parent_winid ~= state.view.winid and state.parent_winid or nil
	local float_dims = state.layout.float_dims
	local insert = vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
	M.close()
	return function()
		local views = require("opencode.ui.chat.state")
		if not views.valid(opts.view, generation) or not opts.view.visible or views.session(opts.view).id ~= opts.session_id then return end
		require("opencode.ui.chat").focus_view(opts.view)
		opts.winid, opts.float_dims = opts.view.winid, opts.view.float_dims
		if parent and vim.api.nvim_win_is_valid(parent) then
			opts.winid, opts.float_dims = parent, float_dims
			vim.api.nvim_set_current_win(parent)
		end
		if M.show(opts) == false then return end
		vim.api.nvim_win_set_cursor(state.winid, cursor)
		if not insert then vim.cmd("stopinsert") end
	end
end

function M.draft_token()
	return draft_epoch
end

function M.capture_draft_cursor()
	if not state.visible then return end
	remember_cursor(get_input_text())
	if pending_cursor then pending_cursor.locked = true end
end

function M.focus()
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then return false end
	if not owner_valid() then M.close(); return false end
	vim.api.nvim_set_current_win(state.winid)
	vim.cmd("startinsert")
	return true
end

---@param parts table[] Selected native skill references, keyed by catalog id
---@param session_id string
---@return boolean success
---@return string|nil error
function M.stage_skills(parts, session_id)
	if type(session_id) ~= "string" or session_id == "" or current_session_id() ~= session_id then
		return false, "The active session changed; select skills again in the intended session"
	end
	if state.visible and state.session_id ~= session_id then
		return false, "The open draft belongs to another session; return to it before selecting skills"
	end
	if type(parts) ~= "table" then return false, "Skill selections must be a list of catalog references" end
	local text = state.visible and get_input_text() or history.get_pending(session_id)
	local existing = state.visible and copy_parts(state.parts) or history.get_pending_parts(session_id)
	local merged, seen = {}, {}
	for _, part in ipairs(existing) do
		if part.type ~= "skill" then
			merged[#merged + 1] = part
		elseif not part._marker or marker_range(text, part._marker) then
			local id = skill_id(part)
			if not id or not seen[id] then
				merged[#merged + 1] = part
				if id then seen[id] = part end
			end
		end
	end
	local session_error = skill_session_error(merged, session_id) or skill_session_error(parts, session_id)
	if session_error then return false, session_error end
	local markers = {}
	for _, selected in ipairs(parts) do
		local id = skill_id(selected)
		if type(selected) ~= "table" or selected.type ~= "skill" or not id then
			return false, "Every selected skill requires a catalog id"
		end
		local part = seen[id]
		if not part then
			part = vim.deepcopy(selected)
			merged[#merged + 1], seen[id] = part, part
		end
		part._session_id, part._marker = session_id, "@" .. id
		if not marker_range(text, part._marker) then
			markers[#markers + 1] = part._marker
			-- Include planned markers when checking later duplicate selections.
			text = text .. " " .. part._marker .. " "
		end
	end
	if state.visible then
		state.parts = merged
		if #markers > 0 then
			if pending_cursor and pending_cursor.locked then restore_cursor(get_input_text()) end
			local cursor = vim.api.nvim_win_get_cursor(state.winid)
			local line = vim.api.nvim_buf_get_lines(state.bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
			local before = line:sub(cursor[2], cursor[2])
			local padding = cursor[2] > 0 and not before:match("%s") and " " or ""
			insert_text_at_cursor(padding .. table.concat(markers, " ") .. " ")
		end
		history.set_pending(get_input_text(), draft_parts(), session_id)
		remember_cursor(get_input_text())
		info_bar.update(state)
		M.focus()
	else
		text = history.get_pending(session_id)
		if #markers > 0 then
			local offset = saved_cursor(text, session_id) or #text
			local before = text:sub(1, offset)
			local padding = before ~= "" and not before:sub(-1):match("%s") and " " or ""
			local inserted = padding .. table.concat(markers, " ") .. " "
			text = before .. inserted .. text:sub(offset + 1)
			pending_cursor = { text = text, session_id = session_id, offset = offset + #inserted }
		end
		history.set_pending(text, merged, session_id)
		if pending_cursor and pending_cursor.session_id == session_id and pending_cursor.text == text then
			history.set_pending_cursor(pending_cursor.offset, session_id)
		end
	end
	return true
end

---@return number[]
function M.get_winids()
	if not state.visible then
		return {}
	end

	local wins = {}
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		table.insert(wins, state.winid)
	end

	if state.info_popup and state.info_popup.winid and vim.api.nvim_win_is_valid(state.info_popup.winid) then
		table.insert(wins, state.info_popup.winid)
	end

	return wins
end

function M.clear_history()
	history_search.cancel(state)
	draft_epoch, pending_cursor = draft_epoch + 1, nil
	history.clear()
	state.parts = {}
	autocomplete.reset(state)
	mentions.reset(state)
end

function M.get_history()
	return history.entries()
end

function M.search_history()
	if not state.visible then return false end
	if history_search.cancel(state) then return true end
	local draft = { text = get_input_text(), parts = draft_parts(), mode = state.mode, height = state.layout.current_height,
		options = vim.deepcopy(state.send_options) }
	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local started = history_search.start(state, draft, {
		prepare = function()
			state.parts, state.send_options = {}, nil
			autocomplete.reset(state)
			mentions.reset(state)
			set_input_text("")
			info_bar.update(state)
		end,
		restore = function()
			state.parts, state.mode, state.send_options = draft.parts, draft.mode, draft.options
			autocomplete.reset(state)
			mentions.reset(state)
			set_input_text(draft.text)
			if state.winid and vim.api.nvim_win_is_valid(state.winid) then vim.api.nvim_win_set_cursor(state.winid, cursor) end
			info_bar.update(state)
		end,
		select = function(entry)
			local ok, err = M.merge_pending_draft(entry)
			if not ok then vim.notify(err, vim.log.levels.WARN) end
		end,
	})
	if started then
		draft_epoch, pending_cursor = draft_epoch + 1, nil
		vim.cmd("startinsert!")
	end
	return started
end

---@return string
function M.get_pending_text()
	if state.history_search then return state.history_search.draft.text end
	if state.visible and state.session_id == current_session_id() then
		return get_input_text()
	end
	return history.get_pending()
end

function M.get_pending_parts()
	if state.history_search then return copy_parts(state.history_search.draft.parts) end
	return state.visible and state.session_id == current_session_id() and draft_parts() or history.get_pending_parts()
end

function M.get_mode()
	return state.visible and state.mode or history.get_pending_mode(current_session_id())
end

function M.get_pending_options()
	if state.history_search then return vim.deepcopy(state.history_search.draft.options) end
	if state.visible and state.session_id == current_session_id() then return vim.deepcopy(state.send_options) end
	return history.get_pending_options(current_session_id())
end

function M.set_mode(mode)
	history_search.cancel(state)
	state.mode = mode == "shell" and "shell" or "normal"
	history.set_pending_mode(state.mode, current_session_id())
	if state.visible then
		autocomplete.reset(state)
		info_bar.update(state)
	end
end

---@param text string
---@param parts table[]|nil
function M.set_pending_draft(text, parts, opts)
	history_search.cancel(state)
	local content = text or ""
	local copied = copy_parts(parts)
	draft_epoch, pending_cursor = draft_epoch + 1, nil
	history.set_pending(content, copied, current_session_id())
	history.set_pending_options(opts and opts.options, current_session_id())
	if state.visible and state.session_id == current_session_id() then
		state.parts = copied
		state.send_options = opts and opts.options and vim.deepcopy(opts.options) or nil
		refresh_context_snapshot(state.context_snapshot)
		autocomplete.reset(state)
		mentions.reset(state)
		set_input_text(content)
		info_bar.update(state)
	end
	if opts and opts.mode then M.set_mode(opts.mode) end
end

function M.can_merge_draft(draft)
	if (M.get_pending_text() ~= "" or #M.get_pending_parts() > 0) and M.get_mode() ~= (draft.mode or "normal") then
		return false, "Stash the current prompt before combining shell and chat drafts"
	end
	return true
end

function M.merge_pending_draft(draft)
	history_search.cancel(state)
	local ok, err = M.can_merge_draft(draft)
	if not ok then return false, err end
	local current = { text = M.get_pending_text(), parts = M.get_pending_parts() }
	local text, parts = attachments.merge_drafts(current, draft)
	local existing = current.text ~= "" or #current.parts > 0
	local options
	if existing then options = M.get_pending_options() else options = vim.deepcopy(draft.options) end
	if existing and type(draft.options) == "table" and type(draft.options.context) == "table" then
		options = options or {}
		options.context = options.context or {}
		for _, part in ipairs(draft.options.context) do
			local found = false
			for _, current_part in ipairs(options.context) do if vim.deep_equal(current_part, part) then found = true; break end end
			if not found then options.context[#options.context + 1] = vim.deepcopy(part) end
		end
	end
	M.set_pending_draft(text, parts, { options = options, mode = existing and M.get_mode() or draft.mode or "normal" })
	return true
end

---@param text string
function M.set_pending_text(text, opts)
	history_search.cancel(state)
	local content = text or ""
	if not (opts or {}).preserve_token then draft_epoch = draft_epoch + 1 end
	pending_cursor = nil
	history.set_pending(content, content == "" and {} or nil, current_session_id())
	if content == "" and (not state.visible or state.session_id == current_session_id()) then
		state.parts = {}
	end

	if state.visible and state.session_id == current_session_id() then
		autocomplete.reset(state)
		mentions.reset(state)
		set_input_text(content)
	end
end

---@return boolean success
function M.paste_clipboard()
	local bufnr, visible, session_id = state.bufnr, state.visible, current_session_id()
	return attachments.paste_clipboard(state, {
		is_current = function()
			return state.bufnr == bufnr and state.visible == visible and current_session_id() == session_id and owner_valid()
		end,
		insert_text_at_cursor = insert_text_at_cursor,
		normalize_pasted_image_paths = function()
			attachments.normalize_pasted_image_paths(state, resize_input)
		end,
		add_file_part = function(content)
			return attachments.add_file_part(state, content, nil, insert_text_at_cursor)
		end,
	})
end

---@param text string
---@param opts? { separator?: string }
---@return string
function M.append_pending_text(text, opts)
	local extra = text or ""
	if extra == "" then
		return M.get_pending_text()
	end

	opts = opts or {}
	local separator = opts.separator or "\n"
	local current = M.get_pending_text()
	local next_text

	if current == "" then
		next_text = extra
	elseif separator == "" then
		next_text = current .. extra
	elseif current:sub(-#separator) == separator then
		next_text = current .. extra
	else
		next_text = current .. separator .. extra
	end

	M.set_pending_text(next_text, { preserve_token = true })
	return next_text
end

function M.update_info_bar()
	info_bar.update(state)
end

function M.get_editor_context()
	if not state.visible or state.session_id ~= current_session_id() then return require("opencode.editor_context").pending(current_session_id()) end
	return state.editor_context and vim.deepcopy(state.editor_context)
end
function M.dismiss_editor_context()
	require("opencode.actions").mark_editor_context(current_session_id(), M.get_editor_context(), "dismissed")
	state.editor_context = nil; info_bar.update(state)
end
function M.refresh_editor_context()
	state.editor_context = require("opencode.actions").refresh_editor_context(current_session_id())
	info_bar.update(state)
	return M.get_editor_context()
end

function M.cycle_variant()
	info_bar.cycle_variant(state)
end

function M.cycle_agent()
	info_bar.cycle_agent(state)
end

function M.cycle_model()
	info_bar.cycle_model(state)
end

return M
