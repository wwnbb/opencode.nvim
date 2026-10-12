describe("native VCS HTTP facade", function()
	local saved, schedule, requests, response, client, api
	local names = { "opencode.client", "opencode.client.api", "opencode.client.http", "opencode.client.transport" }
	local directory = "/project space"
	local function body(data, status)
		response = { status = status or 200, headers = { ["content-type"] = "application/json" }, body = vim.json.encode({ data = data, location = { directory = directory } }) }
	end
	local function invoke(method, opts)
		local result
		client[method](opts or { directory = directory }, function(err, data, meta) result = { err = err, data = data, meta = meta } end)
		assert.is_table(result)
		return result
	end
	before_each(function()
		saved, requests = {}, {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		schedule = vim.schedule; vim.schedule = function(callback) callback() end
		package.loaded["opencode.client.transport"] = { request = function(opts, callback) requests[#requests + 1] = opts; callback(nil, response) end }
		client, api = require("opencode.client"), require("opencode.client.api")
		client.http.setup({ host = "127.0.0.1", port = 4096 })
	end)
	after_each(function()
		vim.schedule = schedule
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	end)

	it("reads branch metadata, nullable inferred base, and native branch names at an explicit location", function()
		local info = { provider = "git", branch = { current = "feature", default = "main" } }
		body(info)
		local result = invoke("get_vcs_info")
		assert.same(info, result.data); assert.equals(directory, result.meta.location.directory)
		assert.equals("/api/vcs?location%5Bdirectory%5D=%2Fproject%20space", requests[1].path)
		body(vim.NIL); assert.equals(vim.NIL, invoke("get_vcs_base").data)
		assert.equals("/api/vcs/base?location%5Bdirectory%5D=%2Fproject%20space", requests[2].path)
		body({ "main", "remotes/origin/main" })
		assert.same({ "main", "remotes/origin/main" }, invoke("list_vcs_branches", { directory = directory, search = "origin/main" }).data)
		assert.equals("/api/vcs/branch?limit=100&location%5Bdirectory%5D=%2Fproject%20space&search=origin%2Fmain", requests[3].path)
	end)

	it("encodes source, explicit base, zero context, and the native patch DTO without full files", function()
		local diff = { { file = "a.lua", patch = "@@ -1 +1 @@\n-old\n+new\n", additions = 1, deletions = 1, status = "modified" } }
		body(diff)
		local result = invoke("get_vcs_diff", { directory = directory, mode = "committed", base = "remotes/origin/main", context = 0 })
		assert.same(diff, result.data); assert.is_nil(result.data[1].before); assert.is_nil(result.data[1].after)
		assert.equals("/api/vcs/diff?base=remotes%2Forigin%2Fmain&context=0&location%5Bdirectory%5D=%2Fproject%20space&mode=committed", requests[1].path)
		invoke("get_vcs_diff")
		assert.equals("/api/vcs/diff?location%5Bdirectory%5D=%2Fproject%20space&mode=branch", requests[2].path)
		for _, request in ipairs(requests) do assert.equals("GET", request.method); assert.is_nil(request.body) end
	end)

	it("rejects missing envelopes and retains unsupported, authentication, and ambiguous-base errors", function()
		response = { status = 200, headers = { ["content-type"] = "application/json" }, body = vim.json.encode({ data = {} }) }
		assert.equals("incompatible_response", invoke("get_vcs_diff").err.code)
		for _, error in ipairs({ { status = 404, message = "Not found" }, { status = 401, message = "Unauthorized" }, { status = 503, message = "Ambiguous base" } }) do
			response = { status = error.status, headers = { ["content-type"] = "application/json" }, body = vim.json.encode({ _tag = "TestError", message = error.message }) }
			local result = invoke("get_vcs_base")
			assert.is_nil(result.data); assert.equals(error.status, result.err.status); assert.equals(error.message, result.err.message)
		end
	end)
end)

describe("VCS actions", function()
	local actions, client = require("opencode.actions"), require("opencode.client")
	local lifecycle, state, pending = require("opencode.lifecycle"), require("opencode.state"), require("opencode.session.pending")
	local saved, calls
	local methods = { "get_vcs_info", "get_vcs_base", "list_vcs_branches", "get_vcs_diff" }
	before_each(function()
		state.reset(); pending.clear_all(); state.set_session("s", "Session")
		state.upsert_session({ id = "s", directory = "/session project" }, { touch = false })
		saved, calls = { connected = lifecycle.ensure_connected }, {}
		lifecycle.ensure_connected = function(callback) callback() end
		for _, method in ipairs(methods) do
			saved[method] = client[method]
			client[method] = function(opts, callback) calls[#calls + 1] = { method = method, opts = opts, callback = callback } end
		end
	end)
	after_each(function()
		for _, method in ipairs(methods) do client[method] = saved[method] end
		lifecycle.ensure_connected = saved.connected
		state.reset(); pending.clear_all()
	end)

	it("scopes each method to the session location and drops a response after disconnect", function()
		local responses = 0
		for _, method in ipairs(methods) do actions[method]({ context = 0 }, function() responses = responses + 1 end) end
		for index, method in ipairs(methods) do assert.equals(method, calls[index].method); assert.same({ directory = "/session project", context = 0 }, calls[index].opts) end
		require("tests.helpers.schedule").with(function(flush)
			calls[1].callback(nil, {}); flush(); assert.equals(1, responses)
			pending.invalidate(); calls[2].callback(nil, {}); flush()
			assert.equals(1, responses)
		end)
	end)
end)
