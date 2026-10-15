describe("integration connection method selection", function()
	local integration, menus, input, notices, stubs, saved_config
	before_each(function()
		saved_config = require("opencode.state").get_config()
		integration = { id = "test", name = "Test provider", methods = {} }
		menus, notices, stubs = {}, {}, {}
		input = nil
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(require("opencode.actions"), "list_integrations", function(cb)
			cb(nil, { integration })
		end)
		stubs[#stubs + 1] = stub(require("opencode.ui.menu"), "open", function(opts) menus[#menus + 1] = opts end)
		stubs[#stubs + 1] = stub(require("opencode.ui.float"), "create_input_popup", function(opts) input = opts end)
		stubs[#stubs + 1] = stub(vim, "notify", function(message) notices[#notices + 1] = message end)
	end)
	after_each(function()
		for _, stub in ipairs(stubs) do stub:revert() end
		require("opencode.state").set_config(saved_config)
	end)

	it("opens the API key field directly after choosing a provider with env and key", function()
		integration.methods = { { type = "env", names = { "TEST_KEY" } }, { type = "key" } }
		require("opencode.ui.palette.integration").connect(nil, { directory = "/tmp" })
		assert.equals(" Integrations ", menus[1].title)
		menus[1].on_select(menus[1].items[1])
		assert.equals(1, #menus)
		assert.equals("API key", input.prompt)
		assert.equals(" Connect Test provider ", input.title)
	end)

	it("keeps a selector for multiple interactive methods and omits env", function()
		integration.methods = { { type = "env" }, { type = "key" }, { type = "oauth", label = "Browser" } }
		require("opencode.ui.palette.integration").connect("test", { directory = "/tmp" })
		assert.equals(1, #menus)
		assert.equals(2, #menus[1].items)
		assert.equals("API key", menus[1].items[1].label)
		assert.equals("Browser", menus[1].items[2].label)
		assert.is_nil(input)
	end)

	it("does not open an empty selector for an environment-only provider", function()
		integration.methods = { { type = "env" } }
		require("opencode.ui.palette.integration").connect("test", { directory = "/tmp" })
		assert.equals(0, #menus)
		assert.is_nil(input)
		assert.equals(1, #notices)
	end)
	for _, stage in ipairs({ "provider", "method", "form", "key" }) do
		it("does not reuse an old connection flow after reconnect at " .. stage, function()
			local connect_calls, submit = 0, nil
			local stub = require("luassert.stub")
			stubs[#stubs + 1] = stub(require("opencode.actions"), "connect_integration_key", function() connect_calls = connect_calls + 1 end)
			stubs[#stubs + 1] = stub(require("opencode.ui.form"), "open", function(_, _, callback) submit = callback end)
			integration.methods = stage == "method" and { { type = "key" }, { type = "oauth" } }
				or { { type = "key", form = stage == "form" and { { key = "region", type = "text" } } or nil } }
			require("opencode.ui.palette.integration").connect(stage ~= "provider" and "test" or nil, { directory = "/tmp" })
			local count = #menus
			require("opencode.session.pending").invalidate()
			if stage == "provider" or stage == "method" then menus[1].on_select(menus[1].items[1])
			elseif stage == "form" then submit({ region = "test" })
			else assert.is_not_nil(input); input.on_submit("test-key") end
			assert.equals(0, connect_calls)
			assert.equals(count, #menus)
			if stage ~= "key" then assert.is_nil(input) end
		end)
	end
	it("submits an API key on its current connection", function()
		local calls = 0
		stubs[#stubs + 1] = require("luassert.stub")(require("opencode.actions"), "connect_integration_key", function(id, key, _, opts, cb)
			assert.equals("test", id); assert.equals("test-key", key); assert.equals("/tmp", opts.directory)
			calls = calls + 1
			cb(nil, { connections = { { type = "credential" } } })
		end)
		integration.methods = { { type = "key" } }
		require("opencode.ui.palette.integration").connect("test", { directory = "/tmp" })
		input.on_submit("test-key")
		assert.equals(1, calls)
	end)
	it("replaces command login messages and displays and uses configured authorization controls", function()
		require("opencode.state").set_config(require("opencode.config").merge({ integration = { keymaps = {
			close = "Z", open = "O", code = "C", copy_url = "u", copy_instructions = "U",
		} } }))
		local callback, popup_options, lines, cancelled
		local bufnr = vim.api.nvim_create_buf(false, true)
		local popup = { mount = function() end, render = function(_, value) lines = value end }
		popup.close = function() popup_options.on_close() end
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(require("opencode.ui.float"), "create_centered_popup", function(opts)
			popup_options = opts
			return popup, bufnr
		end)
		stubs[#stubs + 1] = stub(require("opencode.actions"), "start_integration_attempt", function(id, method, _, _, listener)
			assert.equals("test", id); assert.equals("command", method.type)
			callback = listener
			return 42
		end)
		stubs[#stubs + 1] = stub(require("opencode.actions"), "cancel_integration_attempt", function(id) cancelled = id end)
		integration.methods = { { type = "command" } }
		require("opencode.ui.palette.integration").connect("test", { directory = "/tmp" })
		local view = { id = 42, status = "polling", message = "Open https://example.invalid/login\nCode: ABCD-1234" }
		callback(view); callback(view)
		assert.same({ "Authorization: polling", "", "Open https://example.invalid/login", "Code: ABCD-1234", "",
			"O: open authorization URL   C: enter code   Z: close / cancel", "u: copy URL   U: copy authorization instructions / code" }, lines)
		view.message = "Open https://example.invalid/login\nCode: ABCD-1234\nWaiting for approval"
		callback(view)
		assert.equals("Waiting for approval", lines[5])
		view.status, view.message, view.error = "failed", "Login refused\nTry another account", "Authorization failed"
		callback(view)
		assert.same({ "Authorization: failed", "", "Login refused", "Try another account", "Authorization failed", "",
			"O: open authorization URL   C: enter code   Z: close / cancel", "u: copy URL   U: copy authorization instructions / code" }, lines)
		local close_mapping
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
			assert.not_equals("<Esc>", mapping.lhs)
			assert.not_equals("q", mapping.lhs)
			if mapping.lhs == "Z" then close_mapping = mapping.callback end
		end
		assert.is_not_nil(close_mapping)
		close_mapping()
		assert.equals(42, cancelled)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)

	it("copies the native authorization URL/instructions and ignores stale clipboard shortcuts", function()
		local listener, popup_options, copied = nil, nil, {}
		local buf = vim.api.nvim_create_buf(false, true)
		local popup = { mount = function() end, render = function() end, close = function() popup_options.on_close() end }
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(require("opencode.ui.float"), "create_centered_popup", function(opts) popup_options = opts; return popup, buf end)
		stubs[#stubs + 1] = stub(require("opencode.actions"), "start_integration_attempt", function(_, _, _, _, callback) listener = callback; return 42 end)
		stubs[#stubs + 1] = stub(require("opencode.actions"), "cancel_integration_attempt", function() end)
		stubs[#stubs + 1] = stub(vim.fn, "setreg", function(register, value) copied[#copied + 1] = { register, value }; return 0 end)
		stubs[#stubs + 1] = stub(vim.fn, "getreg", function() return copied[#copied][2] end)
		integration.methods = { { type = "oauth" } }
		require("opencode.ui.palette.integration").connect("test", { directory = "/tmp" })
		listener({ id = 42, status = "polling", url = "https://example.invalid/login", instructions = "Enter code ABCD-1234" })
		local function press(lhs)
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do if mapping.lhs == lhs then return mapping.callback() end end
			error("Missing OAuth clipboard key " .. lhs)
		end
		press("y"); press("Y")
		assert.same({ { '"', "https://example.invalid/login" }, { "+", "https://example.invalid/login" },
			{ '"', "Enter code ABCD-1234" }, { "+", "Enter code ABCD-1234" } }, copied)
		require("opencode.session.pending").invalidate(); press("y"); assert.equals(4, #copied)
		popup.close(); press("Y"); assert.equals(4, #copied)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

end)
