local M = {
	commands = {
		{ name = "cancel", description = "Cancel pending input at cursor" },
		{ name = "edit", description = "Edit pending input at cursor" },
		{ name = "steer", description = "Steer queued input at cursor" },
		{ name = "queue", description = "Queue steering input at cursor" },
	},
}

local state = require("opencode.ui.chat.state").state
local app_state = require("opencode.state")
local selectors = require("opencode.selectors")
local actions = require("opencode.actions")
local widget_support = require("opencode.ui.chat.widget_support")
local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")

local function has_draft()
	return input.is_visible() or history.get_pending() ~= "" or #history.get_pending_parts() > 0
end

local function open_draft(draft)
	input.show({ winid = state.winid, float_dims = state.float_dims, text = draft.text, parts = draft.parts,
		session_bound = true, send_options = draft.options, mode = draft.mode,
		on_send = function(text, parts, send_options)
			actions.send(text, vim.tbl_extend("force", draft.options, send_options or {}, { parts = parts }))
		end,
		on_cancel = function()
			if state.winid and vim.api.nvim_win_is_valid(state.winid) then vim.api.nvim_set_current_win(state.winid) end
		end })
end

function M.restore_draft(draft, sid)
	if app_state.get_session().id ~= sid then
		history.defer_pending(draft, sid)
		vim.notify("Input cancelled; return to its session to restore the draft", vim.log.levels.INFO)
		return
	end
	local ok, err = input.merge_pending_draft(draft)
	if not ok then history.defer_pending(draft, sid); vim.notify(err, vim.log.levels.WARN); return end
	if state.visible and not input.is_visible() then
		open_draft({ text = input.get_pending_text(), parts = input.get_pending_parts(), mode = input.get_mode(), options = history.get_pending_options() or draft.options })
	end
end

local function at_cursor()
	if not state.visible or not state.winid or vim.api.nvim_get_current_win() ~= state.winid
		or vim.api.nvim_win_get_buf(state.winid) ~= state.bufnr then return end
	local sid = app_state.get_session().id
	local id = widget_support.find_widget_context_at_cursor(state.pending_inputs or {}, state.winid, function(item)
		return item.session_id == sid and widget_support.position_generation_is_current(item)
	end)
	local record = id and selectors.pending_input(sid, id)
	if record then return sid, id, record end
end

-- Deferred edits resume through the normal input entry point, never through a
-- widget key pressed over an unrelated message or empty space.
function M.resume_edit()
	local sid = app_state.get_session().id
	if has_draft() then return false end
	local draft = history.take_deferred(sid)
	if not draft then return false end
	open_draft(draft)
	return true
end

function M.handle(action)
	local sid, id, record = at_cursor()
	if not id then return false end
	if action == "steer" and record.status ~= "queued" then return true end
	if action == "queue" and record.status ~= "accepted" then return true end
	if action == "edit" and has_draft() then
		vim.notify("Finish the current draft before editing a queued input", vim.log.levels.INFO)
		return true
	end
	actions[action .. "_pending_input"](sid, id, function(err, draft)
		if err then
			vim.notify("Could not " .. action .. " input: " .. tostring(type(err) == "table" and err.message or err), vim.log.levels.ERROR)
			return
		end
		if not draft then return end
		-- Cursor edit preserves its existing deferred behavior. The queue picker
		-- explicitly restores into the current draft via restore_draft().
		if has_draft() or app_state.get_session().id ~= sid or not state.visible then
			history.defer_pending(draft, sid)
			vim.notify("Input cancelled; reopen input in its session after finishing the current draft to edit it", vim.log.levels.INFO)
			return
		end
		open_draft(draft)
	end)
	return true
end

return M
