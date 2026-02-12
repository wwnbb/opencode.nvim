-- opencode.nvim - Lifecycle management module
-- Handles lazy initialization and server lifecycle

local M = {}

local Job = require("plenary.job")
local config = require("opencode.config")
local state = require("opencode.state")

-- Pending callbacks queue for lazy initialization
local pending_callbacks = {}

-- Lifecycle timers
local check_timer = nil

-- Forward declarations for functions that need to be called before their definition
local connect_to_server
local check_existing_server

-- Default configuration
M.opts = {
	auto_start = true,
	startup_timeout = 10000,
	health_check_interval = 1000,
	shutdown_on_exit = false,
	reuse_running = true,
	config_dir = nil,
}

-- Check if OpenCode server is already running at configured host:port
check_existing_server = function(callback)
	local http = require("opencode.client.http")

	http.health(function(err, data)
		if err or not data then
			callback(false)
			return
		end

		if data.healthy then
			callback(true, data.version)
		else
			callback(false)
		end
	end)
end

-- Parse server URL from output line
-- Expected format: "opencode server listening on http://127.0.0.1:57168"
local function parse_server_url(line)
	if not line then
		return nil
	end

	local url = line:match("listening on (http://[%w%.%-]+:%d+)")
	if url then
		local host, port = url:match("http://([%w%.%-]+):(%d+)")
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

-- Start OpenCode server process
local function spawn_server(callback)
	local host = state.get_server_info().host

	-- Build opencode serve command
	-- Use --port 0 to let opencode pick an available port
	local cmd = "opencode"
	local args = {
		"serve",
		"--hostname",
		host,
		"--port",
		"0",
	}

	state.set_connection("starting")
	state.set_server_managed(true)

	local server_ready = false
	local server_job

	server_job = Job:new({
		command = cmd,
		args = args,
		env = vim.tbl_extend("force", vim.fn.environ(), {
			-- Pass through any auth env vars if configured
			OPENCODE_SERVER_USERNAME = M.opts.auth and M.opts.auth.username,
			OPENCODE_SERVER_PASSWORD = M.opts.auth and M.opts.auth.password,
			-- Pass through config directory if configured
			OPENCODE_CONFIG_DIR = M.opts.config_dir,
		}),
		on_stdout = function(_, data)
			if data then
				-- Try to parse server URL from output
				local server_info = parse_server_url(data)
				if server_info and not server_ready then
					server_ready = true

					vim.schedule(function()
						-- Update state and HTTP client with actual port
						state.set_server_info({
							host = server_info.host,
							port = server_info.port,
						})

						-- Update HTTP client configuration
						local http = require("opencode.client.http")
						http.setup({
							host = server_info.host,
							port = server_info.port,
						})

						-- Update SSE client configuration
						local sse = require("opencode.client.sse")
						sse.setup({
							host = server_info.host,
							port = server_info.port,
						})

						if M.opts.debug then
							vim.notify("OpenCode server started on " .. server_info.url, vim.log.levels.DEBUG)
						end

						-- Now connect to the server
						state.set_connection("connecting")
						check_existing_server(function(running, version)
							if running then
								connect_to_server(version)
							else
								-- Server reported listening but health check failed, retry
								vim.defer_fn(function()
									check_existing_server(function(retry_running, retry_version)
										if retry_running then
											connect_to_server(retry_version)
										else
											state.set_connection("error")
											vim.notify("OpenCode server health check failed", vim.log.levels.ERROR)
											callback({ error = "Health check failed" })
										end
									end)
								end, 500)
							end
						end)
					end)
				elseif M.opts.debug then
					vim.schedule(function()
						vim.notify("OpenCode server: " .. data, vim.log.levels.DEBUG)
					end)
				end
			end
		end,
		on_stderr = function(_, data)
			-- Server errors/warnings (including "Warning: OPENCODE_SERVER_PASSWORD is not set")
			if data then
				vim.schedule(function()
					if M.opts.debug then
						vim.notify("OpenCode server stderr: " .. data, vim.log.levels.DEBUG)
					end
				end)
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if state.is_server_managed() then
					state.set_server_pid(nil)
					state.set_connection("idle")

					if code ~= 0 and code ~= 143 then -- 143 is SIGTERM
						vim.notify("OpenCode server exited with code: " .. code, vim.log.levels.WARN)
					end
				end
			end)
		end,
	})

	-- Start the server
	server_job:start()

	-- Get PID (may take a moment)
	vim.defer_fn(function()
		local pid = server_job.pid
		if pid then
			state.set_server_pid(pid)
		end
	end, 100)

	-- Timeout handler - if we don't get the "listening on" message in time
	local start_time = vim.uv.now()
	local timeout = M.opts.startup_timeout

	local function check_timeout()
		if server_ready then
			return -- Already connected
		end

		local elapsed = vim.uv.now() - start_time
		if elapsed >= timeout then
			state.set_connection("error")
			vim.schedule(function()
				vim.notify("OpenCode server startup timed out", vim.log.levels.ERROR)
				callback({ error = "Startup timeout" })
			end)
			return
		end

		-- Check again
		check_timer = vim.defer_fn(check_timeout, M.opts.health_check_interval)
	end

	-- Start timeout check
	check_timer = vim.defer_fn(check_timeout, M.opts.health_check_interval)
end

-- Process queued callbacks after connection
local function process_pending_callbacks()
	while #pending_callbacks > 0 do
		local cb = table.remove(pending_callbacks, 1)
		local ok, err = pcall(cb)
		if not ok then
			vim.notify("Pending callback error: " .. tostring(err), vim.log.levels.ERROR)
		end
	end
end

-- Setup SSE event listeners
local function setup_event_listeners(client)
	-- Connection events (SSE-level)
	client.on_event("connected", function()
		-- SSE connected, server.connected event will follow
	end)

	client.on_event("disconnected", function(reason)
		state.set_connection("idle")
		vim.notify("OpenCode disconnected: " .. (reason or "unknown"), vim.log.levels.WARN)
	end)

	-- Server connection event (from server, not SSE level)
	client.on_event("server.connected", function()
		state.set_connection("connected")
	end)

	-- Message events are handled by events.lua setup_chat_handlers()
	-- We only track message count here
	client.on_event("message.updated", function(data)
		if data and data.info then
			vim.schedule(function()
				state.increment_message_count()
			end)
		end
	end)

	-- Session status events from server
	client.on_event("session.status", function(data)
		if data and data.status then
			vim.schedule(function()
				local current_session = state.get_session()
				if data.sessionID == current_session.id then
					if data.status == "idle" then
						state.set_status("idle")
					elseif data.status == "busy" then
						state.set_status("streaming")
					end
				end
			end)
		end
	end)

	-- File edit events are handled by events.lua edit handler
	-- which integrates with changes module and diff viewer
end

-- Connect to running server
connect_to_server = function(version)
	local client = require("opencode.client")

	state.set_connection("connected")
	state.set_server_info({ version = version })

	-- Start event stream
	client.connect_events()

	-- Setup event listeners
	setup_event_listeners(client)

	-- Process any pending callbacks
	vim.schedule(process_pending_callbacks)

	vim.notify("OpenCode connected (server v" .. (version or "unknown") .. ")", vim.log.levels.INFO)
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
		M.start()
		return false
	end

	if connection == "starting" or connection == "connecting" then
		-- Already in progress, queue callback
		table.insert(pending_callbacks, callback)
		return false
	end

	return false
end

-- Start server and connect (or connect to existing)
function M.start()
	if not M.opts.auto_start then
		vim.notify("OpenCode auto-start is disabled", vim.log.levels.WARN)
		return false
	end

	if state.get_connection() ~= "idle" and state.get_connection() ~= "error" then
		return false -- Already starting/connecting/connected
	end

	if M.opts.reuse_running then
		-- First check if there's already a server running
		state.set_connection("starting")

		check_existing_server(function(running, version)
			if running then
				-- Connect to existing server
				state.set_server_managed(false)
				vim.schedule(function()
					connect_to_server(version)
				end)
			else
				-- Start our own server
				vim.schedule(function()
					spawn_server(function(err)
						if err then
							state.set_connection("error")
							vim.notify("Failed to start OpenCode server: " .. err.error, vim.log.levels.ERROR)
						end
					end)
				end)
			end
		end)
	else
		-- Always start our own server
		spawn_server(function(err)
			if err then
				state.set_connection("error")
				vim.notify("Failed to start OpenCode server: " .. err.error, vim.log.levels.ERROR)
			end
		end)
	end

	return true
end

-- Stop server (only if we started it)
function M.stop()
	if not state.is_server_managed() then
		vim.notify("Cannot stop external OpenCode server", vim.log.levels.WARN)
		return false
	end

	local pid = state.get_server_pid()
	if not pid then
		vim.notify("No OpenCode server PID found", vim.log.levels.WARN)
		return false
	end

	-- Kill the server process
	local kill_job = Job:new({
		command = "kill",
		args = { tostring(pid) },
		on_exit = function(_, code)
			vim.schedule(function()
				if code == 0 then
					state.set_server_pid(nil)
					state.set_server_managed(false)
					state.set_connection("idle")
					vim.notify("OpenCode server stopped", vim.log.levels.INFO)
				else
					vim.notify("Failed to stop OpenCode server (exit code: " .. code .. ")", vim.log.levels.ERROR)
				end
			end)
		end,
	})

	kill_job:start()
	return true
end

-- Restart server
function M.restart()
	if state.is_server_managed() then
		M.stop()
		-- Wait a moment then start again
		vim.defer_fn(function()
			M.start()
		end, 1000)
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

	client.disconnect_events()
	state.set_connection("idle")

	-- Clear any pending callbacks
	pending_callbacks = {}

	-- Stop check timer if running
	if check_timer then
		check_timer:stop()
		check_timer = nil
	end

	vim.notify("OpenCode disconnected", vim.log.levels.INFO)
end

-- Configure lifecycle options
---@param opts table
function M.setup(opts)
	opts = opts or {}
	M.opts = vim.tbl_deep_extend("force", M.opts, opts)

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
