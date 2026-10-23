-- Session catalog operations keep remote metadata and navigation behind actions.
local M = {}
local state = require("opencode.state")
local pending = require("opencode.session.pending")
local focus = require("opencode.session.focus")
local schedule = require("opencode.util.schedule").schedule_callback
local opens, renames = setmetatable({}, { __mode = "k" }), {}

local function valid_id(id)
	return type(id) == "string" and vim.trim(id) ~= "" and not id:find("[%z\r\n]")
end

function M.open(id, opts, callback)
	opts = opts or {}
	if not valid_id(id) then schedule(callback, { message = "Enter a valid session ID" }); return end
	local views = package.loaded["opencode.ui.chat.state"]
	local view = opts.view or (views and views.current and views.current())
	local guard = focus.guard(view)
	local initial_input = focus.capture_input(view)
	local key, request = guard.owner or M, {}
	opens[key] = request
	local token = pending.token(id)
	if guard.owner then opts = vim.tbl_extend("force", opts, { view = guard.owner }) end
	local function current()
		return opens[key] == request and pending.is_current(token) and guard.valid()
	end
	local function finish(err, info)
		schedule(function()
			guard.dispose()
			if not current() then return end
			if not err then focus.open_fetched(guard, info, opts, initial_input) end
			if callback then callback(err, info) end
		end)
	end
	require("opencode.lifecycle").ensure_connected(function()
		if not current() then guard.dispose(); return end
		local client = require("opencode.client")
		client.get_session(id, function(err, info)
			if not current() then guard.dispose(); return end
			if err then finish(err); return end
			if info.id ~= id then finish({ message = "Server returned a different session ID" }); return end
			local directory = info.location and info.location.directory
			if not require("opencode.util.path").is_absolute(directory) then finish({ message = "Session has an invalid server location" }); return end
			client.get_location(directory, function(location_err, location)
				if location_err then
					finish({ status = location_err.status, code = "location_unavailable",
						message = "Session location is unavailable: " .. tostring(location_err.message or location_err) }); return
				end
				local normalize = require("opencode.util.path").normalize
				if not location or normalize(location.directory) ~= normalize(directory) then
					finish({ code = "location_mismatch", message = "Server resolved a different session location" }); return
				end
				finish(nil, info)
			end)
		end)
	end)
end

function M.rename(id, title, callback)
	if not valid_id(id) or type(title) ~= "string" or title:find("%z") then
		schedule(callback, { message = "Enter a valid session ID and title" }); return
	end
	title = vim.trim(title)
	local token = pending.token(id)
	renames[id] = token
	local function current() return renames[id] == token and pending.is_current(token) end
	require("opencode.lifecycle").ensure_connected(function()
		if not current() then return end
		local client = require("opencode.client")
		client.update_session(id, title, function(err)
			if not current() then return end
			if err then
				schedule(function()
					if not current() then return end
					renames[id] = nil
					if callback then callback(err) end
				end)
				return
			end
			local snapshot = state.get_session_record(id)
			client.get_session(id, function(read_err, info)
				schedule(function()
					if not current() then return end
					if not read_err then
						if info.id ~= id then read_err = { message = "Server returned a different session ID" }
						else
							local sessions = require("opencode.session")
							local latest = state.get_session_record(id)
							if not vim.deep_equal(snapshot, latest) then info = latest
							else sessions.remember(info, { touch = false, reason = "session_rename" }) end
							if info and state.get_session().id == id then
								sessions.set_active(id, info.title, { reason = "session_rename", preserve_cache = true, runtime = state.is_runtime_session(id) })
							end
						end
					end
					renames[id] = nil
					if callback then callback(read_err, info) end
				end)
			end)
		end)
	end)
end

function M.move(id, directory, callback)
	if not valid_id(id) or type(directory) ~= "string" or vim.trim(directory) == "" or directory:find("[%z\r\n]") then
		schedule(callback, { message = "Enter a valid session ID and server directory" }); return
	end
	-- The server resolves relative paths and ~ against this session's location.
	local token = pending.token(id)
	require("opencode.lifecycle").ensure_connected(function()
		if not pending.is_current(token) then return end
		require("opencode.client").move_session(id, vim.trim(directory), function(err, result)
			schedule(function()
				if not pending.is_current(token) then return end
				if not err then require("opencode.events").emit("session_reconcile", { session_id = id }) end
				if callback then callback(err, result) end
			end)
		end)
	end)
end

return M
