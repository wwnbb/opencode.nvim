local M = {}

local Job = require("plenary.job")
local state = require("opencode.state")
local server_env = require("opencode.server_env")
local uv = vim.uv or vim.loop

local pending_callbacks = {}
-- Optional per-callback handlers run when a queued action is discarded, so
-- callers can release resources held for a callback that will never run.
local drop_handlers = setmetatable({}, { __mode = "k" })

-- A managed process remains owned until its exit is observed, including after
-- startup failure or a successful termination signal.
local current_attempt = nil
local restart_generation = 0
local listener_clients = setmetatable({}, { __mode = "k" })

local connect_to_server
local check_existing_server
local complete_connection
local fail_startup
local begin_health_checks
local continue_startup
local setup_event_listeners
local install_exit_hook

M.opts = {
	command = "opencode",
	auto_start = true,
	startup_timeout = 10000,
	health_check_interval = 1000,
	shutdown_on_exit = true,
	use_shell_env = true,
	env = {},
	config_dir = nil,
}

-- Spawned, discovered, explicit-endpoint and untracked-stop attempts share one
-- shape; callers supply the phase and their own fields.
local function new_attempt(fields)
	return vim.tbl_extend("force", {
		connecting = false,
		connection_token = 0,
		disconnected = false,
		exited = false,
		signal_sent = false,
		kill_sent = false,
		stop_waiters = {},
	}, fields)
end

local function error_detail(err)
	if type(err) == "table" then
		return tostring(err.message or err.error or err.code or "unknown error")
	end
	return tostring(err or "unknown error")
end

local function is_current_attempt(attempt)
	return current_attempt == attempt
end

local function stop_attempt_timer(attempt, key)
	local timer = attempt[key]
	attempt[key] = nil
	if not timer then
		return
	end

	if type(timer.stop) == "function" then
		pcall(timer.stop, timer)
	end
	if type(timer.close) == "function" then
		local closing = false
		if uv and uv.is_closing then
			local ok, result = pcall(uv.is_closing, timer)
			closing = ok and result or false
		end
		if not closing then
			pcall(timer.close, timer)
		end
	end
end

local function cancel_attempt_timers(attempt)
	stop_attempt_timer(attempt, "timeout_timer")
	stop_attempt_timer(attempt, "health_timer")
	stop_attempt_timer(attempt, "exit_timer")
	stop_attempt_timer(attempt, "stop_timer")
	stop_attempt_timer(attempt, "event_timer")
end

local function signal_succeeded(ok, result, err)
	return ok and result ~= false and not (result == nil and err ~= nil)
end

local function signal_process(job, pid, signal)
	signal = signal or 15
	local handle = job and job.handle
	if handle and type(handle.kill) == "function" then
		local closing = false
		if uv and uv.is_closing then
			local ok, result = pcall(uv.is_closing, handle)
			closing = ok and result or false
		end
		if not closing then
			local ok, result, err = pcall(handle.kill, handle, signal)
			if signal_succeeded(ok, result, err) then
				return true
			end
		end
	end

	if pid and uv and type(uv.kill) == "function" then
		local ok, result, err = pcall(uv.kill, pid, signal)
		if signal_succeeded(ok, result, err) then
			return true
		end
	end

	return false
end

local function signal_attempt(attempt, signal)
	signal = signal or 15
	if attempt.exited then
		return true
	end
	if signal == 15 and attempt.signal_sent then
		return true
	end
	if signal == 9 and attempt.kill_sent then
		return true
	end

	local signaled = signal_process(attempt.job, attempt.pid, signal)
	if signaled then
		if signal == 9 then
			attempt.kill_sent = true
		else
			attempt.signal_sent = true
		end
	end
	return signaled
end

local function stop_watchdog(attempt)
	local watchdog = attempt.watchdog
	attempt.watchdog = nil
	if watchdog then watchdog.stop() end
end

-- Recreated by setup() and by every spawn, so an owned server is stopped on a
-- normal exit whichever ran first. Abnormal exits are left to the watchdog.
install_exit_hook = function()
	local group = vim.api.nvim_create_augroup("OpenCodeLifecycle", { clear = true })
	if not M.opts.shutdown_on_exit then return end
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			if state.is_server_managed() then
				M.stop()
			end
		end,
	})
end

local function disconnect_events()
	local ok, client = pcall(require, "opencode.client")
	if ok and client and type(client.disconnect_events) == "function" then
		client.disconnect_events()
	end
end

local function take_pending_callbacks()
	local callbacks = pending_callbacks
	pending_callbacks = {}
	return callbacks
end

local function drop_callbacks(callbacks, first)
	for index = first or 1, #(callbacks or {}) do
		local on_drop = drop_handlers[callbacks[index]]
		drop_handlers[callbacks[index]] = nil
		if on_drop then require("opencode.util.schedule").schedule_pcall("dropped action handler", on_drop) end
	end
end

local function drop_pending_callbacks()
	drop_callbacks(take_pending_callbacks())
end

local function remove_pending_callback(callback)
	for index = #pending_callbacks, 1, -1 do
		if pending_callbacks[index] == callback then
			table.remove(pending_callbacks, index)
			drop_callbacks({ callback })
			return
		end
	end
end

local function process_callbacks(callbacks, attempt, token)
	for index, callback in ipairs(callbacks or {}) do
		if state.get_connection() ~= "connected" or current_attempt ~= attempt
			or (attempt and attempt.connection_token ~= token) then
			drop_callbacks(callbacks, index)
			return
		end
		drop_handlers[callback] = nil
		local ok, err = pcall(callback)
		if not ok then
			vim.notify("Pending callback error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

local function run_stop_waiters(waiters)
	for _, callback in ipairs(waiters or {}) do
		local ok, err = pcall(callback)
		if not ok then
			vim.notify("Stop callback error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

local function release_attempt(attempt, connection)
	if not is_current_attempt(attempt) then
		return {}
	end

	cancel_attempt_timers(attempt)
	attempt.connection_token = attempt.connection_token + 1
	attempt.connecting = false
	drop_pending_callbacks()

	local waiters = attempt.stop_waiters or {}
	attempt.stop_waiters = {}
	current_attempt = nil

	state.set_server_pid(nil)
	state.set_server_managed(false)
	state.clear_server_endpoint()
	state.set_connection(connection)
	return waiters
end

local function arm_stop_timeout(attempt)
	if not is_current_attempt(attempt) or attempt.phase ~= "stopping" or attempt.exited then
		return
	end

	stop_attempt_timer(attempt, "stop_timer")
	attempt.stop_timer = vim.defer_fn(function()
		if not is_current_attempt(attempt) or attempt.phase ~= "stopping" or attempt.exited then
			return
		end
		attempt.stop_timer = nil

		if attempt.kill_sent then
			vim.notify("OpenCode server did not exit after SIGKILL; releasing ownership", vim.log.levels.ERROR)
			local waiters = release_attempt(attempt, "error")
			run_stop_waiters(waiters)
			return
		end

		vim.notify("OpenCode server did not exit; sending SIGKILL", vim.log.levels.WARN)
		if signal_attempt(attempt, 9) then
			arm_stop_timeout(attempt)
			return
		end

		attempt.phase = "stop_error"
		state.set_connection("error")
		vim.notify("Failed to stop OpenCode server", vim.log.levels.ERROR)
	end, M.opts.startup_timeout)
end

local function has_owned_process(attempt)
	return attempt.pid ~= nil or (attempt.job and attempt.job.handle ~= nil)
end

local function connection_is_current(attempt, token, startup)
	if not is_current_attempt(attempt) then
		return false
	end
	if not attempt.connecting or attempt.connection_token ~= token then
		return false
	end
	if attempt.disconnected or attempt.phase == "stopping" or attempt.phase == "stop_error" then
		return false
	end
	if startup then
		return not attempt.startup_done
	end
	return attempt.startup_done and attempt.phase == "ready"
end

local function arm_startup_timeout(attempt)
	if not is_current_attempt(attempt) or attempt.startup_done or attempt.phase ~= "starting" then
		return
	end

	stop_attempt_timer(attempt, "timeout_timer")
	attempt.timeout_timer = vim.defer_fn(function()
		if not is_current_attempt(attempt) or attempt.startup_done or attempt.phase ~= "starting" then
			return
		end
		attempt.timeout_timer = nil
		fail_startup(attempt, "OpenCode server startup timed out")
	end, M.opts.startup_timeout)
end

fail_startup = function(attempt, message)
	if not is_current_attempt(attempt) or attempt.startup_done then
		return false
	end

	attempt.startup_done = true
	attempt.connecting = false
	attempt.connection_token = attempt.connection_token + 1
	attempt.disconnected = false
	attempt.stop_reason = "failure"
	drop_pending_callbacks()
	cancel_attempt_timers(attempt)
	state.set_connection("error")

	if attempt.exited or not has_owned_process(attempt) then
		local waiters = release_attempt(attempt, "error")
		vim.notify(message, vim.log.levels.ERROR)
		run_stop_waiters(waiters)
		return true
	end

	disconnect_events()
	if signal_attempt(attempt) then
		attempt.phase = "stopping"
		arm_stop_timeout(attempt)
		vim.notify(message, vim.log.levels.ERROR)
	else
		attempt.phase = "stop_error"
		vim.notify(message .. "; failed to terminate managed server", vim.log.levels.ERROR)
	end
	return true
end

check_existing_server = function(attempt, token, startup, callback)
	if not connection_is_current(attempt, token, startup) then
		return
	end

	local server_info = state.get_server_info()
	if not server_info.port and not server_info.url then
		callback(false)
		return
	end

	local http = require("opencode.client.http")
	http.health(function(err, data)
		if not connection_is_current(attempt, token, startup) then
			return
		end
		if err or not data or not data.version then
			callback(false, nil, err)
			return
		end
		if attempt.registration then
			local identity_err = require("opencode.managed").validate(attempt.registration, data)
			if identity_err then callback(false, nil, identity_err); return end
			attempt.verified = true
		end
		callback(true, data.version)
	end)
end

complete_connection = function(attempt, token, startup, success, version, failure_message)
	if not connection_is_current(attempt, token, startup) then
		return false
	end

	attempt.connecting = false
	attempt.awaiting_event = nil
	stop_attempt_timer(attempt, "health_timer")
	stop_attempt_timer(attempt, "event_timer")

	if not success then
		drop_pending_callbacks()
		if startup then
			return fail_startup(attempt, failure_message)
		end
		state.set_connection("error")
		vim.notify(failure_message, vim.log.levels.ERROR)
		return true
	end

	if startup then
		attempt.startup_done = true
		attempt.phase = "ready"
		stop_attempt_timer(attempt, "timeout_timer")
	end

	state.set_connection("connected")
	state.set_server_info({ version = version })

	local callbacks = take_pending_callbacks()
	vim.schedule(function()
		process_callbacks(callbacks, attempt, token)
	end)
	vim.notify("OpenCode connected (server v" .. (version or "unknown") .. ")", vim.log.levels.INFO)
	return true
end

begin_health_checks = function(attempt, startup)
	if not is_current_attempt(attempt) then
		return false
	end
	if attempt.phase == "stopping" or attempt.phase == "stop_error" then
		return false
	end

	attempt.connection_token = attempt.connection_token + 1
	attempt.connecting = true
	local token = attempt.connection_token

	local function check(retry)
		if not connection_is_current(attempt, token, startup) then
			return
		end

		check_existing_server(attempt, token, startup, function(running, version, err)
			if not connection_is_current(attempt, token, startup) then
				return
			end
			if running then
				connect_to_server(attempt, token, startup, version)
			elseif retry or (err and (err.status == 401 or err.code == "incompatible_response")) then
				complete_connection(
					attempt,
					token,
					startup,
					false,
					nil,
					"OpenCode server health check failed" .. (err and (": " .. error_detail(err)) or "")
				)
			else
				attempt.health_timer = vim.defer_fn(function()
					if not connection_is_current(attempt, token, startup) then
						return
					end
					attempt.health_timer = nil
					check(true)
				end, 500)
			end
		end)
	end

	check(false)
	return true
end

continue_startup = function(attempt)
	if not is_current_attempt(attempt) then
		return false
	end
	if attempt.startup_done or attempt.phase ~= "starting" or attempt.disconnected or attempt.connecting then
		return false
	end

	local server_info = attempt.listening_info
	if not server_info then
		return true
	end

	if not attempt.configured then
		state.set_server_info({
			url = false,
			host = server_info.host,
			port = server_info.port,
		})

		-- A new owned process replaces any previous endpoint: restart the stream
		-- and invalidate requests bound to the old server.
		require("opencode.client").configure_endpoint({
			url = false,
			resolve_endpoint = false,
			host = server_info.host,
			port = server_info.port,
			auth = attempt.auth,
		}, { reset_stream = true })

		attempt.configured = true
	end

	state.set_connection("connecting")
	return begin_health_checks(attempt, true)
end

local function spawn_server()
	local host = state.get_server_info().host
	local auth = vim.deepcopy(M.opts.auth or {})
	auth.username = auth.username or "opencode"
	if type(auth.password) ~= "string" or auth.password == "" then
		-- v2 generates a password when omitted. Supply our own ephemeral secret
		-- before spawning so HTTP/SSE can authenticate without scraping stdout.
		local random, err = uv.random(32)
		if not random then vim.notify("Could not initialize OpenCode server authentication: " .. tostring(err), vim.log.levels.ERROR); return false end
		auth.password = (random:gsub(".", function(byte) return string.format("%02x", byte:byte()) end))
	end
	local env = server_env.build(M.opts, auth)
	local config = state.get_config() or {}
	local overlay, profiles = require("opencode.completion.profile").prepare_all({
		completion = config.completion or M.opts.completion,
		explanation = config.explanation or M.opts.explanation,
	}, env.OPENCODE_CONFIG_CONTENT)
	env.OPENCODE_CONFIG_CONTENT = overlay

	-- CLI 2.0.11 requires an integer. Zero requests an available OS port.
	local cmd = server_env.resolve_command(M.opts.command, env)
	local args = {
		"serve",
		"--hostname",
		host,
		"--port",
		"0",
	}

	local attempt = new_attempt({ profiles = profiles, auth = auth, phase = "starting", startup_done = false })
	current_attempt = attempt
	-- Spawning owns a process even when setup() never ran.
	install_exit_hook()

	state.set_connection("starting")
	state.set_server_managed(true)
	state.set_server_pid(nil)

	local ok, server_job = pcall(function()
		return Job:new({
			command = cmd,
			args = args,
			env = env,
			enable_recording = false,
			on_stdout = function(_, data)
				if not is_current_attempt(attempt) or attempt.startup_done or attempt.phase ~= "starting" or not data then
					return
				end
				if data:match("^server password ") then return end

				local server_info = server_env.parse_server_url(data)
				if server_info and not attempt.listening_info then
					attempt.listening_info = server_info
					vim.schedule(function()
						if not is_current_attempt(attempt) then
							return
						end
						continue_startup(attempt)
					end)
				end
			end,
			on_exit = function(_, code)
				stop_watchdog(attempt)
				if not is_current_attempt(attempt) then
					return
				end
				attempt.exited = true

				vim.schedule(function()
					if not is_current_attempt(attempt) then
						return
					end

					if attempt.stop_reason then
						local reason = attempt.stop_reason
						local connection = reason == "failure" and "error" or "idle"
						local waiters = release_attempt(attempt, connection)
						if reason == "stop" then
							vim.notify("OpenCode server stopped", vim.log.levels.INFO)
						end
						run_stop_waiters(waiters)
						return
					end

					if not attempt.startup_done then
						fail_startup(
							attempt,
							"OpenCode server exited before readiness with code: " .. tostring(code)
						)
						return
					end

					-- The port is gone with the process; reconnecting would retry it forever.
					disconnect_events()
					local waiters = release_attempt(attempt, "idle")
					if code ~= 0 and code ~= 143 then -- 143 is SIGTERM
						vim.notify("OpenCode server exited with code: " .. code, vim.log.levels.WARN)
					end
					run_stop_waiters(waiters)
				end)
			end,
		})
	end)

	if not ok then
		fail_startup(attempt, "Failed to start OpenCode server: " .. error_detail(server_job))
		return false
	end

	attempt.job = server_job
	arm_startup_timeout(attempt)

	local started, start_err = pcall(function()
		server_job:start()
	end)
	attempt.pid = server_job.pid
	if attempt.pid and is_current_attempt(attempt) then
		state.set_server_pid(attempt.pid)
	end
	-- Only a real process gets a watchdog, and only once it has not exited.
	if started and M.opts.shutdown_on_exit and type(server_job.handle) == "userdata" and not attempt.exited then
		attempt.watchdog = require("opencode.server_watchdog").start(attempt.pid)
	end

	if not started then
		fail_startup(attempt, "Failed to start OpenCode server: " .. error_detail(start_err))
		return false
	end

	return is_current_attempt(attempt) and (attempt.phase == "starting" or attempt.phase == "ready")
end

setup_event_listeners = function(client)
	if listener_clients[client] then
		return
	end
	client.on_event("disconnected", function(reason)
		if
			current_attempt
			and (current_attempt.disconnected or current_attempt.phase == "stopping" or current_attempt.phase == "stop_error")
		then
			return
		end
		-- An attempt still starting or checking health owns its outcome through
		-- its own timers; downgrading it here would strand queued actions.
		if current_attempt and (current_attempt.connecting or not current_attempt.startup_done) then
			return
		end
		if current_attempt then
			current_attempt.connection_token = current_attempt.connection_token + 1
		end
		-- SSE reports every failed reconnect as a close; only the first one is news.
		local connection = state.get_connection()
		if connection == "idle" or connection == "error" then
			return
		end
		state.set_connection("idle")
		vim.notify("OpenCode disconnected: " .. (reason or "unknown"), vim.log.levels.WARN)
	end)

	-- Server connection event (from server, not SSE level)
	client.on_event("server.connected", function()
		if current_attempt and (current_attempt.disconnected or current_attempt.phase == "stopping" or current_attempt.phase == "stop_error") then
			return
		end
		local attempt = current_attempt
		local waiting = attempt and attempt.awaiting_event
		if waiting then
			complete_connection(attempt, waiting.token, waiting.startup, true, waiting.version)
			return
		end
		-- A health check in flight completes readiness itself.
		if attempt and attempt.connecting then return end
		state.set_connection("connected")
	end)

	listener_clients[client] = true
end

connect_to_server = function(attempt, token, startup, version)
	if not connection_is_current(attempt, token, startup) then
		return false
	end

	local client = require("opencode.client")
	setup_event_listeners(client)
	attempt.awaiting_event = { token = token, startup = startup, version = version }
	stop_attempt_timer(attempt, "event_timer")
	attempt.event_timer = vim.defer_fn(function()
		if not connection_is_current(attempt, token, startup) then return end
		attempt.event_timer = nil
		complete_connection(attempt, token, startup, false, nil, "OpenCode event stream did not send server.connected")
	end, M.opts.startup_timeout)

	local ok, connected, connect_err = pcall(function()
		return client.connect_events()
	end)
	if not ok then
		connect_err = connected
		connected = false
	end

	if connected ~= true then
		return complete_connection(
			attempt,
			token,
			startup,
			false,
			nil,
			"Failed to connect OpenCode event stream: " .. error_detail(connect_err)
		)
	end
	-- An automatic SSE reconnect may already have received server.connected;
	-- connect_events() keeps that stream and no second event will arrive.
	local sse = client.sse
	if attempt.awaiting_event and attempt.awaiting_event.token == token
		and sse and type(sse.is_connected) == "function" and sse.is_connected() then
		return complete_connection(attempt, token, startup, true, version)
	end

	return true -- Native server.connected completes readiness exactly once.
end

local function discover_managed(attempt, callback, guard, allow_start)
	return require("opencode.managed").discover(attempt, {
		opts = function() return M.opts end,
		current = function() return is_current_attempt(attempt) and not attempt.disconnected and (not guard or guard()) end,
	}, callback, allow_start)
end

local function begin_managed(attempt)
	attempt.disconnected = false
	state.set_connection("connecting")
	local token = attempt.connection_token
	local client = require("opencode.client")
	client.configure_endpoint({ resolve_endpoint = function(callback, guard)
		return discover_managed(attempt, callback, guard, true)
	end })
	local finished = false
	local discovery = discover_managed(attempt, function(err)
		finished, attempt.discovery = true, nil
		if not is_current_attempt(attempt) or attempt.disconnected or token ~= attempt.connection_token then return end
		if err then drop_pending_callbacks(); state.set_connection("error"); vim.notify(err.message, vim.log.levels.ERROR)
		else begin_health_checks(attempt, false) end
	end, nil, true)
	-- Only the first discovery step is cancellable; later steps check staleness.
	if not finished then attempt.discovery = discovery end
	return true
end

-- Ensure server is connected (lazy initialization entry point)
---@param callback function Called when connection is ready
---@param on_drop? function Called (scheduled) instead when the action is discarded
function M.ensure_connected(callback, on_drop)
	local connection = state.get_connection()
	if on_drop then drop_handlers[callback] = on_drop end

	if connection == "connected" then
		-- Queue the action for this connection only.
		local attempt = current_attempt
		local token = attempt and attempt.connection_token
		vim.schedule(function() process_callbacks({ callback }, attempt, token) end)
		return true
	end

	local attempt = current_attempt
	if (connection == "idle" or connection == "error") and attempt and attempt.phase == "stopping" then
		-- Retry once the stopping process exits; a restart waiter registered
		-- earlier starts its replacement first. Disconnect, stop and setup cancel it.
		local generation = restart_generation
		table.insert(attempt.stop_waiters, function()
			if generation ~= restart_generation then drop_callbacks({ callback }); return end
			M.ensure_connected(callback)
		end)
		return false
	end

	if connection == "idle" or connection == "error" then
		table.insert(pending_callbacks, callback)
		if not M.start() then
			remove_pending_callback(callback)
			if attempt and attempt.phase == "stop_error" and current_attempt == attempt then
				vim.notify("OpenCode server could not be stopped; stop it again before reconnecting", vim.log.levels.ERROR)
			end
		end
		return false
	end

	if connection == "starting" or connection == "connecting" then
		table.insert(pending_callbacks, callback)
		return false
	end

	return false
end

function M.start()
	local connection = state.get_connection()
	if connection ~= "idle" and connection ~= "error" then
		return false -- Already starting/connecting/connected
	end

	if current_attempt then
		local attempt = current_attempt
		if attempt.connecting and attempt.phase ~= "stopping" and attempt.phase ~= "stop_error" then
			-- A health or event check in flight decides this attempt; wait for it.
			state.set_connection("connecting")
			return true
		end
		if attempt.phase == "ready" then
			if attempt.discovered then return begin_managed(attempt) end
			attempt.disconnected = false
			state.set_connection("connecting")
			return begin_health_checks(attempt, false)
		end
		if attempt.phase == "starting" and not attempt.startup_done then
			attempt.disconnected = false
			state.set_connection("starting")
			-- Keep the original deadline; only a disconnect stops this timer.
			if not attempt.timeout_timer then arm_startup_timeout(attempt) end
			if attempt.listening_info then
				return continue_startup(attempt)
			end
			return true
		end
		return false
	end

	-- Explicit endpoints are external even when auto_start is enabled. An auth
	-- or version failure must never replace them with a new managed server.
	if M.opts.url and M.opts.managed then
		vim.notify("Choose either server.url or server.managed", vim.log.levels.ERROR)
		return false
	end
	if M.opts.managed then
		local attempt = new_attempt({ phase = "ready", startup_done = true, external = true, discovered = true })
		current_attempt = attempt
		state.set_server_managed(false)
		state.set_server_pid(nil)
		return begin_managed(attempt)
	end
	if M.opts.port or M.opts.url then
		local attempt = new_attempt({ phase = "ready", startup_done = true, external = true })
		current_attempt = attempt
		state.set_server_managed(false)
		state.set_server_pid(nil)
		state.set_connection("connecting")
		return begin_health_checks(attempt, false)
	end
	if not M.opts.auto_start then
		vim.notify("OpenCode auto-start is disabled", vim.log.levels.WARN)
		return false
	end
	return spawn_server()
end

local function pid_is_running(pid)
	if not pid or not uv or type(uv.kill) ~= "function" then
		return nil
	end

	local ok, result, err = pcall(uv.kill, pid, 0)
	if not ok then
		return nil
	end
	if signal_succeeded(ok, result, err) then
		return true
	end

	local detail = tostring(err or result or ""):lower()
	if detail:find("esrch", 1, true) or detail:find("no such process", 1, true) then
		return false
	end
	return nil
end

local function observe_untracked_exit(attempt)
	if not is_current_attempt(attempt) or not attempt.untracked or attempt.phase ~= "stopping" then
		return
	end

	local interval = math.max(50, tonumber(M.opts.health_check_interval) or 100)

	local function check()
		if not is_current_attempt(attempt) or attempt.phase ~= "stopping" then
			return
		end

		if pid_is_running(attempt.pid) == false then
			attempt.exited = true
			local waiters = release_attempt(attempt, "idle")
			vim.notify("OpenCode server stopped", vim.log.levels.INFO)
			run_stop_waiters(waiters)
			return
		end

		attempt.exit_timer = vim.defer_fn(function()
			if not is_current_attempt(attempt) then
				return
			end
			attempt.exit_timer = nil
			check()
		end, interval)
	end

	check()
end

-- Stop server (only if we started it)
function M.stop(on_stopped)
	restart_generation = restart_generation + 1
	if not state.is_server_managed() then
		vim.notify("Cannot stop external OpenCode server", vim.log.levels.WARN)
		return false
	end

	local attempt = current_attempt
	local pid = state.get_server_pid() or (attempt and attempt.pid)
	if not attempt then
		if not pid then
			vim.notify("No OpenCode server PID found", vim.log.levels.WARN)
			return false
		end

		attempt = new_attempt({ phase = "ready", startup_done = true, pid = pid, untracked = true })
		current_attempt = attempt
	end

	if type(on_stopped) == "function" then
		table.insert(attempt.stop_waiters, on_stopped)
	end

	if attempt.phase == "stopping" then
		return true
	end
	if not pid and not (attempt.job and attempt.job.handle) then
		vim.notify("No OpenCode server PID found", vim.log.levels.WARN)
		return false
	end

	attempt.startup_done = true
	attempt.connecting = false
	attempt.connection_token = attempt.connection_token + 1
	attempt.disconnected = true
	attempt.stop_reason = "stop"
	drop_pending_callbacks()
	cancel_attempt_timers(attempt)
	disconnect_events()

	if not signal_attempt(attempt) then
		attempt.phase = "stop_error"
		state.set_connection("error")
		vim.notify("Failed to stop OpenCode server", vim.log.levels.ERROR)
		return false
	end

	attempt.phase = "stopping"
	state.set_connection("idle")
	arm_stop_timeout(attempt)
	if attempt.untracked then
		observe_untracked_exit(attempt)
	end
	return true
end

function M.restart()
	if current_attempt and current_attempt.discovered then
		return M.manage_service("restart", function(err)
			if err then vim.notify(err.message, vim.log.levels.ERROR) end
		end)
	elseif state.is_server_managed() then
		local restart = restart_generation + 1
		M.stop(function()
			if restart == restart_generation then M.start() end
		end)
	else
		M.disconnect()
		M.start()
	end
end

function M.managed_status()
	return require("opencode.managed").status(current_attempt, M.opts)
end

function M.manage_service(operation, callback)
	callback = callback or function() end
	if operation ~= "restart" and operation ~= "upgrade" then callback({ message = "Unsupported service operation" }); return end
	if not M.managed_status().can_manage then
		callback({ message = "This operation requires the verified native service on this local managing host", code = "unsupported" }); return
	end
	local attempt = current_attempt
	local generation, token, info = restart_generation, attempt.connection_token, vim.deepcopy(attempt.registration)
	return require("opencode.client.http").health(function(err, health)
		if not is_current_attempt(attempt) or generation ~= restart_generation or token ~= attempt.connection_token then return end
		local managed = require("opencode.managed")
		local failure = err or managed.validate(info, health)
		if failure or not managed.same(info, managed.read(M.opts)) then callback(failure or { message = "Managed service registration changed", code = "stale_connection" }); return end
		if operation == "restart" then M.disconnect() end
		local action_generation = restart_generation
		managed.native_cli(M.opts, operation == "restart" and { "service", "restart" } or { "upgrade" }, function(command_err)
			if not is_current_attempt(attempt) or action_generation ~= restart_generation then return end
			-- A failed CLI restart may leave the old daemon healthy. Rediscover
			-- either result; an updater runs while the current chat stays usable.
			if operation == "restart" then M.start() end
			callback(command_err)
		end)
	end)
end

-- Disconnect from server (keep server running)
function M.disconnect()
	restart_generation = restart_generation + 1
	local client = require("opencode.client")
	local cleanup = require("opencode.cleanup")
	local attempt = current_attempt

	if attempt then
		attempt.connection_token = attempt.connection_token + 1
		attempt.connecting = false
		attempt.disconnected = true
		local discovery = attempt.discovery
		attempt.discovery = nil
		if type(discovery) == "table" and type(discovery.cancel) == "function" then pcall(discovery.cancel) end
		stop_attempt_timer(attempt, "health_timer")
		stop_attempt_timer(attempt, "event_timer")
		attempt.awaiting_event = nil
		if not attempt.startup_done then
			stop_attempt_timer(attempt, "timeout_timer")
		end
	end

	client.disconnect_events()
	cleanup.clear_transient({
		clear_chat = true,
		reset_state = false,
	})
	drop_pending_callbacks()
	if attempt and attempt.phase == "stop_error" then
		state.set_connection("error")
	else
		state.set_connection("idle")
	end

	vim.notify("OpenCode disconnected", vim.log.levels.INFO)
end

---@param opts table
function M.setup(opts)
	restart_generation = restart_generation + 1
	opts = opts or {}
	M.opts = vim.tbl_extend("force", M.opts, vim.deepcopy(opts))
	server_env.reset_shell_env()

	install_exit_hook()
end

---Whether this plugin owns the server process, so feature options can be
---installed as a process overlay. Explicit port/url and discovered native
---daemons are external.
function M.owns_server()
	local attempt = current_attempt
	if attempt then return not attempt.external end
	return M.opts.port == nil and not M.opts.url and not M.opts.managed
end

---Return the selector for a profile installed in the connected server.
local function resolve_feature_model(config, kind)
	local feature = current_attempt and current_attempt.profiles and current_attempt.profiles[kind]
	return require("opencode.completion.profile").resolve(config, {
		managed = M.owns_server(),
		active = feature and feature.active,
		error = feature and feature.error,
	}, kind)
end

function M.resolve_completion_model(config)
	return resolve_feature_model(config, "completion")
end

function M.resolve_explanation_model(config)
	return resolve_feature_model(config, "explanation")
end

---The hidden explanation agent, when this plugin spawned the server with it.
---@return string|nil
function M.explanation_agent()
	local feature = current_attempt and not current_attempt.external
		and current_attempt.profiles and current_attempt.profiles.explanation
	return feature and feature.agent or nil
end

function M.status()
	return {
		connection = state.get_connection(),
		server_pid = state.get_server_pid(),
		server_managed = state.is_server_managed(),
		pending_callbacks = #pending_callbacks,
	}
end

return M
