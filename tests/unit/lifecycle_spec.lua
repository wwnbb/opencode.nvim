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
	local temporary_files

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
		temporary_files = {}
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
			auto_ready = true,
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
			if client.auto_ready then for _, callback in ipairs(listeners["server.connected"] or {}) do callback() end end
			return true
		end
		function client.disconnect_events()
			client.disconnect_calls = client.disconnect_calls + 1
		end
		function client.configure_endpoint(opts)
			state_data.http_setup = vim.tbl_extend("force", state_data.http_setup or {}, opts)
			state_data.sse_setup = vim.tbl_extend("force", state_data.sse_setup or {}, opts)
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
		for _, file in ipairs(temporary_files) do vim.fn.delete(file, "rf") end
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
		assert.equals("::1", state_data.server.host, "IPv6 host")
		assert.equals(4096, state_data.server.port, "IPv6 port")
		respond_health(1, true); flush_scheduled()
		assert.equals(true, connected, "IPv6 readiness")
	end)

	it("removes automatic shutdown when reconfigured off", function()
		lifecycle.setup({ shutdown_on_exit = true })
		assert.equals(1, #vim.api.nvim_get_autocmds({ group = "OpenCodeLifecycle", event = "VimLeavePre" }))
		lifecycle.setup({ shutdown_on_exit = false })
		assert.equals(0, #vim.api.nvim_get_autocmds({ group = "OpenCodeLifecycle", event = "VimLeavePre" }))
	end)

	it("replaces environment maps and snapshots supplied credentials", function()
		lifecycle.setup({ env = { OPENCODE_NVIM_TEST_REMOVED_ENV = "old" } })
		local opts = { env = { OPENCODE_NVIM_TEST_KEPT_ENV = "new" }, auth = { username = "alice", password = "test-secret" } }
		lifecycle.setup(opts)
		opts.env.OPENCODE_NVIM_TEST_KEPT_ENV = "changed"
		opts.auth.password = "changed"
		local job = complete_start()
		assert.is_nil(job.opts.env.OPENCODE_NVIM_TEST_REMOVED_ENV)
		assert.equals("new", job.opts.env.OPENCODE_NVIM_TEST_KEPT_ENV)
		assert.equals("test-secret", job.opts.env.OPENCODE_SERVER_PASSWORD)
	end)

	local function managed_file(info)
		local file = vim.fn.tempname(); temporary_files[#temporary_files + 1] = file
		assert.is_true(require("opencode.util.json_file").write(file, info))
		lifecycle.setup({ managed = true, service_file = file, auto_start = false })
		return file
	end
	local function managing_host()
		local directory = vim.fn.tempname(); temporary_files[#temporary_files + 1] = directory
		lifecycle.setup({ managed = true, service_file = false, auto_start = false, env = { XDG_STATE_HOME = directory } })
		local file = directory .. "/opencode/service.json"
		assert.is_true(require("opencode.util.json_file").write(file, { pid = 1000, url = "http://localhost:4096", version = "2.0.11" }))
		lifecycle.start(); respond_health(1, true); respond_health(2, true); flush_scheduled()
		assert.is_true(lifecycle.managed_status().can_manage)
		return file
	end
	it("keeps chat connected when the native updater is unavailable", function()
		managing_host()
		local failure, callbacks = nil, 0
		lifecycle.manage_service("upgrade", function(err) failure = err; callbacks = callbacks + 1 end)
		respond_health(3, true); flush_scheduled()
		assert.equals("cli_unavailable", failure.code); assert.equals(1, callbacks)
		assert.equals("connected", state_data.connection); assert.equals(0, client.disconnect_calls)
	end)
	it("refuses managing-host mutations after the registration changes during preflight", function()
		local file = managing_host()
		local failure
		lifecycle.manage_service("restart", function(err) failure = err end)
		assert.is_true(require("opencode.util.json_file").write(file, { pid = 1000, url = "http://localhost:4097", version = "2.0.11" }))
		respond_health(3, true); flush_scheduled()
		assert.equals("stale_connection", failure.code); assert.equals(0, client.disconnect_calls)
		assert.equals("connected", state_data.connection)
	end)
	it("recovers the existing daemon connection after a native restart command failure", function()
		managing_host()
		local failure
		lifecycle.manage_service("restart", function(err) failure = err end)
		respond_health(3, true); flush_scheduled()
		assert.equals("cli_unavailable", failure.code); assert.equals(4, #health_callbacks)
		respond_health(4, true); respond_health(5, true); flush_scheduled()
		assert.equals("connected", state_data.connection)
	end)
	it("discovers native URL/auth and verifies PID before connecting without owning the daemon", function()
		managed_file({ pid = 1000, version = "2.0.11", url = "http://127.0.0.1:4096/prefix", password = "private-value" })
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		assert.equals(0, #jobs); assert.equals("connecting", state_data.connection)
		respond_health(1, true); respond_health(2, true); flush_scheduled()
		assert.equals("connected", state_data.connection); assert.equals(1, runs)
		assert.is_false(state_data.server.managed); assert.is_nil(state_data.server.pid)
		assert.equals("http://127.0.0.1:4096/prefix", state_data.http_setup.url)
		assert.equals("private-value", state_data.http_setup.auth.password)
		assert.is_nil(lifecycle.managed_status().password); assert.is_false(lifecycle.managed_status().can_manage)
	end)
	it("rejects stale managed PID/version and registration replacement during health", function()
		local file = managed_file({ pid = 1001, url = "http://localhost:4096" })
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		respond_health(1, true); flush_scheduled()
		assert.equals("error", state_data.connection); assert.equals(0, client.connect_calls); assert.equals(0, runs)
		assert.is_true(require("opencode.util.json_file").write(file, { pid = 1000, url = "http://localhost:4096" }))
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		assert.is_true(require("opencode.util.json_file").write(file, { pid = 1000, url = "http://localhost:4097" }))
		respond_health(2, true); flush_scheduled()
		assert.equals("error", state_data.connection); assert.equals(0, runs)
	end)
	it("rediscovery refreshes native endpoint and credentials and ignores late disconnected health", function()
		local file = managed_file({ pid = 1000, url = "http://localhost:4096", password = "one" })
		lifecycle.start(); respond_health(1, true); respond_health(2, true); flush_scheduled()
		assert.is_true(require("opencode.util.json_file").write(file, { pid = 1000, url = "https://localhost:4097/proxy", password = "two" }))
		local result, guard = nil, true
		state_data.sse_setup.resolve_endpoint(function(err, value) result = { err = err, config = value } end, function() return guard end)
		respond_health(3, true); assert.is_nil(result.err); assert.equals("https://localhost:4097/proxy", result.config.url)
		assert.equals("two", result.config.auth.password)
		result = nil
		state_data.sse_setup.resolve_endpoint(function(...) result = { ... } end, function() return guard end)
		guard = false; lifecycle.disconnect(); respond_health(4, true); flush_scheduled()
		assert.is_nil(result); assert.equals("idle", state_data.connection)
	end)
	it("connects URL endpoints without spawning and sanitizes invalid URL status", function()
		lifecycle.setup({ url = "https://host/proxy", auto_start = true }); state_data.server.url = "https://host/proxy"
		lifecycle.start(); respond_health(1, true); flush_scheduled()
		assert.equals(0, #jobs); assert.equals("connected", state_data.connection); assert.is_false(state_data.server.managed)
		lifecycle.setup({ url = "https://user:private-value@host" })
		assert.is_nil(lifecycle.managed_status().url:find("private-value", 1, true))
	end)
	it("waits for native readiness rather than successful HTTP headers or stream open", function()
		client.auto_ready = false
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		emit_listening(jobs[1], 4096); respond_health(1, true); flush_scheduled()
		assert.equals("connecting", state_data.connection); assert.equals(0, runs)
		listeners["server.connected"][1](); listeners["server.connected"][1](); flush_scheduled()
		assert.equals("connected", state_data.connection); assert.equals(1, runs)
	end)
	it("drops waiting readiness and stale native events on manual disconnect", function()
		client.auto_ready = false
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		emit_listening(jobs[1], 4096); respond_health(1, true)
		lifecycle.disconnect(); listeners["server.connected"][1](); flush_scheduled()
		assert.equals("idle", state_data.connection); assert.equals(0, runs)
	end)
	it("expires header-only external readiness without dispatching an action", function()
		client.auto_ready = false
		lifecycle.setup({ port = 4096 }); state_data.server.port = 4096
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		respond_health(1, true); fire_timer(last_active_timer()); flush_scheduled()
		assert.equals("error", state_data.connection); assert.equals(0, runs)
	end)
	for _, action in ipairs({ "disconnect", "stop" }) do
		it("does not warn about an expected SSE close during " .. action, function()
			complete_start()
			local warnings = {}
			vim.notify = function(message, level)
				if level == vim.log.levels.WARN then warnings[#warnings + 1] = message end
			end
			local disconnect_events = client.disconnect_events
			client.disconnect_events = function()
				disconnect_events()
				for _, callback in ipairs(listeners.disconnected) do callback("closed") end
			end

			lifecycle[action]()
			assert.same({}, warnings)
			assert.equals("idle", state_data.connection)
		end)
	end

	it("drops readiness callbacks scheduled before disconnect", function()
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		emit_listening(jobs[1], 4096)
		respond_health(1, true)
		assert.equals("connected", state_data.connection)
		lifecycle.disconnect()
		flush_scheduled()
		assert.equals(0, runs)
	end)

	it("drops already-connected callbacks after disconnect and reconnect", function()
		complete_start()
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		lifecycle.disconnect()
		lifecycle.start()
		respond_health(#health_callbacks, true)
		flush_scheduled()
		assert.equals("connected", state_data.connection)
		assert.equals(0, runs)
	end)

	for _, phase in ipairs({ "readiness", "already-connected" }) do
		it("drops queued " .. phase .. " actions after SSE loss and automatic reconnect", function()
			local runs = 0
			if phase == "readiness" then
				lifecycle.ensure_connected(function() runs = runs + 1 end)
				emit_listening(jobs[1], 4096)
				respond_health(1, true)
			else
				complete_start()
				lifecycle.ensure_connected(function() runs = runs + 1 end)
			end
			listeners.disconnected[1]("eof")
			listeners["server.connected"][1]()
			flush_scheduled()
			assert.equals("connected", state_data.connection)
			assert.equals(0, runs)
			lifecycle.ensure_connected(function() runs = runs + 1 end)
			flush_scheduled()
			assert.equals(1, runs)
		end)
	end

	it("keeps an explicit health check alive while automatic SSE reconnects come and go", function()
		complete_start()
		listeners.disconnected[1]("eof")
		local runs = 0
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		listeners["server.connected"][1]()
		listeners.disconnected[1]("eof")
		respond_health(#health_callbacks, true)
		flush_scheduled()
		assert.equals("connected", state_data.connection)
		assert.equals(1, runs)
	end)

	it("stops dispatching a readiness batch when its first action disconnects", function()
		local runs = 0
		lifecycle.ensure_connected(function() lifecycle.disconnect() end)
		lifecycle.ensure_connected(function() runs = runs + 1 end)
		emit_listening(jobs[1], 4096)
		respond_health(1, true)
		flush_scheduled()
		assert.equals(0, runs)
	end)

	it("shares one ephemeral credential between the owned process, HTTP and SSE", function()
		lifecycle.ensure_connected(function() end)
		local job = jobs[1]
		assert.same({ "serve", "--hostname", "localhost", "--port", "0" }, job.opts.args)
		local password = job.opts.env.OPENCODE_SERVER_PASSWORD
		assert.equals("string", type(password), "owned credential type")
		assert.equals(64, #password, "owned credential length")
		emit_listening(job, 4096)
		assert.equals(password, state_data.http_setup.auth.password, "HTTP credential")
		assert.equals(password, state_data.sse_setup.auth.password, "SSE credential")
		assert.equals(false, job.opts.enable_recording, "no raw startup-output retention")
		assert.equals(nil, lifecycle.opts.auth, "generated secret does not become user configuration")
	end)

	it("installs completion options in the owned process and keeps its startup snapshot", function()
		local completion = {
			enabled = true, model = { providerID = "openai", modelID = "coder" },
			options = { settings = { reasoningEffort = "none" } },
		}
		lifecycle.setup({ completion = completion, env = { OPENCODE_CONFIG_CONTENT = '{"model":"openai/chat"}' } })
		local job = complete_start()
		local overlay = vim.json.decode(job.opts.env.OPENCODE_CONFIG_CONTENT)
		assert.equals("openai/chat", overlay.model)
		local variant = overlay.providers.openai.models.coder.variants[1]
		assert.same({ reasoningEffort = "none" }, variant.settings)
		assert.equals(variant.id, lifecycle.resolve_completion_model(completion).variant)
		completion.options.settings.reasoningEffort = "low"
		lifecycle.setup({ completion = completion })
		local model, err = lifecycle.resolve_completion_model(completion)
		assert.is_nil(model)
		assert.matches("restart", err, 1, true)
		assert.equals(1, #jobs)
		lifecycle.setup({ completion = { enabled = true, model = completion.model, variant = "fast" } })
		assert.is_nil(lifecycle.opts.completion.options)
	end)

	it("installs independent completion and explanation profiles in one owned process", function()
		local completion = {
			enabled = true, model = { providerID = "openai", modelID = "coder" },
			options = { body = { reasoning_effort = "none" } },
		}
		local explanation = vim.deepcopy(completion)
		lifecycle.setup({
			completion = completion,
			explanation = explanation,
			env = { OPENCODE_CONFIG_CONTENT = '{"model":"openai/chat"}' },
		})
		local job = complete_start()
		local overlay = vim.json.decode(job.opts.env.OPENCODE_CONFIG_CONTENT)
		local variants = overlay.providers.openai.models.coder.variants
		assert.equals(2, #variants)
		assert.equals("openai/chat", overlay.model)
		assert.same({ reasoning_effort = "none" }, variants[1].body)
		assert.same({ reasoning_effort = "none" }, variants[2].body)
		assert.equals(variants[1].id, lifecycle.resolve_completion_model(completion).variant)
		assert.equals(variants[2].id, lifecycle.resolve_explanation_model(explanation).variant)
		assert.are_not.equals(variants[1].id, variants[2].id)
		explanation.options.body.reasoning_effort = "low"
		lifecycle.setup({ explanation = explanation })
		assert.equals(variants[1].id, lifecycle.resolve_completion_model(completion).variant)
		local model, err = lifecycle.resolve_explanation_model(explanation)
		assert.is_nil(model)
		assert.matches("restart", err, 1, true)
		assert.equals(1, #jobs)
	end)

	it("keeps completion available when explanation overlay is invalid", function()
		local completion = {
			enabled = true, model = { providerID = "openai", modelID = "coder" },
			options = { body = { max_tokens = 32 } },
		}
		local explanation = {
			enabled = true, model = { providerID = "openai", modelID = "coder" },
			variant = "brief", options = { body = { max_tokens = 64 } },
		}
		lifecycle.setup({ completion = completion, explanation = explanation })
		local job = complete_start()
		local variants = vim.json.decode(job.opts.env.OPENCODE_CONFIG_CONTENT).providers.openai.models.coder.variants
		assert.equals(1, #variants)
		assert.equals(variants[1].id, lifecycle.resolve_completion_model(completion).variant)
		local model, err = lifecycle.resolve_explanation_model(explanation)
		assert.is_nil(model)
		assert.matches("not both", err, 1, true)
	end)

	it("isolates invalid completion options from ordinary startup", function()
		local completion = {
			enabled = true, model = { providerID = "openai", modelID = "coder" },
			variant = "fast", options = {},
		}
		lifecycle.setup({ completion = completion, env = { OPENCODE_CONFIG_CONTENT = '{"model":"openai/chat"}' } })
		local job = complete_start()
		assert.equals('{"model":"openai/chat"}', job.opts.env.OPENCODE_CONFIG_CONTENT)
		assert.equals("connected", state_data.connection)
		local model, err = lifecycle.resolve_completion_model(completion)
		assert.is_nil(model)
		assert.matches("not both", err, 1, true)
	end)

	it("refreshes completion profiles only after a managed process is restarted", function()
		local completion = { enabled = true, model = { providerID = "local", modelID = "coder" }, options = { body = { max_tokens = 32 } } }
		lifecycle.setup({ completion = completion })
		local first_job = complete_start()
		local first_variant = lifecycle.resolve_completion_model(completion).variant
		lifecycle.disconnect()
		assert.equals(first_variant, lifecycle.resolve_completion_model(completion).variant)
		lifecycle.ensure_connected(function() end)
		respond_health(#health_callbacks, true)
		flush_scheduled()
		completion.options.body.max_tokens = 64
		lifecycle.setup({ completion = completion })
		assert.is_nil(lifecycle.resolve_completion_model(completion))
		lifecycle.restart()
		first_job.opts.on_exit(first_job, 0, 15)
		flush_scheduled()
		local second_job = jobs[2]
		emit_listening(second_job, 4012)
		respond_health(#health_callbacks, true)
		flush_scheduled()
		local variant = lifecycle.resolve_completion_model(completion).variant
		assert.are_not.equals(first_variant, variant)
		assert.equals(64, vim.json.decode(second_job.opts.env.OPENCODE_CONFIG_CONTENT).providers["local"].models.coder.variants[1].body.max_tokens)
		lifecycle.stop()
		second_job.opts.on_exit(second_job, 0, 15)
		flush_scheduled()
		assert.is_nil(lifecycle.resolve_completion_model(completion))
	end)

	it("rejects local completion options for an explicitly connected server", function()
		local completion = { enabled = true, model = { providerID = "local", modelID = "coder" }, options = {} }
		lifecycle.setup({ port = 4096, completion = completion })
		state_data.server.port = 4096
		lifecycle.ensure_connected(function() end)
		respond_health(1, true)
		flush_scheduled()
		assert.equals(0, #jobs)
		assert.equals("connected", state_data.connection)
		local model, err = lifecycle.resolve_completion_model(completion)
		assert.is_nil(model)
		assert.matches("external server", err, 1, true)
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

		assert.equals(0, old_runs, "failed action")
		assert.equals(0, lifecycle.status().pending_callbacks, "failed queue")
		assert.equals("error", state_data.connection, "failed state")
		assert.equals(true, state_data.server.managed, "failure ownership")
		assert.equals(1, first_job.signal_count, "failure signal")

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

		assert.equals(0, old_runs, "old action after retry")
		assert.equals(1, retry_runs, "retry action")
	end)

	it("retains ownership when synchronous signaling fails", function()
		local stranded_runs = 0
		lifecycle.ensure_connected(function()
			stranded_runs = stranded_runs + 1
		end)
		local job = jobs[1]
		job.kill_fails = true

		fire_timer(timers[1])

		assert.equals(1, job.signal_count, "failed signal count")
		assert.equals("error", state_data.connection, "signal failure state")
		assert.equals(true, state_data.server.managed, "signal failure managed state")
		assert.equals(job.pid, state_data.server.pid, "signal failure PID")
		assert.equals(0, lifecycle.status().pending_callbacks, "signal failure queue")
		assert.equals(false, lifecycle.start(), "replacement start while owned")
		assert.equals(1, #jobs, "replacement job count")

		lifecycle.ensure_connected(function()
			stranded_runs = stranded_runs + 1
		end)
		assert.equals(0, lifecycle.status().pending_callbacks, "refused retry queue")
		assert.equals(0, stranded_runs, "refused retry action")

		job.kill_fails = false
		assert.equals(true, lifecycle.stop(), "stop retry result")
		assert.equals(2, job.signal_count, "stop retry signal")
		assert.equals(true, state_data.server.managed, "ownership before exit")

		job.opts.on_exit(job, 0, 15)
		flush_scheduled()
		assert.equals(false, state_data.server.managed, "ownership after exit")
		assert.equals(nil, state_data.server.pid, "PID after exit")
	end)

	it("waits for delayed process exit before restarting", function()
		local first_job = complete_start(nil, 4201)

		lifecycle.restart()

		assert.equals(1, first_job.signal_count, "restart signal dispatch")
		assert.equals(15, first_job.last_signal, "restart signal")
		assert.equals(1, #jobs, "restart before exit")
		assert.equals(1, client.disconnect_calls, "restart disconnects SSE before teardown")

		flush_scheduled()
		assert.equals(1, #jobs, "restart remains pending until observed exit")

		first_job.opts.on_exit(first_job, 0, 15)
		flush_scheduled()
		assert.equals(2, #jobs, "restart after observed exit")

		local second_job = jobs[2]
		emit_listening(second_job, 4202)
		respond_health(2, true)
		flush_scheduled()
		assert.equals("connected", state_data.connection, "restarted connection")
	end)

	it("reconnects an external server immediately without a restart delay", function()
		lifecycle.setup({ port = 4096 }); state_data.server.port = 4096
		lifecycle.ensure_connected(function() end)
		respond_health(1, true); flush_scheduled()
		lifecycle.restart()
		assert.equals(2, #health_callbacks)
		assert.is_nil(last_active_timer())
		assert.equals(1, state_data.cleanup_calls)
		respond_health(2, true); flush_scheduled()
		assert.equals("connected", state_data.connection)
		assert.equals(0, #jobs)
	end)

	it("does not revive an external restart after explicit disconnect", function()
		lifecycle.setup({ port = 4096 }); state_data.server.port = 4096
		lifecycle.ensure_connected(function() end)
		respond_health(1, true); flush_scheduled()
		lifecycle.restart(); lifecycle.disconnect()
		for _, timer in ipairs(vim.list_slice(timers)) do if timer.active then fire_timer(timer) end end
		assert.equals("idle", state_data.connection)
		if health_callbacks[2] then respond_health(2, true) end
		flush_scheduled()
		assert.equals("idle", state_data.connection)
		assert.equals(1, client.connect_calls)
	end)

	for _, cancellation in ipairs({ "disconnect", "stop", "setup" }) do
		it("cancels a managed restart when " .. cancellation .. " supersedes it", function()
			local job = complete_start()
			lifecycle.restart()
			if cancellation == "setup" then lifecycle.setup({ command = "/other/opencode" })
			else lifecycle[cancellation]() end
			job.opts.on_exit(job, 0, 15); flush_scheduled()
			assert.equals(1, #jobs)
			assert.equals("idle", state_data.connection)
			assert.is_nil(state_data.server.pid)
		end)
	end

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

		assert.equals(0, client.connect_calls, "late connect count")
		assert.equals(4301, state_data.server.port, "late stdout port")
		assert.equals(0, old_runs, "timed-out action")

		first_job.opts.on_exit(first_job, 0, 15)
		flush_scheduled()
		lifecycle.ensure_connected(function()
			retry_runs = retry_runs + 1
		end)
		local second_job = jobs[2]

		first_job.opts.on_exit(first_job, 1, 0)
		flush_scheduled()
		assert.equals(second_job.pid, state_data.server.pid, "stale exit PID")

		emit_listening(second_job, 4302)
		respond_health(2, true)
		flush_scheduled()
		assert.equals(0, old_runs, "old action after timeout retry")
		assert.equals(1, retry_runs, "timeout retry action")
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

		assert.equals(0, runs, "health failure action")
		assert.equals("error", state_data.connection, "health failure state")
		assert.equals(1, job.signal_count, "health failure signal")
		assert.equals(0, lifecycle.status().pending_callbacks, "health failure queue")

		health_callbacks[2](nil, { healthy = true, version = "late" })
		flush_scheduled()
		assert.equals(0, client.connect_calls, "late health connect")
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
			assert.equals(1, #(listeners[event_type] or {}), event_type .. " initial listeners")
		end

		lifecycle.disconnect()
		client.connect_result = false
		client.connect_error = "auth failed"
		lifecycle.ensure_connected(function()
			failed_runs = failed_runs + 1
		end)
		respond_health(2, true)
		flush_scheduled()

		assert.equals(1, #jobs, "failed reconnect job count")
		assert.equals(0, job.signal_count, "failed reconnect process signal")
		assert.equals(0, failed_runs, "failed reconnect action")
		assert.equals(0, lifecycle.status().pending_callbacks, "failed reconnect queue")

		client.connect_result = true
		client.connect_error = nil
		lifecycle.ensure_connected(function()
			retry_runs = retry_runs + 1
		end)
		respond_health(3, true)
		flush_scheduled()

		assert.equals(1, #jobs, "successful reconnect job count")
		assert.equals(1, retry_runs, "successful reconnect action")
		for _, event_type in ipairs(event_types) do
			assert.equals(1, #(listeners[event_type] or {}), event_type .. " reconnect listeners")
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

		assert.equals(0, runs, "exited action")
		assert.equals(0, lifecycle.status().pending_callbacks, "exited queue")
		assert.equals("error", state_data.connection, "exited state")
		assert.equals(false, state_data.server.managed, "exited ownership")
	end)

	it("dispatches stop synchronously and idempotently", function()
		local job = complete_start(nil, 4601)

		assert.equals(true, lifecycle.stop(), "first stop")
		assert.equals(1, job.signal_count, "first stop signal")
		assert.equals(15, job.last_signal, "first stop SIGTERM")
		assert.equals(1, client.disconnect_calls, "stop disconnects SSE")
		assert.equals(1, #jobs, "stop kill job count")
		assert.equals(true, lifecycle.stop(), "repeated stop")
		assert.equals(1, job.signal_count, "repeated stop signal")
		assert.equals(1, client.disconnect_calls, "repeated stop does not disconnect twice")
		assert.equals(true, state_data.server.managed, "managed before exit")

		job.opts.on_exit(job, 0, 15)
		flush_scheduled()
		assert.equals(false, state_data.server.managed, "managed after exit")
	end)

	it("escalates a hung stop to SIGKILL then releases ownership", function()
		local job = complete_start(nil, 4701)

		assert.equals(true, lifecycle.stop(), "hung stop")
		assert.equals(15, job.last_signal, "hung stop SIGTERM")
		assert.equals(false, lifecycle.start(), "start blocked while stopping")

		local term_timer = last_active_timer()
		assert(term_timer, "stop timeout must be armed")
		fire_timer(term_timer)

		assert.equals(2, job.signal_count, "SIGKILL dispatch")
		assert.equals(9, job.last_signal, "hung stop SIGKILL")
		assert.equals(false, lifecycle.start(), "start blocked after SIGKILL")
		assert.equals(true, state_data.server.managed, "owned after SIGKILL")

		local kill_timer = last_active_timer()
		assert(kill_timer, "SIGKILL wait must be armed")
		fire_timer(kill_timer)
		flush_scheduled()

		assert.equals(false, state_data.server.managed, "released after SIGKILL timeout")
		assert.equals("error", state_data.connection, "error after SIGKILL timeout")
		assert.equals(true, lifecycle.start(), "start after hang release")
		assert.equals(2, #jobs, "replacement job after hang release")
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

		assert.equals(0, runs, "disabled action")
		assert.equals(0, #jobs, "disabled jobs")
		assert.equals(0, lifecycle.status().pending_callbacks, "disabled queue")
	end)
end)
