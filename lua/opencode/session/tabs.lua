-- Tab layout persistence and native viewed acknowledgements. Runtime data lives in state.lua.
local M = {}
local state = require("opencode.state")
local pending = require("opencode.session.pending")
local owner, scope, listener, bus
local subscriptions = {}
local focused, visible, observed = true, false, nil
local acknowledgement, retry_timer
local generation = 0
local retry_count = 0

local function cancel_retry()
	if retry_timer then
		pcall(retry_timer.stop, retry_timer); pcall(retry_timer.close, retry_timer)
		retry_timer = nil
	end
end

function M.clear()
	generation = generation + 1
	cancel_retry()
	acknowledgement, visible, observed = nil, false, nil
	retry_count = 0
end

function M.teardown()
	M.clear()
	if listener then state.off("*", listener) end
	if bus then for event, callback in pairs(subscriptions) do bus.off(event, callback) end end
	listener, bus, owner, subscriptions = nil, nil, nil, {}
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
	if observed ~= session_id then retry_count = 0 end
	observed, visible = session_id, is_visible == true
	if not focused or not visible or not state.is_connected() or not session_id then return end
	local info = state.get_session_record(session_id)
	local time = info and info.time or {}
	local idle = time.idle
	if type(idle) ~= "number" or (type(time.viewed) == "number" and time.viewed >= idle) then return end
	if acknowledgement and acknowledgement.id == session_id and acknowledgement.idle == idle then return end
	cancel_retry()
	local attempt = { id = session_id, idle = idle, generation = generation, token = pending.token(session_id) }
	acknowledgement = attempt
	require("opencode.client").view_session(session_id, idle, function(err)
		if acknowledgement ~= attempt or generation ~= attempt.generation or not pending.is_current(attempt.token) then return end
		if not err then
			retry_count = 0
			require("opencode.session").remember({ id = session_id, time = { viewed = idle } }, { touch = false, reason = "viewed" })
			return
		end
		-- Auth/config errors require intervention; keep unread rather than retrying forever.
		if err.retryable == false or err.status == 401 or err.status == 403 or err.status == 404 then return end
		retry_count = retry_count + 1
		local delay = math.min(1000 * 2 ^ math.min(retry_count - 1, 5), 30000)
		retry_timer = vim.defer_fn(function()
			retry_timer = nil
			if acknowledgement ~= attempt or generation ~= attempt.generation then return end
			acknowledgement = nil
			M.observe(observed, visible)
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

function M.reopen()
	local id = state.get_closed_session_order()[1]
	if not id then vim.notify("No closed OpenCode session tab", vim.log.levels.INFO); return end
	local token = pending.token(id)
	local current = state.get_session().id
	require("opencode.client").get_session(id, function(err, info)
		if not pending.is_current(token) or state.get_session().id ~= current or state.get_closed_session_order()[1] ~= id then return end
		if err then
			if err.status == 404 then state.remove_session(id); save() end
			vim.notify("Could not reopen session: " .. tostring(err.message or err), vim.log.levels.WARN)
			return
		end
		require("opencode.session").switch_to(info, { reason = "reopen", notify = false })
		state.set_closed_session_order(state.get_closed_session_order())
	end)
end

function M.setup(events)
	local previous_scope = owner and scope
	M.teardown()
	bus, subscriptions, owner = events, {}, nil
	local config = state.get_config() or {}
	local options = config.chat and config.chat.session_tabs or {}
	if options.persist ~= false and options.enabled ~= false then
		local server = config.server or {}
		local directory = options.scope == "global" and "global" or state.normalize_directory(vim.fn.getcwd())
		if server.url and server.url ~= false then
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
	subscriptions.connected = events.on("connected", function() acknowledgement = nil end)
	local group = vim.api.nvim_create_augroup("OpenCodeViewed", { clear = true })
	vim.api.nvim_create_autocmd("FocusLost", { group = group, callback = function() focused = false end })
	vim.api.nvim_create_autocmd("FocusGained", { group = group, callback = function() focused = true; M.observe(observed, visible) end })
	if options.scope ~= "global" then
		vim.api.nvim_create_autocmd("DirChanged", { group = group, callback = function() M.setup(events) end })
	end
end

return M
