describe("integration connection method selection", function()
	local integration, menus, input, notices, stubs
	before_each(function()
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

end)
