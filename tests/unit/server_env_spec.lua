describe("server process environment", function()
	local server_env = require("opencode.server_env")
	after_each(function() server_env.reset_shell_env() end)

	it("parses the CLI listening line, including unbracketed IPv6", function()
		assert.same({ url = "http://127.0.0.1:57168", host = "127.0.0.1", port = 57168 },
			server_env.parse_server_url("server listening on http://127.0.0.1:57168"))
		assert.same({ url = "http://[::1]:4096", host = "::1", port = 4096 },
			server_env.parse_server_url("server listening on http://[::1]:4096"))
		assert.same({ url = "http://[::1]:4096", host = "::1", port = 4096 },
			server_env.parse_server_url("server listening on http://::1:4096"))
		assert.is_nil(server_env.parse_server_url("server password abc"))
		assert.is_nil(server_env.parse_server_url(nil))
	end)

	it("parses env output and promotes toolchain bins without duplicates", function()
		assert.same({ A = "1", B_2 = "x=y" }, server_env.parse_env_output("A=1\nnot a pair\r\nB_2=x=y"))
		assert.same({}, server_env.parse_env_output(""))
		assert.equals("/new:/usr/bin:/bin", server_env.prepend_path("/usr/bin:/new:/bin", "/new"))
		local env = { PATH = "/usr/bin", VOLTA_HOME = "/volta", BUN_INSTALL = "/bun", NVM_BIN = "/nvm/bin" }
		server_env.promote_toolchain_bins(env)
		assert.equals("/nvm/bin:/bun/bin:/volta/bin:/usr/bin", env.PATH)
	end)

	it("builds string-only server env with credentials and drops JSON null values", function()
		local env = server_env.build({ use_shell_env = false, config_dir = "/cfg",
			env = { OPENCODE_NVIM_TEST_VALUE = 42, OPENCODE_NVIM_TEST_REMOVED = vim.NIL } }, { username = "opencode", password = "test-secret" })
		assert.equals("42", env.OPENCODE_NVIM_TEST_VALUE)
		assert.is_nil(env.OPENCODE_NVIM_TEST_REMOVED)
		assert.equals("opencode", env.OPENCODE_SERVER_USERNAME)
		assert.equals("test-secret", env.OPENCODE_SERVER_PASSWORD)
		assert.equals("/cfg", env.OPENCODE_CONFIG_DIR)
		assert.equals("/fake/opencode", server_env.resolve_command("/fake/opencode", env))
		assert.equals("opencode-nvim-missing-command", server_env.resolve_command("opencode-nvim-missing-command", { PATH = "" }))
	end)
end)
