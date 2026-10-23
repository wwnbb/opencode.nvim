local sync = require("opencode.sync")

describe("sync.catalog_for", function()
	before_each(function()
		sync.clear_all()
		sync.select_catalog_location("/active")
		sync.handle_location_catalog("/active", "providers", {
			providers = { { id = "a", models = { one = { name = "Active one" } } } },
			default = { a = "one" }, server_default = { providerID = "a", id = "one" },
		})
		sync.handle_location_catalog("/active", "agents", { { id = "build", name = "Builder" } })
		sync.handle_location_catalog("/active", "config", { model = "a/one" })
		sync.handle_location_catalog("/other", "providers", {
			providers = { { id = "o", models = { two = { name = "Other two" } } }, { id = "bare", models = vim.NIL } },
			default = { o = "two" }, server_default = { providerID = "o", id = "two" },
		})
		sync.handle_location_catalog("/other", "agents", { { id = "plan", name = "build" }, { id = "build", name = "Other builder" } })
	end)
	after_each(function() sync.clear_all() end)

	it("uses the active store for a nil directory or the active location", function()
		for _, directory in ipairs({ vim.NIL, "/active" }) do
			local catalog = sync.catalog_for(directory ~= vim.NIL and directory or nil)
			assert.equals("/active", catalog.location)
			assert.equals(sync.get_providers(), catalog.providers)
			assert.equals(sync.get_agents(), catalog.agents)
			assert.same({ a = "one" }, catalog.defaults)
			assert.same({ model = "a/one" }, catalog.config)
			assert.same({ providerID = "a", id = "one" }, catalog.server_default)
			assert.equals("Active one", catalog:model("a", "one").name)
			assert.equals("Builder", catalog:agent("build").name)
			assert.is_true(catalog.loaded.providers and catalog.loaded.agents)
		end
	end)

	it("reads another location's entries and falls back to the active store per missing domain", function()
		local catalog = sync.catalog_for("/other")
		assert.equals("/other", catalog.location)
		assert.equals("Other two", catalog:model("o", "two").name)
		assert.is_nil(catalog:model("a", "one"))
		assert.same({ o = "two" }, catalog.defaults)
		assert.same({ providerID = "o", id = "two" }, catalog.server_default)
		assert.same({ model = "a/one" }, catalog.config, "config has no /other entry")
		assert.is_false(catalog.loaded.config)
		local missing = sync.catalog_for("/missing")
		assert.equals("Active one", missing:model("a", "one").name)
		assert.equals("Builder", missing:agent("build").name)
		assert.is_nil(missing.server_default)
		assert.is_false(missing.loaded.providers or missing.loaded.agents)
	end)

	it("matches agents by id across the whole list before display names", function()
		local catalog = sync.catalog_for("/other")
		assert.equals("Other builder", catalog:agent("build").name)
		assert.equals("plan", catalog:agent("plan").id)
		assert.equals("build", catalog:agent("Other builder").id)
		assert.is_nil(catalog:agent(nil))
	end)

	it("treats absent or non-table provider models as unavailable", function()
		local catalog = sync.catalog_for("/other")
		assert.is_nil(catalog:model("bare", "two"))
		assert.is_nil(catalog:model("missing", "two"))
	end)
end)
