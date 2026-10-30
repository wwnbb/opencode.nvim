describe("native managed service registration", function()
	local managed = require("opencode.managed")
	local directory, opts
	before_each(function()
		directory = vim.fn.tempname(); vim.fn.mkdir(directory .. "/opencode", "p")
		opts = { managed = true, env = { XDG_STATE_HOME = directory } }
	end)
	after_each(function() vim.fn.delete(directory, "rf") end)
	local function write(value) assert.is_true(require("opencode.util.json_file").write(managed.default_file(opts), value)) end
	it("reads the native registration and creates Basic credentials without exposing them in errors", function()
		write({ id = "native", pid = 42, version = "2.0.11", url = "http://127.0.0.1:4096", password = "private-value" })
		local info = assert(managed.read(opts)); assert.equals(42, info.pid)
		assert.same({ url = info.url, auth = { username = "opencode", password = "private-value" }, tls = {} }, managed.config(info, opts))
		assert.is_nil(managed.validate(info, { pid = 42, version = "2.0.11" }))
		assert.is_truthy(managed.validate(info, { pid = 43, version = "2.0.11" })); assert.is_truthy(managed.validate(info, { pid = 42, version = "2.0.12" }))
		assert.is_true(managed.can_manage(opts, info))
	end)
	it("accepts optional native version/password and rejects malformed registrations", function()
		write({ pid = 42, url = "http://localhost:4096" }); local info = assert(managed.read(opts))
		assert.is_nil(managed.validate(info, { pid = 42, version = "2.0.12" }))
		for _, invalid in ipairs({ { pid = 0, url = "http://localhost" }, { pid = 1.5, url = "http://localhost" },
			{ pid = 42, url = "https://user:private-value@host" }, { pid = 42, url = "http://localhost", password = {} } }) do
			write(invalid); local value, err = managed.read(opts); assert.is_nil(value); assert.is_nil(err.message:find("private-value", 1, true))
		end
	end)
	it("never offers local management for remote, explicit or custom-file discoveries", function()
		local info = { pid = 42, url = "https://remote.test/base" }
		assert.is_false(managed.can_manage(opts, info))
		info.url = "http://localhost:4096"; assert.is_false(managed.can_manage({ managed = false }, info))
		opts.service_file = directory .. "/custom.json"; assert.is_false(managed.can_manage(opts, info))
	end)
	it("detects URL, password, PID and version replacement during discovery", function()
		local info = { pid = 42, url = "http://localhost:4096", password = "one", version = "2.0.11" }
		assert.is_true(managed.same(info, vim.deepcopy(info)))
		for key, value in pairs({ pid = 43, url = "http://localhost:4097", password = "two", version = "2.0.12" }) do
			local other = vim.deepcopy(info); other[key] = value; assert.is_false(managed.same(info, other))
		end
		assert.is_false(managed.same(info, nil))
	end)
	describe("discovery", function()
		local names = { "opencode.client", "opencode.client.http", "opencode.state" }
		local saved, original, commands, health, configured, results, attempt
		before_each(function()
			saved, original = {}, { system = vim.system, executable = vim.fn.executable, schedule = vim.schedule }
			for _, name in ipairs(names) do saved[name] = package.loaded[name] end
			commands, health, configured, results, attempt = {}, {}, {}, {}, {}
			package.loaded["opencode.client"] = { configure_endpoint = function(config) configured[#configured + 1] = config end }
			package.loaded["opencode.client.http"] = { health = function(callback) health[#health + 1] = callback end }
			package.loaded["opencode.state"] = { set_server_info = function() end }
			vim.fn.executable = function() return 1 end
			vim.schedule = function(callback) callback() end
			vim.system = function(argv, _, callback)
				commands[#commands + 1] = argv
				write({ pid = 42, version = "2.0.11", url = "http://127.0.0.1:4096" })
				callback({ code = 0 })
				return {}
			end
			opts = vim.tbl_extend("force", opts, { auto_start = true, use_shell_env = false, command = "/fake/opencode", startup_timeout = 100 })
		end)
		after_each(function()
			vim.system, vim.fn.executable, vim.schedule = original.system, original.executable, original.schedule
			for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		end)
		local function discover(allow_start)
			managed.discover(attempt, { opts = function() return opts end, current = function() return true end },
				function(err, config) results[#results + 1] = { err = err, config = config } end, allow_start)
		end
		it("starts the native service once for a missing registration, then verifies it", function()
			discover(true)
			assert.same({ { "/fake/opencode", "service", "start" } }, commands)
			health[1](nil, { pid = 42, version = "2.0.11" })
			assert.is_nil(results[1].err); assert.equals("http://127.0.0.1:4096", results[1].config.url)
			assert.is_true(attempt.verified); assert.equals(42, attempt.registration.pid)
		end)
		it("starts once after a retryable health failure and reports the second failure", function()
			write({ pid = 42, version = "2.0.11", url = "http://127.0.0.1:4096" })
			discover(true)
			assert.equals(0, #commands)
			health[1]({ message = "Not ready", retryable = true })
			assert.equals(1, #commands)
			health[2]({ message = "Still not ready", retryable = true })
			assert.equals(1, #commands); assert.equals("Still not ready", results[1].err.message)
			assert.is_false(attempt.verified); assert.equals(2, #configured)
		end)
		it("cancels an in-progress native service start and ignores its late result", function()
			local finish, signals = nil, {}
			vim.system = function(argv, _, callback)
				commands[#commands + 1] = argv
				finish = callback
				return { kill = function(_, signal) signals[#signals + 1] = signal end }
			end
			local handle = managed.discover(attempt, { opts = function() return opts end, current = function() return true end },
				function(err, config) results[#results + 1] = { err = err, config = config } end, true)
			assert.equals("function", type(handle.cancel))
			handle.cancel(); handle.cancel()
			assert.same({ 15 }, signals)
			write({ pid = 42, version = "2.0.11", url = "http://127.0.0.1:4096" })
			finish({ code = 0 })
			assert.equals(0, #health); assert.equals(0, #results)
		end)
		it("does not start the service when discovery may not start it", function()
			discover(false)
			assert.equals(0, #commands); assert.equals("service_unavailable", results[1].err.code)
		end)
	end)
	it("returns an unavailable result for a missing file", function()
		local value, err = managed.read(opts); assert.is_nil(value); assert.equals("service_unavailable", err.code); assert.is_true(err.retryable)
	end)
end)
