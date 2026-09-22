-- opencode.nvim - Lifecycle management module
-- Handles lazy initialization and server lifecycle

local M = {}

local Job = require("plenary.job")
local state = require("opencode.state")
local uv = vim.uv or vim.loop

-- Pending callbacks queue for lazy initialization
local pending_callbacks = {}

-- A managed process remains owned until its exit is observed, including after
-- startup failure or a successful termination signal.
local attempt_generation = 0
local current_attempt = nil
local listener_clients = setmetatable({}, { __mode = "k" })

-- Forward declarations for functions that need to be called before their definition
local connect_to_server
local check_existing_server
local complete_connection
local fail_startup
local begin_health_checks
local continue_startup
local setup_event_listeners

-- Default configuration
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

local shell_env_cache = nil

local function parse_env_output(output)
	local env = {}
	if type(output) ~= "string" or output == "" then
		return env
	end

	for line in output:gmatch("[^\r\n]+") do
		local key, value = line:match("^([%w_]+)=(.*)$")
		if key then
			env[key] = value
		end
	end

	return env
end

local function load_shell_env()
	if M.opts.use_shell_env == false then
		return {}
	end
	if shell_env_cache then
		return shell_env_cache
	end

	local shell = os.getenv("SHELL") or vim.o.shell or "/bin/sh"
	local shell_name = vim.fn.fnamemodify(shell, ":t")
	local flag = (shell_name == "bash" or shell_name == "zsh") and "-lic" or "-lc"
	local ok, output = pcall(vim.fn.system, { shell, flag, "env" })
	if not ok or vim.v.shell_error ~= 0 then
		shell_env_cache = {}
		return shell_env_cache
	end

	shell_env_cache = parse_env_output(output)
	return shell_env_cache
end

local function prepend_path(path, dir)
	if type(dir) ~= "string" or dir == "" then
		return path or ""
	end

	local parts = {}
	local seen = {}
	local function add(part)
		if part and part ~= "" and not seen[part] then
			seen[part] = true
			table.insert(parts, part)
		end
	end

	add(dir)
	for part in tostring(path or ""):gmatch("[^:]+") do
		add(part)
	end

	return table.concat(parts, ":")
end

local function env_value(env, key)
	local value = env[key]
	if value == nil or value == vim.NIL then
		return nil
	end
	return tostring(value)
end

local function promote_toolchain_bins(env)
	local path = env_value(env, "PATH") or os.getenv("PATH") or ""
	local volta_home = env_value(env, "VOLTA_HOME")
	local bun_install = env_value(env, "BUN_INSTALL")
	local nvm_bin = env_value(env, "NVM_BIN")

	if volta_home and volta_home ~= "" then
		path = prepend_path(path, volta_home .. "/bin")
	end
	if bun_install and bun_install ~= "" then
		path = prepend_path(path, bun_install .. "/bin")
	end
	if nvm_bin and nvm_bin ~= "" then
		path = prepend_path(path, nvm_bin)
	end

	env.PATH = path
end

local function build_server_env(auth)
	local env = vim.tbl_extend(
		"force",
		vim.fn.environ(),
		load_shell_env(),
		type(M.opts.env) == "table" and M.opts.env or {},
		{
			OPENCODE_SERVER_USERNAME = auth and auth.username,
			OPENCODE_SERVER_PASSWORD = auth and auth.password,
			OPENCODE_CONFIG_DIR = M.opts.config_dir,
		}
	)

	for key, value in pairs(env) do
		if value == vim.NIL then
			env[key] = nil
		end
	end

	promote_toolchain_bins(env)

	for key, value in pairs(env) do
		if value ~= nil then
			env[key] = tostring(value)
		end
	end

	return env
end

local function resolve_command(command, env)
	command = command or "opencode"
	if command:find("/", 1, true) then
		return command
	end

	local path = env and env.PATH or os.getenv("PATH") or ""
	for dir in path:gmatch("[^:]+") do
		local candidate = dir .. "/" .. command
		if vim.fn.executable(candidate) == 1 then
			return candidate
		end
	end

	local exepath = vim.fn.exepath(command)
	if exepath and exepath ~= "" then
		return exepath
	end

	return command
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

local function remove_pending_callback(callback)
	for index = #pending_callbacks, 1, -1 do
		if pending_callbacks[index] == callback then
			table.remove(pending_callbacks, index)
			return
		end
	end
end

local function process_callbacks(callbacks)
	for _, callback in ipairs(callbacks or {}) do
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
	pending_callbacks = {}

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

-- Parse server URL from output line
-- Verified with CLI 2.0.11: "server listening on http://127.0.0.1:57168"
local function parse_server_url(line)
	if not line then
		return nil
	end

	local url = line:match("listening on (http://[^%s]+)")
	if url then
		local host, port = url:match("^http://%[([^%]]+)%]:(%d+)$")
		if not host then
			host, port = url:match("^http://([^:/]+):(%d+)$")
		end
		-- CLI 2.0.11 on macOS prints its IPv6 localhost address without URL
		-- brackets (http://::1:PORT). Parse only this CLI output convention;
		-- keep the internal URL valid for subsequent consumers.
		if not host then
			local ipv6, native_port = url:match("^http://([%x:]+):(%d+)$")
			if ipv6 and ipv6:find(":", 1, true) then
				host, port = ipv6, native_port
				url = "http://[" .. host .. "]:" .. port
			end
		end
		if host and port then
			return {
				url = url,
				host = host,
				port = tonumber(port),
			}
		end
	end

	return nil
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
	pending_callbacks = {}
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
	if not server_info.port then
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
		callback(true, data.version)
	end)
end

complete_connection = function(attempt, token, startup, success, version, failure_message)
	if not connection_is_current(attempt, token, startup) then
		return false
	end

	attempt.connecting = false
	stop_attempt_timer(attempt, "health_timer")

	if not success then
		pending_callbacks = {}
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
		process_callbacks(callbacks)
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
			host = server_info.host,
			port = server_info.port,
		})

		local http = require("opencode.client.http")
		http.setup({
			host = server_info.host,
			port = server_info.port,
			auth = attempt.auth,
		})

		local sse = require("opencode.client.sse")
		sse.setup({
			host = server_info.host,
			port = server_info.port,
			auth = attempt.auth,
		})

		attempt.configured = true
		if M.opts.debug then
			vim.notify("OpenCode server started on " .. server_info.url, vim.log.levels.DEBUG)
		end
	end

	state.set_connection("connecting")
	return begin_health_checks(attempt, true)
end

-- Start OpenCode server process
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
	local env = build_server_env(auth)

	-- Build opencode serve command
	-- CLI 2.0.11 requires an integer. Zero requests an available OS port.
	local cmd = resolve_command(M.opts.command, env)
	local args = {
		"serve",
		"--hostname",
		host,
		"--port",
		"0",
	}

	attempt_generation = attempt_generation + 1
	local attempt = {
		id = attempt_generation,
		auth = auth,
		phase = "starting",
		startup_done = false,
		connecting = false,
		connection_token = 0,
		disconnected = false,
		exited = false,
		signal_sent = false,
		kill_sent = false,
		stop_waiters = {},
	}
	current_attempt = attempt

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

				local server_info = parse_server_url(data)
				if server_info and not attempt.listening_info then
					attempt.listening_info = server_info
					vim.schedule(function()
						if not is_current_attempt(attempt) then
							return
						end
						continue_startup(attempt)
					end)
				elseif M.opts.debug then
					vim.schedule(function()
						if not is_current_attempt(attempt) or attempt.startup_done then
							return
						end
						vim.notify("OpenCode server: " .. data, vim.log.levels.DEBUG)
					end)
				end
			end,
			on_stderr = function(_, data)
				if not is_current_attempt(attempt) or attempt.startup_done or not data then
					return
				end
				vim.schedule(function()
					if not is_current_attempt(attempt) or attempt.startup_done then
						return
					end
					if M.opts.debug then
						vim.notify("OpenCode server stderr: " .. data, vim.log.levels.DEBUG)
					end
				end)
			end,
			on_exit = function(_, code, signal)
				if not is_current_attempt(attempt) then
					return
				end
				attempt.exited = true
				attempt.exit_code = code
				attempt.exit_signal = signal

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

	if not started then
		fail_startup(attempt, "Failed to start OpenCode server: " .. error_detail(start_err))
		return false
	end

	return is_current_attempt(attempt) and (attempt.phase == "starting" or attempt.phase == "ready")
end

-- Setup SSE event listeners
setup_event_listeners = function(client)
	if listener_clients[client] then
		return
	end
	-- Connection events (SSE-level)
	client.on_event("connected", function()
		-- SSE connected, server.connected event will follow
	end)

	client.on_event("disconnected", function(reason)
		if
			current_attempt
			and (current_attempt.phase == "stopping" or current_attempt.phase == "stop_error")
		then
			return
		end
		state.set_connection("idle")
		vim.notify("OpenCode disconnected: " .. (reason or "unknown"), vim.log.levels.WARN)
	end)

	-- Server connection event (from server, not SSE level)
	client.on_event("server.connected", function()
		if current_attempt and (current_attempt.phase == "stopping" or current_attempt.phase == "stop_error") then
			return
		end
		state.set_connection("connected")
	end)

	-- Message counts are updated by events.handlers.message after sync de-dupes updates.
	client.on_event("message.updated", function(data)
		return data
	end)

	-- Session status events are mirrored by events.handlers.message.
	client.on_event("session.status", function(data)
		return data
	end)

	-- File edit events are handled by events.lua edit handler
	-- which integrates with changes module and diff viewer
listener_clients[client] = true
end

-- Connect to running server
connect_to_server = function(attempt, token, startup, version)
	if not connection_is_current(attempt, token, startup) then
		return false
	end

	local client = require("opencode.client")
	setup_event_listeners(client)

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

	return complete_connection(attempt, token, startup, true, version)
end

-- Ensure server is connected (lazy initialization entry point)
---@param callback function Called when connection is ready
function M.ensure_connected(callback)
	local connection = state.get_connection()

	if connection == "connected" then
		-- Already connected, execute immediately
		vim.schedule(callback)
		return true
	end

	if connection == "idle" or connection == "error" then
		-- Need to start/connect
		table.insert(pending_callbacks, callback)
		if not M.start() then
			remove_pending_callback(callback)
		end
		return false
	end

	if connection == "starting" or connection == "connecting" then
		-- Already in progress, queue callback
		table.insert(pending_callbacks, callback)
		return false
	end

	return false
end

-- Start server and connect
function M.start()
	local connection = state.get_connection()
	if connection ~= "idle" and connection ~= "error" then
		return false -- Already starting/connecting/connected
	end

	if current_attempt then
		local attempt = current_attempt
		if attempt.phase == "ready" then
			attempt.disconnected = false
			state.set_connection("connecting")
			return begin_health_checks(attempt, false)
		end
		if attempt.phase == "starting" and not attempt.startup_done then
			attempt.disconnected = false
			state.set_connection("starting")
			arm_startup_timeout(attempt)
			if attempt.listening_info then
				return continue_startup(attempt)
			end
			return true
		end
		return false
	end

	-- Explicit endpoints are external even when auto_start is enabled. An auth
	-- or version failure must never replace them with a new managed server.
	if M.opts.port then
		attempt_generation = attempt_generation + 1
		local attempt = {
			id = attempt_generation, phase = "ready", startup_done = true,
			connecting = false, connection_token = 0, disconnected = false,
			external = true, stop_waiters = {},
		}
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

		attempt_generation = attempt_generation + 1
		attempt = {
			id = attempt_generation,
			phase = "ready",
			startup_done = true,
			connecting = false,
			connection_token = 0,
			disconnected = false,
			exited = false,
			signal_sent = false,
			kill_sent = false,
			stop_waiters = {},
			pid = pid,
			untracked = true,
		}
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
	pending_callbacks = {}
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

-- Restart server
function M.restart()
	if state.is_server_managed() then
		M.stop(function()
			M.start()
		end)
	else
		-- For external servers, just reconnect
		local client = require("opencode.client")
		client.disconnect_events()
		state.set_connection("idle")

		vim.defer_fn(function()
			M.start()
		end, 500)
	end
end

-- Disconnect from server (keep server running)
function M.disconnect()
	local client = require("opencode.client")
	local cleanup = require("opencode.cleanup")
	local attempt = current_attempt

	if attempt then
		attempt.connection_token = attempt.connection_token + 1
		attempt.connecting = false
		attempt.disconnected = true
		stop_attempt_timer(attempt, "health_timer")
		if not attempt.startup_done then
			stop_attempt_timer(attempt, "timeout_timer")
		end
	end

	client.disconnect_events()
	cleanup.clear_transient({
		clear_chat = true,
		reset_state = false,
	})
	-- Clear any pending callbacks
	pending_callbacks = {}
	if attempt and attempt.phase == "stop_error" then
		state.set_connection("error")
	else
		state.set_connection("idle")
	end

	vim.notify("OpenCode disconnected", vim.log.levels.INFO)
end

-- Configure lifecycle options
---@param opts table
function M.setup(opts)
	opts = opts or {}
	M.opts = vim.tbl_deep_extend("force", M.opts, opts)
	shell_env_cache = nil

	-- Store auth in opts for spawn_server
	if opts.auth then
		M.opts.auth = opts.auth
	end

	-- Setup auto-shutdown on vim exit if configured
	if M.opts.shutdown_on_exit then
		vim.api.nvim_create_autocmd("VimLeavePre", {
			group = vim.api.nvim_create_augroup("OpenCodeLifecycle", { clear = true }),
			callback = function()
				if state.is_server_managed() then
					M.stop()
				end
			end,
		})
	end
end

-- Get lifecycle status
function M.status()
	return {
		connection = state.get_connection(),
		server_pid = state.get_server_pid(),
		server_managed = state.is_server_managed(),
		pending_callbacks = #pending_callbacks,
	}
end

return M
