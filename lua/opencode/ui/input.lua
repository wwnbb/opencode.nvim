-- opencode.nvim - Input area facade

local M = {}

local attachments = require("opencode.ui.input.attachments")
local autocomplete = require("opencode.ui.input.autocomplete")
local autocmds = require("opencode.ui.input.autocmds")
local command_registry = require("opencode.command_registry")
local history = require("opencode.ui.input.history")
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
	popup = nil,
	info_popup = nil,
	info_bufnr = nil,
	visible = false,
	on_send = nil,
	on_cancel = nil,
	close_on_send = true,
	allow_chat_commands = false,
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
	autocomplete = nil,
	mentions = nil,
	normalizing_paste = false,
	resize_scheduled = false,
}
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

local function resize_input()
	layout.resize(state)
end

local function schedule_resize_input()
	layout.schedule_resize(state)
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
	return function()
		if current_session_id() ~= session_id then return end
		local chat = require("opencode.ui.chat")
		if chat.is_visible() then chat.focus_input() end
	end
end

local function selected_command_context()
	local session_id = state.session_id
	return { source = "slash_select", session_id = session_id, args = "", resume_input = resume_chat_input(session_id) }
end

local function command_enter_mode()
	if state.mode == "shell" then return nil end
	if not state.allow_chat_commands or state.session_id ~= current_session_id() then return nil end
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
		history.add(text, parts, state.mode)
	end
	local send_options = state.send_options and vim.deepcopy(state.send_options) or nil
	if state.mode ~= "shell" and not text:match("^%s*/") and state.editor_context then
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

	clear_input()

	if state.on_send then
		state.on_send(text, parts, send_options)
	end
	if state.close_on_send then
		M.close(false)
	end
end

local function cancel_input()
	local text = get_input_text()
	if state.on_cancel then
		state.on_cancel(text)
	end
	M.close()
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
	recall_history(history.previous(get_input_text(), draft_parts(), state.mode))
end

local function history_next()
	recall_history(history.next(get_input_text(), draft_parts(), state.mode))
end

local function insert_text_at_cursor(text)
	return attachments.insert_text_at_cursor(state, text, schedule_resize_input)
end

local function mount_input(chat_winid, float_dims, cfg)
	local frame = layout.build(chat_winid, float_dims, cfg)
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
	if not state.persist_pending or state.session_bound then M.close(state.persist_pending); return end
	local previous_id = state.session_id
	local text = get_input_text()
	history.set_pending(text, draft_parts(), previous_id)
	history.set_pending_mode(state.mode, previous_id)
	history.set_pending_options(state.send_options, previous_id)
	local offset = saved_cursor(text, previous_id)
	if vim.api.nvim_get_current_win() == state.winid or offset == nil then
		remember_cursor(text)
	else
		history.set_pending_cursor(offset, previous_id)
	end
	pending_cursor = nil
	state.session_id = session_id
	state.parts = history.get_pending_parts(session_id)
	state.mode = history.get_pending_mode(session_id)
	state.send_options = history.get_pending_options(session_id)
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

function M.show(opts)
	opts = opts or {}

	if state.visible then
		return M.focus()
	end
	if opts.text ~= nil then draft_epoch, pending_cursor = draft_epoch + 1, nil end

	local cfg = resolve_config()
	state.config = cfg
	state.on_send = opts.on_send
	state.on_cancel = opts.on_cancel or function() end
	state.close_on_send = opts.close_on_send ~= false
	state.allow_chat_commands = opts.allow_chat_commands == true or opts.allow_skill_picker == true
	state.persist_pending = opts.persist_pending ~= false
	state.session_bound = opts.session_bound == true
	state.add_history = opts.add_history ~= false
	state.session_id = current_session_id()
	state.parts = opts.text ~= nil and copy_parts(opts.parts) or history.get_pending_parts(state.session_id)
	state.mode = opts.mode or (opts.text ~= nil and "normal" or history.get_pending_mode(state.session_id))
	state.send_options = opts.send_options or (opts.text == nil and history.get_pending_options(state.session_id))
	state.editor_context = opts.session_bound ~= true and require("opencode.editor_context").pending(state.session_id) or nil

	history.configure(cfg)
	history.load()
	autocomplete.setup_highlights()
	info_bar.setup_highlights()
	mentions.setup_highlights()

	local chat_winid = opts.winid
	if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
		chat_winid = vim.api.nvim_get_current_win()
	end
	state.parent_winid = chat_winid

	mount_input(chat_winid, opts.float_dims, cfg)
	require("opencode.state").on("session.id", session_changed)
	for _, event in ipairs({ "sync_changed", "sessions_changed", "config_change" }) do require("opencode.events").on(event, refresh_info) end

	autocmds.setup(state, {
		schedule_resize = schedule_resize_input,
		reflow = function() layout.reflow(state); info_bar.update(state) end,
		input_changed = function()
			if state.mode ~= "shell" then autocomplete.refresh(state) end
			info_bar.update(state)
		end,
		cursor_moved = function()
			if state.mode ~= "shell" then autocomplete.refresh(state) end
			if state.paste_folds then schedule_resize_input() end
		end,
		insert_leave = function()
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
	-- Popup teardown is scheduled after BufLeave. Capture the insertion point
	-- now, before another popup or InsertLeave can move the old window's caret.
	vim.api.nvim_create_autocmd("BufLeave", {
		buffer = state.bufnr,
		callback = function()
			local text = get_input_text()
			if state.visible and state.persist_pending
				and not (pending_cursor and pending_cursor.locked and saved_cursor(text, state.session_id) ~= nil) then
				remember_cursor(text)
			end
		end,
	})

	keymaps.setup(state.bufnr, cfg, {
		send = send_message,
		send_queue = function() send_message("queue") end,
		send_steer = function() send_message("steer") end,
		cancel = cancel_input,
		history_prev = history_prev,
		history_next = history_next,
		autocomplete_visible = function()
			return autocomplete.is_visible(state)
		end,
		autocomplete_next = function()
			return autocomplete.select_next(state)
		end,
		autocomplete_prev = function()
			return autocomplete.select_prev(state)
		end,
		autocomplete_confirm = function()
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
	})

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

	if save_draft ~= false and state.persist_pending then
		local text = get_input_text()
		history.set_pending(text, draft_parts(), state.session_id)
		history.set_pending_mode(state.mode, state.session_id)
		history.set_pending_options(state.send_options, state.session_id)
		local offset = saved_cursor(text, state.session_id)
		if vim.api.nvim_get_current_win() == state.winid or offset == nil then
			remember_cursor(text)
		else
			history.set_pending_cursor(offset, state.session_id)
		end
	end
	require("opencode.state").off("session.id", session_changed)
	for _, event in ipairs({ "sync_changed", "sessions_changed", "config_change" }) do require("opencode.events").off(event, refresh_info) end

	autocomplete.clear(state)
	mentions.clear(state)
	focus_parent_before_unmount()
	popups.unmount(state)

	state.visible = false
	state.winid = nil
	state.parent_winid = nil
	state.bufnr = nil
	state.popup = nil
	state.info_popup = nil
	state.info_bufnr = nil
	state.layout = nil
	state.parts = {}
	state.session_id = nil
	state.mode = "normal"
	state.send_options = nil
	state.autocomplete = nil
	state.mentions = nil
	state.on_send = nil
	state.on_cancel = nil
	state.close_on_send = true
	state.allow_chat_commands = false
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
	draft_epoch, pending_cursor = draft_epoch + 1, nil
	history.clear()
	state.parts = {}
	autocomplete.reset(state)
	mentions.reset(state)
end

function M.get_history()
	return history.entries()
end

---@return string
function M.get_pending_text()
	if state.visible and state.session_id == current_session_id() then
		return get_input_text()
	end
	return history.get_pending()
end

function M.get_pending_parts()
	return state.visible and state.session_id == current_session_id() and draft_parts() or history.get_pending_parts()
end

function M.get_mode()
	return state.visible and state.mode or history.get_pending_mode(current_session_id())
end

function M.get_pending_options()
	if state.visible and state.session_id == current_session_id() then return vim.deepcopy(state.send_options) end
	return history.get_pending_options(current_session_id())
end

function M.set_mode(mode)
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
	local content = text or ""
	local copied = copy_parts(parts)
	draft_epoch, pending_cursor = draft_epoch + 1, nil
	history.set_pending(content, copied, current_session_id())
	history.set_pending_options(opts and opts.options, current_session_id())
	if state.visible and state.session_id == current_session_id() then
		state.parts = copied
		state.send_options = opts and opts.options and vim.deepcopy(opts.options) or nil
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
	return attachments.paste_clipboard(state, {
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
