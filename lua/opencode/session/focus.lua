local M = {}

-- Window identity distinguishes the original composer from a later opening.
---@return number|false
function M.capture_input(owner)
	local input = require("opencode.ui.input")
	return input.owner_view() == owner and input.get_winids()[1] or false
end

-- Staleness for "fetch, then switch": a session-bound view is current while its
-- generation holds; otherwise any change of the global session since capture
-- (including A -> B -> A) cancels. Call dispose() once the operation finishes.
function M.guard(view, generation)
	local views = require("opencode.session.views").registry()
	local owner = view and view.session_bound and view or nil
	if owner then
		generation = generation or owner.generation
		return { view = view, owner = owner,
			valid = function() return views ~= nil and views.valid(owner, generation) end,
			dispose = function() end }
	end
	local state = require("opencode.state")
	local source, changed = state.get_session().id, false
	-- Once changed the guard stays invalid, so stop listening even when the
	-- owner never reaches dispose().
	local function switched()
		changed = true
		state.off("session.id", switched)
	end
	state.on("session.id", switched)
	return { view = view,
		valid = function() return not changed and state.get_session().id == source end,
		dispose = function() state.off("session.id", switched) end }
end

-- Switch to fetched session info with the guard's focus rules; a superseded
-- focus still records the session without touching recency.
function M.open_fetched(guard, info, opts, initial_input)
	local sessions = require("opencode.session")
	if M.with_session_focus(guard.view, function()
		return sessions.switch_to(info, opts)
	end, initial_input) == false then
		sessions.remember(info, { touch = false, reason = opts.reason or "session_open" })
	end
end

-- A session response must not take focus back after the user leaves its owner.
function M.with_session_focus(owner, create, initial_input)
	if not owner then return create() end
	local cs = require("opencode.ui.chat.state")
	local workspace = require("opencode.ui.chat.workspace")
	local window, previous = vim.api.nvim_get_current_win(), workspace.current()
	local parked = workspace.is_parked()
	local input = require("opencode.ui.input")
	-- A newly opened source composer supersedes the navigation, not its loaded data.
	-- nil keeps callers without a snapshot unchanged; false means no original input.
	if initial_input ~= nil and input.owner_view() == owner and input.get_winids()[1] ~= initial_input then return false end
	local in_input = vim.tbl_contains(input.get_winids(), window)
	local background = cs.for_window(window) ~= owner
		and not (input.owner_view() == owner and in_input)
	local restore_input = background and in_input and input.suspend()
	local ok, result = xpcall(create, debug.traceback)
	if background then
		local function restore(run)
			local restored, err = xpcall(run, debug.traceback)
			if not restored then
				result = (ok and "" or tostring(result) .. "\n") .. "Could not restore session focus: " .. err
				ok = false
			end
		end
		restore(function()
			if previous and workspace.current() ~= previous then workspace.select(previous.id) end
		end)
		restore(function()
			if restore_input then restore_input()
			elseif vim.api.nvim_win_is_valid(window) then vim.api.nvim_set_current_win(window) end
		end)
		if parked then restore(workspace.park) end
	end
	if not ok then error(result) end
	return result
end

return M
