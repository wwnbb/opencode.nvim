describe("v2 model preferences", function()
	local preferences = require("opencode.preferences")
	local directory
	before_each(function() directory = vim.fn.tempname(); vim.fn.mkdir(directory, "p") end)
	after_each(function() vim.fn.delete(directory, "rf") end)

	local function read_bytes(path)
		local file = assert(io.open(path, "rb"))
		local bytes = file:read("*a")
		file:close()
		return bytes
	end

	it("refuses versionless preferences without reading or changing them", function()
		local path = directory .. "/prefs.json"
		local original = '{"favorite":[{"providerID":"offline","modelID":"old"}],"custom":"preserve"}'
		vim.fn.writefile({ original }, path, "b")
		local notify, notices = vim.notify, {}
		vim.notify = function(message) notices[#notices + 1] = message end
		local owner = preferences.open(path)
		vim.notify = notify
		assert.same({}, owner.data)
		assert.is_false(owner.save({ agent = "stable-id" }))
		assert.equals(original, read_bytes(path))
		assert.equals(0, vim.fn.filereadable(path .. ".v1.bak"))
		assert.matches("version 2 JSON file", notices[1])
	end)

	it("writes a new format 2 file and preserves unknown format 2 settings", function()
		local path = directory .. "/prefs.json"
		local owner = preferences.open(path)
		assert.equals(2, owner.data.version)
		assert.is_true(owner.save({ favorite = { { providerID = "offline", modelID = "logical" } }, custom = "preserve" }))
		local loaded = preferences.open(path)
		assert.equals(2, loaded.data.version)
		assert.equals("logical", loaded.data.favorite[1].modelID)
		assert.equals("preserve", loaded.data.custom)
		assert.is_true(loaded.save({ agent = "stable-id" }))
		assert.equals("preserve", preferences.open(path).data.custom)
		assert.equals("stable-id", preferences.open(path).data.agent)
	end)

	it("preserves unreadable and unsupported versioned files", function()
		for _, original in ipairs({ "{bad json", '{"version":3,"agent":"future"}' }) do
			local path = directory .. "/prefs.json"
			vim.fn.writefile({ original }, path, "b")
			local owner = preferences.open(path)
			assert.same({}, owner.data)
			assert.is_false(owner.save({ agent = "build" }))
			assert.equals(original, read_bytes(path))
		end
	end)

	it("does not replace an existing file when opening it for reading fails", function()
		local path = directory .. "/prefs.json"
		local original = '{"version":2,"agent":"keep"}'
		vim.fn.writefile({ original }, path, "b")
		local open = io.open
		io.open = function(name, mode)
			if name == path and mode == "rb" then return nil, "permission denied" end
			return open(name, mode)
		end
		local ok, owner = pcall(preferences.open, path)
		io.open = open
		assert.is_true(ok)
		assert.is_false(owner.save({ agent = "replace" }))
		assert.equals(original, read_bytes(path))
	end)

	it("separates two identically named agents and does not invent a default model", function()
		package.loaded["opencode.local"] = nil
		local local_state, sync = require("opencode.local"), require("opencode.sync")
		sync.clear_all()
		sync.handle_agents({ { id = "a", name = "Same" }, { id = "b", name = "Same" } })
		sync.handle_providers({ { id = "p", models = { one = {}, two = {} } } })
		assert.is_nil(local_state.model.current())
		local_state.agent.set("a"); local_state.model.set({ providerID = "p", modelID = "one" })
		local_state.agent.set("b"); local_state.model.set({ providerID = "p", modelID = "two" })
		local_state.agent.set("a"); assert.equals("one", local_state.model.current().modelID)
		local_state.agent.set("b"); assert.equals("two", local_state.model.current().modelID)
		sync.clear_all(); package.loaded["opencode.local"] = nil
	end)
end)
