-- Runtime session tab actions and native viewed acknowledgements. Data lives in state.lua.
local M = {}
local state = require("opencode.state")
local pending = require("opencode.session.pending")
local focus = require("opencode.session.focus")
local bus
local subscriptions = {}
local focused, observations = true, {}

local function cancel_retry(entry)
	if entry.retry_timer then
		pcall(entry.retry_timer.stop, entry.retry_timer); pcall(entry.retry_timer.close, entry.retry_timer)
		entry.retry_timer = nil
		entry.acknowledgement = nil
	end
end

function M.clear()
	for _, entry in pairs(observations) do cancel_retry(entry) end
	observations = {}
end

function M.teardown()
	M.clear()
	if bus then for event, callback in pairs(subscriptions) do bus.off(event, callback) end end
	bus, subscriptions = nil, {}
	pcall(vim.api.nvim_del_augroup_by_name, "OpenCodeViewed")
end

function M.observe(session_id, is_visible)
	if not session_id then return end
	local entry = observations[session_id] or { retry_count = 0 }
	observations[session_id] = entry
	entry.visible = is_visible == true
	if not entry.visible then cancel_retry(entry) end
	if not focused or not entry.visible or not state.is_connected() then return end
	local views = require("opencode.session.views").registry()
	if views and type(views.for_session) == "function" then
		local view = views.for_session(session_id)
		if view and (not view.visible or not view.winid or not vim.api.nvim_win_is_valid(view.winid)
			or vim.api.nvim_win_get_tabpage(view.winid) ~= vim.api.nvim_get_current_tabpage()) then return end
	end
	local info = state.get_session_record(session_id)
	local time = info and info.time or {}
	local idle = time.idle
	if type(idle) ~= "number" or (type(time.viewed) == "number" and time.viewed >= idle) then return end
	if entry.acknowledgement and entry.acknowledgement.idle == idle then return end
	cancel_retry(entry)
	local attempt = { id = session_id, idle = idle, token = pending.token(session_id) }
	entry.acknowledgement = attempt
	require("opencode.client").view_session(session_id, idle, function(err)
		if observations[session_id] ~= entry or entry.acknowledgement ~= attempt or not pending.is_current(attempt.token) then return end
		if not err then
			entry.retry_count = 0
			require("opencode.session").remember({ id = session_id, time = { viewed = idle } }, { touch = false, reason = "viewed" })
			return
		end
		-- Auth/config errors require intervention; keep unread rather than retrying forever.
		if err.retryable == false or err.status == 401 or err.status == 403 or err.status == 404 then return end
		entry.retry_count = entry.retry_count + 1
		local delay = math.min(1000 * 2 ^ math.min(entry.retry_count - 1, 5), 30000)
		entry.retry_timer = vim.defer_fn(function()
			entry.retry_timer = nil
			if observations[session_id] ~= entry or entry.acknowledgement ~= attempt then return end
			entry.acknowledgement = nil
			M.observe(session_id, entry.visible)
		end, delay)
	end)
end

function M.reorder(session_id, direction)
	local ids = state.get_runtime_session_order()
	for i, id in ipairs(ids) do
		if id == session_id then
			local target = math.max(1, math.min(#ids, i + (direction < 0 and -1 or 1)))
			if i == target then return false end
			ids[i], ids[target] = ids[target], ids[i]
			state.set_runtime_session_order(ids)
			require("opencode.events").emit("sessions_changed", { reason = "reorder", session_id = session_id })
			return true
		end
	end
	return false
end

function M.reopen(opts)
	opts = opts or {}
	local id = state.get_closed_session_order()[1]
	if not id then vim.notify("No closed OpenCode session tab", vim.log.levels.INFO); return end
	local token = pending.token(id)
	local views = require("opencode.session.views").registry()
	local source = opts.view or (views and type(views.current) == "function" and views.current()) or nil
	local guard = focus.guard(source, opts.generation)
	local initial_input = opts.initial_input
	if initial_input == nil then initial_input = focus.capture_input(source) end
	require("opencode.client").get_session(id, function(err, info)
		guard.dispose()
		if not pending.is_current(token) or state.get_closed_session_order()[1] ~= id or not guard.valid() then return end
		if err then
			if err.status == 404 then state.remove_session(id) end
			vim.notify("Could not reopen session: " .. tostring(err.message or err), vim.log.levels.WARN)
			return
		end
		focus.open_fetched(guard, info, { view = guard.owner, reason = "reopen", notify = false }, initial_input)
	end)
end

function M.setup(events)
	M.teardown()
	bus = events
	subscriptions.disconnected = events.on("disconnected", M.clear)
	subscriptions.connected = events.on("connected", function()
		for _, entry in pairs(observations) do entry.acknowledgement = nil end
	end)
	local group = vim.api.nvim_create_augroup("OpenCodeViewed", { clear = true })
	vim.api.nvim_create_autocmd("FocusLost", { group = group, callback = function() focused = false end })
	vim.api.nvim_create_autocmd({ "FocusGained", "TabEnter" }, { group = group, callback = function(event)
		if event.event == "FocusGained" then focused = true end
		for id, entry in pairs(observations) do M.observe(id, entry.visible) end
	end })
end

return M
