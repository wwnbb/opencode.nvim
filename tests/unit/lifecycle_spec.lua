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
		job.opts.on_stdout(nil, "opencode server listening on http://127.0.0.1:" .. tostring(port), job)
		flush_scheduled()
	end

	local function respond_health(index, healthy, version)
		local callback = health_callbacks[index]
		assert(callback, "health callback " .. tostring(index) .. " must exist")
		callback(nil, {
			healthy = healthy,
			version = version or "1.0.0",
		})
	end

	local function complete_start(callback, port)
		lifecycle.ensure_connected(callback or function() end)
		local job = jobs[#jobs]
		emit_listening(job, port or (4000 + #jobs))
		respond_health(#health_callbacks, true)
		flush_scheduled()
		return job
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
		local timer_count = #timers

		lifecycle.restart()

		assert_eq(first_job.signal_count, 1, "restart signal dispatch")
		assert_eq(first_job.last_signal, 15, "restart signal")
		assert_eq(#jobs, 1, "restart before exit")
		assert_eq(#timers, timer_count, "restart must not use a fixed delay")

		flush_scheduled()
		assert_eq(#jobs, 1, "restart remains pending")

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
			"connected",
			"disconnected",
			"server.connected",
			"message.updated",
			"session.status",
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
		assert_eq(#jobs, 1, "stop kill job count")
		assert_eq(lifecycle.stop(), true, "repeated stop")
		assert_eq(job.signal_count, 1, "repeated stop signal")
		assert_eq(state_data.server.managed, true, "managed before exit")

		job.opts.on_exit(job, 0, 15)
		flush_scheduled()
		assert_eq(state_data.server.managed, false, "managed after exit")
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
