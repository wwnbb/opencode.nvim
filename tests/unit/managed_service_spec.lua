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
	it("returns an unavailable result for a missing file", function()
		local value, err = managed.read(opts); assert.is_nil(value); assert.equals("service_unavailable", err.code); assert.is_true(err.retryable)
	end)
end)
