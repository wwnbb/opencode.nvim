-- Tab layout persistence and native viewed acknowledgements. Runtime data lives in state.lua.
local M = {}
local state = require("opencode.state")
local pending = require("opencode.session.pending")
local owner, scope, listener, bus
local deferred_scope = false
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
	if listener then state.off("*", listener) end
	if bus then for event, callback in pairs(subscriptions) do bus.off(event, callback) end end
	listener, bus, owner, subscriptions = nil, nil, nil, {}
	deferred_scope = false
	pcall(vim.api.nvim_del_augroup_by_name, "OpenCodeViewed")
end

local function save()
	if not owner then return end
	local function records(ids)
		local result = {}
		for _, id in ipairs(ids) do
			local info = state.get_session_record(id) or {}
			result[#result + 1] = { id = id, title = info.title or info.name or id }
		end
		return result
	end
	local scopes = vim.deepcopy(owner.data.scopes or {})
	scopes[scope] = {
		tabs = records(state.get_runtime_session_order()),
		closed = records(state.get_closed_session_order()),
		active = require("opencode.selectors").get_current_runtime_root_id(),
	}
	if not owner.save({ scopes = scopes }) then
		vim.notify("OpenCode: could not save session tabs", vim.log.levels.WARN)
		owner = nil
	end
end

function M.observe(session_id, is_visible)
	if not session_id then return end
	local entry = observations[session_id] or { retry_count = 0 }
	observations[session_id] = entry
	entry.visible = is_visible == true
	if not entry.visible then cancel_retry(entry) end
	if not focused or not entry.visible or not state.is_connected() then return end
	local views = package.loaded["opencode.ui.chat.state"]
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
	local current = state.get_session().id
	local views = package.loaded["opencode.ui.chat.state"]
	local view = opts.view or (views and type(views.current) == "function" and views.current()) or nil
	if view and not view.session_bound then view = nil end
	local generation = opts.generation or (view and view.generation)
	require("opencode.client").get_session(id, function(err, info)
		if not pending.is_current(token) or state.get_closed_session_order()[1] ~= id then return end
		if view then
			if not views.valid(view, generation) then return end
		elseif state.get_session().id ~= current then return end
		if err then
			if err.status == 404 then state.remove_session(id) end
			vim.notify("Could not reopen session: " .. tostring(err.message or err), vim.log.levels.WARN)
			return
		end
		require("opencode.session").switch_to(info, { view = view, reason = "reopen", notify = false })
	end)
end

local function has_tab_workspace()
	local views = package.loaded["opencode.ui.chat.state"]
	if not views or type(views.all) ~= "function" then return false end
	for _, view in ipairs(views.all()) do
		if view.session_bound and view.visible and view.config and view.config.layout == "tab"
			and view.winid and vim.api.nvim_win_is_valid(view.winid) then return true end
	end
	return false
end

-- Keep an open workspace attached to its original persistence scope. Apply a
-- deferred directory change before opening the next workspace.
function M.refresh_scope()
	if deferred_scope and bus and not has_tab_workspace() then M.setup(bus) end
end

function M.setup(events)
	local previous_scope = owner and scope
	M.teardown()
	bus = events
	local config = state.get_config() or {}
	local options = config.chat and config.chat.session_tabs or {}
	if options.persist ~= false and options.enabled ~= false then
		local server = config.server or {}
		local directory = options.scope == "global" and "global" or state.normalize_directory(vim.fn.getcwd())
		if server.url then
			local endpoint = require("opencode.client.endpoint").resolve(server)
			-- Include a proxy's base path, but never persist URL credentials or auth.
			scope = endpoint and vim.json.encode({ endpoint.origin:lower() .. endpoint.base_path, directory }) or nil
		else
			scope = vim.json.encode({ server.host or "localhost", server.port or server.command or "opencode", directory })
		end
		if previous_scope and previous_scope ~= scope then
			state.set_runtime_session_order({})
			state.set_closed_session_order({})
			require("opencode.session").set_active(nil, nil, { preserve_cache = true, reason = "tabs_scope" })
		end
		owner = scope and require("opencode.preferences").open(options.file or (vim.fn.stdpath("data") .. "/opencode_tabs.json")) or nil
		local saved = owner and type(owner.data.scopes) == "table" and owner.data.scopes[scope] or nil
		if type(saved) == "table" and #state.get_runtime_session_order() == 0 then
			local function restore(values)
				local ids = {}
				for _, value in ipairs(type(values) == "table" and values or {}) do
					if type(value) == "table" and type(value.id) == "string" and value.id ~= "" then
						state.upsert_session({ id = value.id, title = type(value.title) == "string" and value.title or value.id }, { touch = false })
						ids[#ids + 1] = value.id
					end
				end
				return ids
			end
			local ids = restore(saved.tabs)
			state.set_runtime_session_order(ids)
			state.set_closed_session_order(restore(saved.closed))
			local active = state.is_runtime_session(saved.active) and saved.active or ids[1]
			if active then
				local info = state.get_session_record(active)
				require("opencode.session").set_active(active, info.title, { preserve_cache = true, reason = "restore_tabs" })
			end
		end
	end
	listener = function(key, new, old)
		if key == "sessions.runtime_order" or key == "sessions.closed_order" or key == "session.id" then save()
		elseif key:match("^sessions%.by_id%.") and (not new or not old or new.title ~= old.title) then save() end
	end
	state.on("*", listener)
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
	if options.scope ~= "global" then
		vim.api.nvim_create_autocmd("DirChanged", { group = group, callback = function()
			if has_tab_workspace() then deferred_scope = true else M.setup(events) end
		end })
	end
end

return M
