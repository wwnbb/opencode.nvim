local catalogs = require("opencode.protocol.catalogs")

describe("native catalog projection", function()
	it("preserves all native cost tiers and isolates projected model metadata", function()
		local models = { {
			id = "logical", modelID = "upstream", providerID = "p", enabled = true,
			cost = { { input = 0 }, { input = 2, tier = { type = "context", size = 100000 } } },
			capabilities = { tools = true, input = { "text", "image" } },
			variants = { { id = "high", body = { effort = "high" } }, { id = "fast" } },
		} }
		local snapshot = vim.deepcopy(models)
		local result = catalogs.providers({ { id = "p" } }, models)
		local model = result.providers[1].models.logical
		assert.equals("logical", model.modelID)
		assert.same(models[1].cost, model.cost)
		assert.same(models[1].capabilities, model.capabilities)
		assert.same({ "high", "fast" }, model.variant_order)
		model.cost[2].tier.size = 200000
		model.capabilities.input[1] = "audio"
		model.variants.high.body.effort = "low"
		assert.same(snapshot, models)
	end)

	it("flattens MCP status without changing the source record", function()
		local records = { { name = "one", integrationID = "auth-id", status = { status = "failed", error = "offline" } } }
		local snapshot = vim.deepcopy(records)
		local result = catalogs.mcp(records)
		assert.same({ name = "one", integrationID = "auth-id", status = "failed", error = "offline" }, result.one)
		result.one.error = "changed"
		assert.same(snapshot, records)
	end)
end)
