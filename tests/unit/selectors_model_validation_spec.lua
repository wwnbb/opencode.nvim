local selectors, state, sync = require("opencode.selectors"), require("opencode.state"), require("opencode.sync")
local logger = require("opencode.logger")

describe("selector model validation", function()
	local saved_local, saved_debug, saved_preload, logs
	before_each(function()
		saved_local, saved_debug, saved_preload = package.loaded["opencode.local"], logger.debug, package.preload["opencode.sync"]
		state.reset(); sync.clear_all()
		sync.handle_providers({ { id = "p", models = { native = {}, legacy = {}, fallback = {} } } })
		package.loaded["opencode.local"] = { model = { current = function() return { providerID = "p", modelID = "fallback" } end } }
		logs = {}
		logger.debug = function(message, data) logs[#logs + 1] = { message = message, data = data } end
	end)
	after_each(function()
		package.loaded["opencode.local"], logger.debug, package.preload["opencode.sync"] = saved_local, saved_debug, saved_preload
		package.loaded["opencode.sync"] = sync
		state.reset(); sync.clear_all()
	end)

	it("rejects malformed, empty and unknown references before using the local fallback", function()
		for _, case in ipairs({
			{ "invalid", "malformed" },
			{ { providerID = 1, modelID = "native" }, "malformed" },
			{ { providerID = "p", id = 1, modelID = "legacy" }, "malformed" },
			{ { providerID = "", modelID = "native" }, "empty" },
			{ { providerID = "p", id = "", modelID = "legacy" }, "empty" },
			{ { providerID = "p", id = "unknown", modelID = "legacy" }, "not_in_sync" },
		}) do
			logs = {}
			local selected = selectors.send_selection({ model = case[1] })
			assert.same({ providerID = "p", modelID = "fallback" }, selected.model)
			assert.equals("local_current", selected.sources.model)
			assert.equals("Model candidate skipped", logs[1].message)
			assert.equals("opts", logs[1].data.source)
			assert.equals(case[2], logs[1].data.reason)
		end
	end)

	it("accepts both model formats and gives native id priority", function()
		for _, ref in ipairs({ { providerID = "p", id = "native", modelID = "legacy" }, { providerID = "p", modelID = "native" } }) do
			logs = {}
			local selected = selectors.send_selection({ model = ref })
			assert.same({ providerID = "p", modelID = "native" }, selected.model)
			assert.equals("opts", selected.sources.model)
			assert.equals("Model candidate accepted", logs[1].message)
			assert.is_nil(logs[1].data.reason)
		end
	end)

	it("reports unavailable sync without accepting an unvalidated model", function()
		package.loaded["opencode.sync"] = nil
		package.preload["opencode.sync"] = function() error("sync unavailable") end
		local selected = selectors.send_selection({ model = { providerID = "p", id = "native" } })
		assert.is_nil(selected.model)
		assert.equals("Model candidate skipped", logs[1].message)
		assert.equals("sync_unavailable", logs[1].data.reason)
	end)
end)
