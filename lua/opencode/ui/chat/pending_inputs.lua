local cs = require("opencode.ui.chat.state")
return cs.factory("pending_inputs", function(view)
local M = {
	commands = {
		{ name = "cancel", description = "Cancel pending input at cursor" },
		{ name = "edit", description = "Edit pending input at cursor" },
		{ name = "steer", description = "Steer queued input at cursor" },
		{ name = "queue", description = "Queue steering input at cursor" },
	},
}

local state = view
local app_state = require("opencode.state")
local selectors = require("opencode.selectors")
local actions = require("opencode.actions")
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")

local function active(sid, generation)
	return cs.valid(view, generation) and cs.session(view).id == sid and app_state.get_session().id == sid
		and ((input.is_visible() and (input.owner_view() == view or not input.owner_view()))
			or (not input.is_visible() and cs.current() == view))
end

local function has_draft(sid)
	return (input.is_visible() and (input.owner_view() == view or not input.owner_view()))
		or history.get_pending(sid) ~= "" or #history.get_pending_parts(sid) > 0
end

local function open_draft(draft, context_snapshot, context_error)
	local sid, generation = cs.session(view).id, view.generation
	input.show({ view = view, session_id = sid, winid = state.winid, float_dims = state.float_dims, text = draft.text, parts = draft.parts,
		session_bound = true, allow_context = true, send_options = draft.options, mode = draft.mode,
		context_snapshot = context_snapshot, context_error = context_error,
		on_send = function(text, parts, send_options)
			if not active(sid, generation) then return end
			actions.send(text, vim.tbl_extend("force", draft.options or {}, send_options or {}, { parts = parts, session_id = sid, view = view }))
		end,
		on_cancel = function()
			if active(sid, generation) and state.winid and vim.api.nvim_win_is_valid(state.winid) then vim.api.nvim_set_current_win(state.winid) end
		end })
end

function M.restore_draft(draft, sid)
	if not active(sid) then
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
	local sid = cs.session(view).id
	local id = widget_support.find_widget_context_at_cursor(state.pending_inputs or {}, state.winid, function(item)
		return item.session_id == sid and widget_support.position_generation_is_current(item)
	end)
	local record = id and selectors.pending_input(sid, id)
	if record then return sid, id, record end
end

-- Deferred edits resume through the normal input entry point, never through a
-- widget key pressed over an unrelated message or empty space.
function M.resume_edit(context_snapshot, context_error)
	local sid = cs.session(view).id
	if not active(sid) or has_draft(sid) then return false end
	local draft = history.take_deferred(sid)
	if not draft then return false end
	open_draft(draft, context_snapshot, context_error)
	return true
end

function M.handle(action)
	local sid, id, record = at_cursor()
	if not id then return false end
	if action == "steer" and record.status ~= "queued" then return true end
	if action == "queue" and record.status ~= "accepted" then return true end
	if action == "edit" and has_draft(sid) then
		vim.notify("Finish the current draft before editing a queued input", vim.log.levels.INFO)
		return true
	end
	local generation = view.generation
	actions[action .. "_pending_input"](sid, id, function(err, draft)
		if err then
			vim.notify("Could not " .. action .. " input: " .. tostring(type(err) == "table" and err.message or err), vim.log.levels.ERROR)
			return
		end
		if not draft then return end
		-- Cursor edit preserves its existing deferred behavior. The queue picker
		-- explicitly restores into the current draft via restore_draft().
		if not active(sid, generation) or has_draft(sid) or not state.visible then
			history.defer_pending(draft, sid)
			vim.notify("Input cancelled; reopen input in its session after finishing the current draft to edit it", vim.log.levels.INFO)
			return
		end
		open_draft(draft)
	end)
	return true
end

return M

end)
