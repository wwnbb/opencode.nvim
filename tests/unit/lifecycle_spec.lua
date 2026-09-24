-- Unit checks for managed lifecycle attempt ownership.
-- Run with: ./tests/run.sh tests/unit/lifecycle_spec.lua

describe("opencode lifecycle", function()
	local module_names = {
		"opencode.lifecycle",
		"opencode.state",
		"opencode.client",
		"opencode.client.http",
		"opencode.client.sse",
		"opencode.cleanup",
		"plenary.job",
	}

	local saved_modules
	local original_schedule
	local original_defer_fn
	local original_notify
	local lifecycle
	local state_data
	local jobs
	local timers
	local scheduled
	local health_callbacks
	local listeners
	local client

	local function assert_eq(actual, expected, message)
		if actual ~= expected then
			error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
		end
	end

	local function flush_scheduled()
		while #scheduled > 0 do
			table.remove(scheduled, 1)()
		end
	end

	local function fire_timer(timer)
		assert(timer and timer.active, "timer must be active")
		timer.active = false
		timer.fn()
	end

	local function emit_listening(job, port)
		job.opts.on_stdout(nil, "server listening on http://127.0.0.1:" .. tostring(port), job)
		flush_scheduled()
	end

	local function respond_health(index, healthy, version)
		local callback = health_callbacks[index]
		assert(callback, "health callback " .. tostring(index) .. " must exist")
		if not healthy then callback({ message = "Not ready" }); return end
		callback(nil, { version = version or "2.0.11", pid = 1000, urls = {}, paths = { tmp = "/tmp" } })
	end

	local function complete_start(callback, port)
		lifecycle.ensure_connected(callback or function() end)
		local job = jobs[#jobs]
		emit_listening(job, port or (4000 + #jobs))
		respond_health(#health_callbacks, true)
		flush_scheduled()
		return job
	end

	local function last_active_timer()
		for index = #timers, 1, -1 do
			if timers[index].active then
				return timers[index]
			end
		end
		return nil
	end

	before_each(function()
		saved_modules = {}
		for _, name in ipairs(module_names) do
			saved_modules[name] = package.loaded[name]
		end

		original_schedule = vim.schedule
		original_defer_fn = vim.defer_fn
		original_notify = vim.notify

		jobs = {}
		timers = {}
		scheduled = {}
		health_callbacks = {}
		listeners = {}

		vim.schedule = function(callback)
			table.insert(scheduled, callback)
		end
		vim.defer_fn = function(callback, timeout)
			local timer = {
				fn = callback,
				timeout = timeout,
				active = true,
			}
			function timer:stop()
				self.active = false
			end
			function timer:close()
				self.active = false
			end
			table.insert(timers, timer)
			return timer
		end
		vim.notify = function() end

		state_data = {
			connection = "idle",
			server = {
				host = "localhost",
				port = nil,
				version = nil,
				pid = nil,
				managed = false,
			},
		}
		package.loaded["opencode.state"] = {
			get_connection = function()
				return state_data.connection
			end,
			set_connection = function(connection)
				state_data.connection = connection
			end,
			get_server_info = function()
				return vim.deepcopy(state_data.server)
			end,
			clear_server_endpoint = function()
				state_data.server.port = nil
				state_data.server.version = nil
			end,
			set_server_info = function(info)
				for key, value in pairs(info or {}) do
					if value ~= nil then
						state_data.server[key] = value
					end
				end
			end,
			get_server_pid = function()
				return state_data.server.pid
			end,
			set_server_pid = function(pid)
				state_data.server.pid = pid
			end,
			is_server_managed = function()
				return state_data.server.managed
			end,
			set_server_managed = function(managed)
				state_data.server.managed = managed
			end,
		}

		local Job = {}
		function Job:new(opts)
			local job = {
				opts = opts,
				planned_pid = 900000 + #jobs + 1,
				signal_count = 0,
				kill_fails = false,
			}
			function job:start()
				self.pid = self.planned_pid
				self.handle = {
					kill = function(_, signal)
						self.signal_count = self.signal_count + 1
						self.last_signal = signal
						if self.kill_fails then
							return nil, "EPERM"
						end
						return 0
					end,
				}
			end
			table.insert(jobs, job)
			return job
		end
		package.loaded["plenary.job"] = Job

		package.loaded["opencode.client.http"] = {
			setup = function(opts)
				state_data.http_setup = opts
			end,
			health = function(callback)
				table.insert(health_callbacks, callback)
			end,
		}
		package.loaded["opencode.client.sse"] = {
			setup = function(opts)
				state_data.sse_setup = opts
			end,
		}

		client = {
			connect_calls = 0,
			connect_result = true,
			connect_error = nil,
			disconnect_calls = 0,
		}
		function client.connect_events()
			client.connect_calls = client.connect_calls + 1
			if client.connect_result == false then
				return false, client.connect_error
			end
			return true
		end
		function client.disconnect_events()
			client.disconnect_calls = client.disconnect_calls + 1
		end
		function client.on_event(event_type, callback)
			listeners[event_type] = listeners[event_type] or {}
			table.insert(listeners[event_type], callback)
		end
		package.loaded["opencode.client"] = client
		package.loaded["opencode.cleanup"] = {
			clear_transient = function()
				state_data.cleanup_calls = (state_data.cleanup_calls or 0) + 1
			end,
		}
		package.loaded["opencode.lifecycle"] = nil

		lifecycle = require("opencode.lifecycle")
		lifecycle.setup({
			command = "/fake/opencode",
			auto_start = true,
			shutdown_on_exit = false,
			startup_timeout = 100,
			health_check_interval = 10,
			use_shell_env = false,
		})
	end)

	after_each(function()
		vim.schedule = original_schedule
		vim.defer_fn = original_defer_fn
		vim.notify = original_notify
		for _, name in ipairs(module_names) do
			package.loaded[name] = saved_modules[name]
		end
	end)

	it("recognizes the actual unbracketed IPv6 listening line from CLI 2.0.11", function()
		local connected = false
		lifecycle.ensure_connected(function() connected = true end)
		local job = jobs[1]
		job.opts.on_stdout(nil, "server listening on http://::1:4096", job)
		flush_scheduled()
		assert_eq(state_data.server.host, "::1", "IPv6 host")
		assert_eq(state_data.server.port, 4096, "IPv6 port")
		respond_health(1, true); flush_scheduled()
		assert_eq(connected, true, "IPv6 readiness")
	end)

	it("shares one ephemeral credential between the owned process, HTTP and SSE", function()
		lifecycle.ensure_connected(function() end)
		local job = jobs[1]
		local password = job.opts.env.OPENCODE_SERVER_PASSWORD
		assert_eq(type(password), "string", "owned credential type")
		assert_eq(#password, 64, "owned credential length")
		emit_listening(job, 4096)
		assert_eq(state_data.http_setup.auth.password, password, "HTTP credential")
		assert_eq(state_data.sse_setup.auth.password, password, "SSE credential")
		assert_eq(job.opts.enable_recording, false, "no raw startup-output retention")
		assert_eq(lifecycle.opts.auth, nil, "generated secret does not become user configuration")
	end)

	it("drops queued actions when event connection fails", function()
		local old_runs = 0
		local retry_runs = 0
		client.connect_result = false
		client.connect_error = { message = "unauthorized" }

		lifecycle.ensure_connected(function()
			old_runs = old_runs + 1
		end)
		local first_job = jobs[1]
		emit_listening(first_job, 4101)
		respond_health(1, true)
		flush_scheduled()

		assert_eq(old_runs, 0, "failed action")
		assert_eq(lifecycle.status().pending_callbacks, 0, "failed queue")
		assert_eq(state_data.connection, "error", "failed state")
		assert_eq(state_data.server.managed, true, "failure ownership")
		assert_eq(first_job.signal_count, 1, "failure signal")

		first_job.opts.on_exit(first_job, 0, 15)
		flush_scheduled()
		client.connect_result = true

		lifecycle.ensure_connected(function()
			retry_runs = retry_runs + 1
		end)
		local second_job = jobs[2]
		emit_listening(second_job, 4102)
		respond_health(2, true)
		flush_scheduled()

		assert_eq(old_runs, 0, "old action after retry")
		assert_eq(retry_runs, 1, "retry action")
	end)

	it("retains ownership when synchronous signaling fails", function()
		local stranded_runs = 0
		lifecycle.ensure_connected(function()
			stranded_runs = stranded_runs + 1
		end)
		local job = jobs[1]
		job.kill_fails = true

		fire_timer(timers[1])

		assert_eq(job.signal_count, 1, "failed signal count")
		assert_eq(state_data.connection, "error", "signal failure state")
		assert_eq(state_data.server.managed, true, "signal failure managed state")
		assert_eq(state_data.server.pid, job.pid, "signal failure PID")
		assert_eq(lifecycle.status().pending_callbacks, 0, "signal failure queue")
		assert_eq(lifecycle.start(), false, "replacement start while owned")
		assert_eq(#jobs, 1, "replacement job count")

		lifecycle.ensure_connected(function()
			stranded_runs = stranded_runs + 1
		end)
		assert_eq(lifecycle.status().pending_callbacks, 0, "refused retry queue")
		assert_eq(stranded_runs, 0, "refused retry action")

		job.kill_fails = false
		assert_eq(lifecycle.stop(), true, "stop retry result")
		assert_eq(job.signal_count, 2, "stop retry signal")
		assert_eq(state_data.server.managed, true, "ownership before exit")

		job.opts.on_exit(job, 0, 15)
		flush_scheduled()
		assert_eq(state_data.server.managed, false, "ownership after exit")
		assert_eq(state_data.server.pid, nil, "PID after exit")
	end)

	it("waits for delayed process exit before restarting", function()
		local first_job = complete_start(nil, 4201)

		lifecycle.restart()

		assert_eq(first_job.signal_count, 1, "restart signal dispatch")
		assert_eq(first_job.last_signal, 15, "restart signal")
		assert_eq(#jobs, 1, "restart before exit")
		assert_eq(client.disconnect_calls, 1, "restart disconnects SSE before teardown")

		flush_scheduled()
		assert_eq(#jobs, 1, "restart remains pending until observed exit")

		first_job.opts.on_exit(first_job, 0, 15)
		flush_scheduled()
		assert_eq(#jobs, 2, "restart after observed exit")

		local second_job = jobs[2]
		emit_listening(second_job, 4202)
		respond_health(2, true)
		flush_scheduled()
		assert_eq(state_data.connection, "connected", "restarted connection")
	end)

	it("ignores late callbacks from a timed-out attempt", function()
		local old_runs = 0
		local retry_runs = 0

		lifecycle.ensure_connected(function()
			old_runs = old_runs + 1
		end)
		local first_job = jobs[1]
		local timeout = timers[1]
		emit_listening(first_job, 4301)
		fire_timer(timeout)

		first_job.opts.on_stdout(nil, "opencode server listening on http://127.0.0.1:4999", first_job)
		health_callbacks[1](nil, { healthy = true, version = "stale" })
		flush_scheduled()

		assert_eq(client.connect_calls, 0, "late connect count")
		assert_eq(state_data.server.port, 4301, "late stdout port")
		assert_eq(old_runs, 0, "timed-out action")

		first_job.opts.on_exit(first_job, 0, 15)
		flush_scheduled()
		lifecycle.ensure_connected(function()
			retry_runs = retry_runs + 1
		end)
		local second_job = jobs[2]

		first_job.opts.on_exit(first_job, 1, 0)
		flush_scheduled()
		assert_eq(state_data.server.pid, second_job.pid, "stale exit PID")

		emit_listening(second_job, 4302)
		respond_health(2, true)
		flush_scheduled()
		assert_eq(old_runs, 0, "old action after timeout retry")
		assert_eq(retry_runs, 1, "timeout retry action")
	end)

	it("cannot connect after health checks are exhausted", function()
		local runs = 0
		lifecycle.ensure_connected(function()
			runs = runs + 1
		end)
		local job = jobs[1]
		emit_listening(job, 4401)

		respond_health(1, false)
		fire_timer(timers[#timers])
		respond_health(2, false)

		assert_eq(runs, 0, "health failure action")
		assert_eq(state_data.connection, "error", "health failure state")
		assert_eq(job.signal_count, 1, "health failure signal")
		assert_eq(lifecycle.status().pending_callbacks, 0, "health failure queue")

		health_callbacks[2](nil, { healthy = true, version = "late" })
		flush_scheduled()
		assert_eq(client.connect_calls, 0, "late health connect")
	end)

	it("reconnects the owned process without duplicate listeners", function()
		local failed_runs = 0
		local retry_runs = 0
		local job = complete_start(nil, 4501)
		local event_types = {
			"disconnected",
			"server.connected",
		}

		for _, event_type in ipairs(event_types) do
			assert_eq(#(listeners[event_type] or {}), 1, event_type .. " initial listeners")
		end

		lifecycle.disconnect()
		client.connect_result = false
		client.connect_error = "auth failed"
		lifecycle.ensure_connected(function()
			failed_runs = failed_runs + 1
		end)
		respond_health(2, true)
		flush_scheduled()

		assert_eq(#jobs, 1, "failed reconnect job count")
		assert_eq(job.signal_count, 0, "failed reconnect process signal")
		assert_eq(failed_runs, 0, "failed reconnect action")
		assert_eq(lifecycle.status().pending_callbacks, 0, "failed reconnect queue")

		client.connect_result = true
		client.connect_error = nil
		lifecycle.ensure_connected(function()
			retry_runs = retry_runs + 1
		end)
		respond_health(3, true)
		flush_scheduled()

		assert_eq(#jobs, 1, "successful reconnect job count")
		assert_eq(retry_runs, 1, "successful reconnect action")
		for _, event_type in ipairs(event_types) do
			assert_eq(#(listeners[event_type] or {}), 1, event_type .. " reconnect listeners")
		end
	end)

	it("treats process exit before readiness as terminal failure", function()
		local runs = 0
		lifecycle.ensure_connected(function()
			runs = runs + 1
		end)
		local job = jobs[1]

		job.opts.on_exit(job, 1, 0)
		flush_scheduled()

		assert_eq(runs, 0, "exited action")
		assert_eq(lifecycle.status().pending_callbacks, 0, "exited queue")
		assert_eq(state_data.connection, "error", "exited state")
		assert_eq(state_data.server.managed, false, "exited ownership")
	end)

	it("dispatches stop synchronously and idempotently", function()
		local job = complete_start(nil, 4601)

		assert_eq(lifecycle.stop(), true, "first stop")
		assert_eq(job.signal_count, 1, "first stop signal")
		assert_eq(job.last_signal, 15, "first stop SIGTERM")
		assert_eq(client.disconnect_calls, 1, "stop disconnects SSE")
		assert_eq(#jobs, 1, "stop kill job count")
		assert_eq(lifecycle.stop(), true, "repeated stop")
		assert_eq(job.signal_count, 1, "repeated stop signal")
		assert_eq(client.disconnect_calls, 1, "repeated stop does not disconnect twice")
		assert_eq(state_data.server.managed, true, "managed before exit")

		job.opts.on_exit(job, 0, 15)
		flush_scheduled()
		assert_eq(state_data.server.managed, false, "managed after exit")
	end)

	it("escalates a hung stop to SIGKILL then releases ownership", function()
		local job = complete_start(nil, 4701)

		assert_eq(lifecycle.stop(), true, "hung stop")
		assert_eq(job.last_signal, 15, "hung stop SIGTERM")
		assert_eq(lifecycle.start(), false, "start blocked while stopping")

		local term_timer = last_active_timer()
		assert(term_timer, "stop timeout must be armed")
		fire_timer(term_timer)

		assert_eq(job.signal_count, 2, "SIGKILL dispatch")
		assert_eq(job.last_signal, 9, "hung stop SIGKILL")
		assert_eq(lifecycle.start(), false, "start blocked after SIGKILL")
		assert_eq(state_data.server.managed, true, "owned after SIGKILL")

		local kill_timer = last_active_timer()
		assert(kill_timer, "SIGKILL wait must be armed")
		fire_timer(kill_timer)
		flush_scheduled()

		assert_eq(state_data.server.managed, false, "released after SIGKILL timeout")
		assert_eq(state_data.connection, "error", "error after SIGKILL timeout")
		assert_eq(lifecycle.start(), true, "start after hang release")
		assert_eq(#jobs, 2, "replacement job after hang release")
	end)

	it("uses explicit port zero for a private server", function()
		local job = complete_start()
		assert.same({ "serve", "--hostname", "localhost", "--port", "0" }, job.opts.args)
	end)

	it("connects an external endpoint with auto-start disabled and never stops it", function()
		lifecycle.setup({ auto_start = false, port = 4096 })
		state_data.server.port = 4096
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		assert.equals(0, #jobs)
		respond_health(1, true)
		flush_scheduled()
		assert.equals(1, runs)
		assert.is_false(state_data.server.managed)
		assert.is_nil(state_data.server.pid)
		assert.is_false(lifecycle.stop())
		lifecycle.disconnect()
		assert.equals(4096, state_data.server.port)
	end)

	it("does not spawn a private server after an external auth failure", function()
		lifecycle.setup({ port = 4096 })
		state_data.server.port = 4096
		lifecycle.ensure_connected(function() error("unauthorized") end)
		health_callbacks[1]({ status = 401, message = "Unauthorized" })
		flush_scheduled()
		assert.equals("error", state_data.connection)
		assert.equals(0, #jobs)
		assert.equals(0, lifecycle.status().pending_callbacks)
	end)

	it("does not retain callbacks when auto-start is disabled", function()
		local runs = 0
		lifecycle.setup({ auto_start = false })

		lifecycle.ensure_connected(function()
			runs = runs + 1
		end)

		assert_eq(runs, 0, "disabled action")
		assert_eq(#jobs, 0, "disabled jobs")
		assert_eq(lifecycle.status().pending_callbacks, 0, "disabled queue")
	end)
end)
