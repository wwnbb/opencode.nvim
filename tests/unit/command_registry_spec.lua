local registry = require("opencode.command_registry")
local slash = require("opencode.slash")

describe("shared command registry", function()
	local ids = { "test.registry_unified", "test.registry_disabled", "test.palette_legacy", "slash.ztest_legacy_registry" }

	after_each(function()
		for _, id in ipairs(ids) do registry.unregister(id) end
	end)

	it("resolves one canonical definition through its id, slash name, and aliases", function()
		local calls = {}
		registry.register({
			id = "test.registry_unified",
			title = "Unified test",
			category = "actions",
			slash = { name = "ztest-unified", aliases = { "ztest-alias" } },
			run = function(ctx) calls[#calls + 1] = { kind = "run", source = ctx.source, args = ctx.args } end,
			on_select = function(ctx)
			calls[#calls + 1] = { kind = "select", source = ctx.source }
			ctx.run()
		end,
		})

		local command = registry.get("test.registry_unified")
		assert.is_not_nil(command)
		assert.equals(command, registry.get_slash("ztest-unified"))
		assert.equals(command, registry.get_slash("ztest-alias"))
		local count = 0
		for _, entry in ipairs(registry.all()) do
			if entry.id == command.id then count = count + 1 end
		end
		assert.equals(1, count)
		local listed = false
		for _, entry in ipairs(registry.list_slash()) do
			if entry.id == command.id then
				listed = true
				assert.equals("ztest-unified", entry.name)
				assert.same({ "ztest-alias" }, entry.aliases)
			end
		end
		assert.is_true(listed)

		assert.is_true(registry.select(command.id, { source = "completion" }))
		assert.same({
			{ kind = "select", source = "completion" },
			{ kind = "run", source = "completion" },
		}, calls)
		assert.is_true(registry.run(command.id, { source = "palette", args = "later" }))
		assert.same({ kind = "run", source = "palette", args = "later" }, calls[3])
	end)

	it("rejects disabled and stale completion selections", function()
		local active, called = true, 0
		registry.register({
			id = "test.registry_disabled",
			title = "Conditional test",
			category = "actions",
			slash = { name = "ztest-conditional" },
			enabled = function() return active end,
			run = function() called = called + 1 end,
			on_select = function(ctx) ctx.run() end,
		})
		local function offered()
			for _, entry in ipairs(registry.list_slash()) do
				if entry.name == "ztest-conditional" then return true end
			end
			return false
		end
		assert.is_true(offered())
		active = false
		assert.is_false(offered())
		assert.is_false(registry.select("test.registry_disabled", { source = "completion" }))
		assert.is_false(registry.run("test.registry_disabled", { source = "slash" }))
		assert.equals(0, called)
		registry.unregister("test.registry_disabled")
		assert.is_nil(registry.get_slash("ztest-conditional"))
		assert.is_false(registry.select("test.registry_disabled", { source = "completion" }))
		assert.equals(0, called)
	end)

	it("keeps legacy slash registration and argument callbacks working", function()
		local received
		slash.register({
			name = "ztest_legacy_registry",
			aliases = { "ztest_legacy_alias" },
			category = "test",
			handler = function(args, parsed) received = { args = args, command = parsed.command } end,
		})
		assert.is_not_nil(registry.get("slash.ztest_legacy_registry"))
		assert.is_not_nil(registry.get_slash("ztest_legacy_alias"))
		assert.is_true(slash.execute(slash.parse("/ztest_legacy_alias with args")))
		assert.same({ args = "with args", command = "ztest_legacy_alias" }, received)
		slash.unregister("ztest_legacy_registry")
		assert.is_nil(registry.get_slash("ztest_legacy_alias"))
	end)

	it("keeps legacy palette registration on the shared action path", function()
		local calls = 0
		require("opencode.ui.palette").register({
			id = "test.palette_legacy",
			title = "Legacy palette test",
			category = "actions",
			action = function() calls = calls + 1 end,
		})
		assert.is_not_nil(registry.get("test.palette_legacy"))
		assert.is_true(registry.run("test.palette_legacy", { source = "palette" }))
		assert.equals(1, calls)
	end)
end)
