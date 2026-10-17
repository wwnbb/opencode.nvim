-- Timeline picker and actions for a selected historical user turn.
local M = {}

local actions = require("opencode.actions")
local app_state = require("opencode.state")
local history = require("opencode.ui.input.history")
local menu = require("opencode.ui.menu")
local projection = require("opencode.protocol.messages")
local sync = require("opencode.sync")
local views = require("opencode.ui.chat.state")

local picker_generation = 0

local function error_text(err)
	return type(err) == "table" and (err.message or err.code) or tostring(err)
end

local function selected_user_turn(session_id, message_id)
	local message = sync.get_message(session_id, message_id)
	if message and message.role == "user" and not message.provisional then return message end
	return nil
end

local function active_session_id(view)
	return views.session(view or views.current()).id
end

local function owner_context(context)
	context = context or {}
	local view = context.view or views.current()
	return { view = view, generation = context.generation or view.generation,
		tabpage = context.tabpage or vim.api.nvim_get_current_tabpage() }
end

local function owner_current(owner, session_id)
	return views.valid(owner.view, owner.generation) and active_session_id(owner.view) == session_id
end

local function owner_focused(owner, session_id)
	return owner_current(owner, session_id) and views.current() == owner.view
		and vim.api.nvim_get_current_tabpage() == owner.tabpage
end

local function visible_message_limit(session_id, messages)
	local record = app_state.get_session_record(session_id)
	local boundary = type(record and record.revert) == "table" and record.revert.messageID or nil
	if not boundary then return #messages end
	for index, message in ipairs(messages) do
		if message.id == boundary then return index - 1 end
	end
	return #messages
end

local function preview(message)
	local native = message._native or message
	local text = vim.trim((native.text or ""):gsub("%s+", " "))
	if text == "" then
		local count = #(native.files or {}) + #(native.agents or {}) + #(native.skills or {})
		text = count > 0 and ("[" .. count .. " attachments]") or "[Empty prompt]"
	end
	return text
end

local function turn_time(message)
	local created = type(message.time) == "table" and message.time.created or nil
	if type(created) ~= "number" then return nil end
	local ok, value = pcall(os.date, "%Y-%m-%d %H:%M", math.floor(created / 1000))
	return ok and value or nil
end

local function preview_jump(session_id, message_id, owner)
	if not message_id or not owner_focused(owner, session_id) then return false end
	local chat_state = owner.view
	if not chat_state.visible or not chat_state.winid or not vim.api.nvim_win_is_valid(chat_state.winid) then
		return false
	end
	if not chat_state.full_history_sessions[session_id] then
		chat_state.full_history_sessions[session_id] = true
		require("opencode.ui.chat").for_view(chat_state).do_render()
	end
	return views.module(chat_state, require("opencode.ui.chat.nav")).jump_to_message(message_id)
end

local function restore_draft(session_id, draft, owner)
	if owner_focused(owner, session_id) then
		local input = require("opencode.ui.input")
		input.set_pending_draft(draft.text, draft.parts)
		require("opencode.ui.chat").for_view(owner.view).focus_input()
	else
		-- Keep the draft attached to its session if the user switched context while
		-- the server operation was in flight.
		history.set_pending(draft.text, draft.parts, session_id)
		history.set_pending_options(nil, session_id)
	end
end

local function fork_session(session_id, before, draft, owner)
	owner = owner or owner_context()
	actions.fork_session(session_id, before and { before = before } or {}, function(err, forked)
		if err or type(forked) ~= "table" or type(forked.id) ~= "string" then
			vim.notify("Could not fork session: " .. error_text(err or "invalid response"), vim.log.levels.ERROR)
			return
		end
		actions.remember_session(forked)
		local activate = owner_focused(owner, session_id)
		if activate then
			actions.switch_session(forked, { reason = "session_fork", view = owner.view })
			owner = owner_context()
			activate = owner_focused(owner, forked.id)
		end
		if draft then restore_draft(forked.id, draft, owner) end
		vim.notify(draft and (activate and "Forked before selected prompt; prompt restored to composer"
			or "Forked before selected prompt; prompt saved in new session") or "Forked session", vim.log.levels.INFO)
	end)
end

---Run one action on a delivered user message.
---@param action "jump"|"copy"|"fork"|"revert"
---@param session_id string
---@param message_id string
---@return boolean
function M.run(action, session_id, message_id, owner)
	owner = owner or owner_context()
	local message = selected_user_turn(session_id, message_id)
	if not message then
		vim.notify("The selected user turn is no longer available", vim.log.levels.WARN)
		return false
	end

	if action == "copy" then
		local text = projection.draft(message).text
		vim.fn.setreg('"', text)
		pcall(vim.fn.setreg, "+", text)
		vim.notify("Prompt copied", vim.log.levels.INFO)
		return true
	end

	if action == "jump" then
		if not owner_current(owner, session_id) then
			vim.notify("Switch to this session before jumping to its message", vim.log.levels.WARN)
			return false
		end
		local messages = sync.get_messages(session_id)
		local limit = visible_message_limit(session_id, messages)
		for index = limit + 1, #messages do
			if messages[index].id == message_id then
				vim.notify("This turn is hidden by staged revert; use /redo to restore it", vim.log.levels.INFO)
				return false
			end
		end
		local chat = require("opencode.ui.chat").for_view(owner.view)
		owner.view.full_history_sessions[session_id] = true
		chat.focus()
		chat.do_render()
		if not views.module(owner.view, require("opencode.ui.chat.nav")).jump_to_message(message_id) then
			vim.notify("Could not locate the selected message in chat", vim.log.levels.WARN)
			return false
		end
		return true
	end

	local draft = projection.draft(message)
	if action == "fork" then
		fork_session(session_id, message_id, draft, owner)
		return true
	end

	if action == "revert" then
		actions.undo_message(session_id, message_id, function(err)
			if err then
				vim.notify("Could not revert to selected prompt: " .. error_text(err), vim.log.levels.ERROR)
				return
			end
			restore_draft(session_id, draft, owner)
			vim.notify("Revert staged. Use /redo to restore the turn.", vim.log.levels.INFO)
		end)
		return true
	end

	return false
end

---Open the action menu for a user turn.
function M.show_actions(session_id, message_id, owner)
	owner = owner or owner_context()
	local message = selected_user_turn(session_id, message_id)
	if not message then
		vim.notify("The selected user turn is no longer available", vim.log.levels.WARN)
		return false
	end
	local pending = require("opencode.session.pending")
	local token = pending.token(session_id)
	menu.open({
		title = " Message Actions ",
		width = 54,
		items = {
			{ label = "Jump to Message", value = "jump", description = "Show in chat" },
			{ label = "Revert to Prompt", value = "revert", description = "Stage undo" },
			{ label = "Copy Prompt", value = "copy", description = "Copy text" },
			{ label = "Fork Before Prompt", value = "fork", description = "Create a new session" },
		},
		on_select = function(item)
			if not pending.is_current(token) or not owner_current(owner, session_id) then return end
			M.run(item.value, session_id, message_id, owner)
		end,
	})
	return true
end

---Open actions for the rendered user turn under the chat cursor.
function M.show_actions_at_cursor(context)
	local owner = owner_context(context)
	local chat_state = owner.view
	local session_id = active_session_id(chat_state)
	local winid = chat_state.winid
	if not session_id or not winid or not vim.api.nvim_win_is_valid(winid) then return false end
	local line = vim.api.nvim_win_get_cursor(winid)[1] - 1
	for _, position in ipairs(chat_state.message_positions or {}) do
		if position.role == "user" and line >= position.start_line and line <= position.end_line then
			return M.show_actions(session_id, position.id, owner)
		end
	end
	vim.notify("Place the cursor on a user message", vim.log.levels.INFO)
	return false
end

local function show_picker(kind, context)
	local owner = owner_context(context)
	local session_id = active_session_id(owner.view)
	if not session_id then
		vim.notify("Open a session first", vim.log.levels.WARN)
		return false
	end
	picker_generation = picker_generation + 1
	local generation = picker_generation
	actions.load_session_messages(session_id, { all = true }, function(err)
		if generation ~= picker_generation or not owner_focused(owner, session_id) then return end
		if err then
			vim.notify("Could not load timeline: " .. error_text(err), vim.log.levels.ERROR)
			return
		end
		local items = {}
		if kind == "fork" then items[1] = { label = "Full session", full = true } end
		local messages = sync.get_messages(session_id)
		for index = #messages, 1, -1 do
			local message = messages[index]
			if message.role == "user" and not message.provisional then
				items[#items + 1] = { label = preview(message), value = message.id, description = turn_time(message) }
			end
		end
		if #items == 0 then
			vim.notify("No user turns in this session", vim.log.levels.INFO)
			return
		end
		local pending = require("opencode.session.pending")
		local token = pending.token(session_id)
		menu.open({
			title = kind == "fork" and " Fork Session " or " Timeline ",
			width = 72,
			searchable = true,
			sort = false,
			items = items,
			on_move = function(item)
				if not pending.is_current(token) or not owner_current(owner, session_id) then return end
				if not item.full then preview_jump(session_id, item.value, owner) end
			end,
			on_select = function(item)
				if not pending.is_current(token) or not owner_current(owner, session_id) then return end
				if kind == "fork" then
					if item.full then fork_session(session_id, nil, nil, owner) else M.run("fork", session_id, item.value, owner) end
				else
					M.show_actions(session_id, item.value, owner)
				end
			end,
		})
	end)
	return true
end

---Fetch every history page before presenting a searchable timeline.
function M.show(context)
	return show_picker("timeline", context)
end

---Choose a full fork or an exclusive boundary before a user turn.
function M.show_fork_picker(context)
	return show_picker("fork", context)
end

return M
