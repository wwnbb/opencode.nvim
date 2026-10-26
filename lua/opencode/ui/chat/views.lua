-- opencode.nvim - Chat views facade
-- require("opencode.ui.chat") returns this facade: module-level calls forward to
-- the focused view's chat instance, and multi-pane operations (focus, bind,
-- split, close, toggle) plus WinEnter focus tracking live here.

local cs = require("opencode.ui.chat.state")

---@param instances table the per-view chat instance factory from ui/chat/init
return function(instances)
local M = { for_view = instances.for_view }
local creating_split = false
for name, method in pairs(instances) do
	if type(method) == "function" and name ~= "for_view" then
		M[name] = function(...) return instances.for_view(cs.current())[name](...) end
	end
end

function M.get_view() return cs.current() end

local function remember_return_window()
	if vim.api.nvim_get_current_tabpage() ~= cs.workspace.tabpage then
		cs.workspace.return_winid = vim.api.nvim_get_current_win()
	end
end

function M.focus_view(view)
	if not cs.valid(view) then return false end
	if view.config and view.config.layout == "tab" then remember_return_window() end
	if view and view.suspended then
		require("opencode.ui.chat.workspace").select(view.workspace_id)
	end
	if not cs.valid(view) or not view.winid or not vim.api.nvim_win_is_valid(view.winid) then return false end
	if view.session_bound and view.config and view.config.layout == "tab"
		and vim.api.nvim_win_get_buf(view.winid) ~= view.bufnr then
		local ok, details = pcall(require, "opencode.ui.chat.execute_details")
		if ok then details = cs.module(view, details) end
		local showing_details = ok and details.is_open() and vim.tbl_contains(details.get_winids(), view.winid)
		if not showing_details then
			-- Detach an ordinary file without replacing it; close can recover a surviving mirror.
			instances.for_view(view).close()
			if not cs.valid(view) or not cs.is_chat_buffer_displayed(view) then return false end
		end
	end
	local input = require("opencode.ui.input")
	local owner = input.owner_view()
	if owner and owner ~= view then require("opencode.ui.input").close_for_view(owner) end
	cs.activate(view)
	vim.api.nvim_set_current_win(view.winid)
	require("opencode.actions").activate_chat_view(view)
	instances.for_view(view).schedule_render({ force = view.transcript_dirty })
	return true
end

function M.bind_session(view, session, opts)
	view = view or cs.current()
	if not cs.valid(view) then return false end
	local existing = session and cs.for_session(session.id)
	if existing and existing ~= view then
		M.focus_view(existing)
		return false
	end
	if not view.session_bound then
		return require("opencode.actions").set_active_session(session and session.id, session and (session.title or session.name), opts)
	end
	local previous = cs.session(view).id
	require("opencode.actions").observe_session(previous, false)
	instances.for_view(view).session_changed(session or {}, opts)
	if view.workspace_id then require("opencode.ui.chat.workspace").session_changed(view, session or {}) end
	if cs.current() == view then
		require("opencode.actions").activate_chat_view(view)
	end
	return true
end

function M.open()
	local app = require("opencode.state")
	local config = (app.get_config() or {}).chat or {}
	if config.layout == "tab" then
		remember_return_window()
		local workspace = require("opencode.ui.chat.workspace")
		local layout = workspace.current()
		if workspace.is_parked() or (layout and not layout.last_view) then
			if workspace.resume() then return end
		end
		local last = cs.workspace.last_view
		if last and M.focus_view(last) then return end
		for _, view in ipairs(cs.all()) do
			if view.config and view.config.layout == "tab" and M.focus_view(view) then return end
		end
		local view = cs.state
		local session = app.get_session()
		local retained = last or view
		-- q keeps the session; x removes its membership.
		if not session.id and retained.session_bound and app.is_runtime_session(retained.session_id) then
			session = cs.session(retained)
		end
		view.session_id, view.session_name = session.id, session.name
		view.session_bound = true
		instances.for_view(view).create()
		instances.for_view(view).open()
		M.focus_view(view)
		require("opencode.ui.chat.workspace").ensure(view)
		return
	end
	return instances.for_view(cs.current()).open()
end

function M.focus()
	M.open()
	local view = cs.current()
	if view.config and view.config.layout == "tab" then return M.focus_view(view) end
	return instances.for_view(view).focus()
end

---Dispose a view (unless opts.dispose is false), detach it from its workspace
---layout and drop it from the registry. Errors leave the view registered.
function M.retire_view(view, opts)
	if not opts or opts.dispose ~= false then
		local owned = view == cs.state and instances or (view.modules and view.modules.init)
		if owned then owned.dispose()
		else
			-- A failed layout creation may not have built the chat instance yet.
			for _, mod in pairs(view.modules or {}) do if mod.dispose then mod.dispose() end end
		end
	end
	view.suspended, view.workspace_id = nil, nil
	cs.remove(view)
end

function M.create_split(parent, session, direction)
	local previous
	if parent and parent.suspended then
		local workspace = require("opencode.ui.chat.workspace")
		previous = workspace.current()
		workspace.select(parent.workspace_id)
	end
	if not cs.valid(parent) or not parent.visible or not parent.winid or not vim.api.nvim_win_is_valid(parent.winid) then return end
	local view = cs.new()
	view.workspace_id = parent.workspace_id
	view.config = vim.deepcopy(parent.config)
	view.session_id, view.session_name = session.id, session.title or session.name
	local chat = instances.for_view(view)
	chat.create()
	creating_split = true
	local ok, err = pcall(function()
		require("opencode.context").preserve_source(function()
			vim.api.nvim_win_call(parent.winid, function()
				vim.cmd(direction == "vertical" and "rightbelow vsplit" or "rightbelow split")
				chat.attach_window(vim.api.nvim_get_current_win())
			end)
		end)
	end)
	creating_split = false
	if not ok then
		chat.close()
		M.retire_view(view)
		vim.notify("Could not split OpenCode: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	M.focus_view(view)
	if previous then require("opencode.ui.chat.workspace").select(previous.id) end
	return view
end

function M.create_layout(session)
	return require("opencode.ui.chat.workspace").create(session)
end

function M.after_close()
	if cs.workspace.switching then return end
	local workspace = package.loaded["opencode.ui.chat.workspace"]
	if workspace then workspace.after_close() end
	local view = cs.current()
	if view.visible and view.winid and vim.api.nvim_win_is_valid(view.winid) then
		require("opencode.actions").activate_chat_view(view)
	else
		require("opencode.actions").set_active_session(nil, nil, { reason = "pane_focus", preserve_cache = true })
	end
	local has_chat = false
	for _, other in ipairs(cs.all()) do
		if other.visible and other.tabpage == cs.workspace.tabpage then has_chat = true; break end
	end
	-- The last view remains a reopening hint, even after its windows are gone.
	if not has_chat and (not workspace or #workspace.list() == 0) then cs.workspace.tabpage = nil end
end

function M.close_view(view, opts)
	if not cs.valid(view) then return end
	require("opencode.actions").observe_session(cs.session(view).id, false)
	if view.suspended then
		local owned = instances.for_view(view)
		local ok, err = xpcall(M.retire_view, debug.traceback, view)
		if not ok then
			-- Teardown or its recovery may already have removed listeners and refresh hooks.
			local restored, restore_error = xpcall(owned.create, debug.traceback)
			if not restored then err = err .. "\nCould not restore suspended chat: " .. restore_error end
		end
		local reconciled, reconcile_error = xpcall(M.after_close, debug.traceback)
		if not reconciled then
			err = (ok and "" or err .. "\n") .. "Could not reconcile suspended close: " .. reconcile_error
			ok = false
		end
		if not ok then error(err, 0) end
		return
	end
	if opts and opts.all_windows then
		local windows = cs.windows(view)
		if view.winid and not vim.tbl_contains(windows, view.winid) then windows[#windows + 1] = view.winid end
		for _, win in ipairs(windows) do
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_call(win, function() instances.for_view(view).close() end)
			end
		end
	else
		instances.for_view(view).close()
	end
	if view.config and view.config.layout == "tab" then M.after_close() end
end

function M.close()
	local view = cs.current()
	-- A hidden layout (or a parked workspace) has no focused pane to close; only
	-- close_view, as x does, may retire a suspended view and drop it from its layout.
	if view.suspended then return end
	return M.close_view(view)
end

function M.toggle()
	local config = (require("opencode.state").get_config() or {}).chat or {}
	if config.layout ~= "tab" then return instances.for_view(cs.current()).toggle() end
	if vim.api.nvim_get_current_tabpage() ~= cs.workspace.tabpage then return M.open() end
	require("opencode.ui.input").close_for_view(cs.current())
	local workspace = require("opencode.ui.chat.workspace")
	-- park() leaves the tab itself; without an active layout only leave it.
	if not workspace.park() then workspace.leave() end
end

local focus_group = vim.api.nvim_create_augroup("OpenCodeChatViewFocus", { clear = true })
vim.api.nvim_create_autocmd({ "WinEnter", "TabEnter", "BufWinEnter" }, {
	group = focus_group,
	callback = function()
		if creating_split or cs.workspace.switching then return end
		local win = vim.api.nvim_get_current_win()
		local view = cs.for_window(win)
		if not view or not view.session_bound then return end
		local function focus()
			local input = require("opencode.ui.input")
			local owner = input.owner_view()
			if owner and (owner ~= view or view.winid ~= win) then input.close_for_view(owner) end
			if view.winid ~= win or not view.visible then instances.for_view(view).attach_window(win) end
			cs.activate(view)
			require("opencode.actions").activate_chat_view(view)
		end
		if view.winid ~= win or not view.visible then
			-- :new and :tabnew briefly inherit the old buffer before replacing it.
			vim.schedule(function()
				if cs.valid(view) and vim.api.nvim_win_is_valid(win) and vim.api.nvim_get_current_win() == win
					and vim.api.nvim_win_get_buf(win) == view.bufnr then focus() end
			end)
			return
		end
		focus()
	end,
})

return M

end
