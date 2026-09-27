describe("OpenCode v2 HTTP contracts", function()
	local names = { "opencode.client", "opencode.client.v2", "opencode.client.http", "opencode.client.transport" }
	local saved, schedule, requests, response, transport_error, v2, http, request_handle
	local function json(value, status)
		response = { status = status or 200, headers = { ["content-type"] = "application/json" }, body = vim.json.encode(value) }
	end
	local function invoke(name, args)
		local result, count = {}, 0
		v2.request(name, args, function(err, data, meta)
			count = count + 1
			result = { err = err, data = data, meta = meta }
		end)
		assert.equals(1, count)
		return result
	end
	before_each(function()
		saved, requests, transport_error = {}, {}, nil
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		schedule = vim.schedule
		vim.schedule = function(fn) fn() end
		request_handle = { cancel = function() end }
		package.loaded["opencode.client.transport"] = {
			request = function(opts, callback)
				requests[#requests + 1] = opts
				callback(transport_error, response)
				return request_handle
			end,
		}
		v2 = require("opencode.client.v2")
		http = require("opencode.client.http")
		http.setup({ host = "127.0.0.1", port = 4096, auth = { password = "test-password" } })
	end)
	after_each(function()
		vim.schedule = schedule
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	end)

	it("uses the recorded info response without a healthy field and rejects incompatible versions", function()
		local info = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/v2/runtime/info.json"), "\n"))
		json(info)
		local result = invoke("info")
		assert.is_nil(result.err)
		assert.equals("2.0.11", result.data.version)
		assert.equals("/api/info", requests[1].path)
		assert.equals(200, result.meta.status)
		for _, version in ipairs({ "1.9.0", "2.0.10", "3.0.0", "unknown" }) do
			info.version = version
			json(info)
			assert.equals("incompatible_response", invoke("info").err.code)
		end
	end)

	it("encodes location keys and UTF-8 bytes once, without ambient directory headers", function()
		json({ location = { directory = "/tmp/путь %#" }, data = {} })
		local result = invoke("agent_list", { query = { location = { directory = "/tmp/путь %#" } } })
		assert.is_nil(result.err)
		assert.equals("/tmp/путь %#", result.meta.location.directory)
		assert.equals("/api/agent?location%5Bdirectory%5D=%2Ftmp%2F%D0%BF%D1%83%D1%82%D1%8C%20%25%23", requests[1].path)
		assert.is_nil(requests[1].headers["x-opencode-directory"])
	end)

	it("preserves page cursors, false, JSON null, and empty lists", function()
		json({ data = {}, cursor = { previous = vim.NIL, next = "opaque+/%" } })
		local result = invoke("session_list", { query = { parentID = "null", resume = false } })
		assert.is_nil(result.err)
		assert.same({}, result.data)
		assert.equals(vim.NIL, result.meta.cursor.previous)
		assert.equals("opaque+/%", result.meta.cursor.next)
		assert.equals("/api/session?parentID=null&resume=false", requests[1].path)
		invoke("session_list", { query = { cursor = result.meta.cursor.next, parentID = vim.NIL } })
		assert.equals("/api/session?cursor=opaque%2B%2F%25&parentID=null", requests[2].path)
		json({ location = { directory = "/project" }, data = vim.NIL })
		assert.equals(vim.NIL, invoke("model_default").data)
		json({ location = { directory = "/project" } })
		assert.equals("incompatible_response", invoke("model_default").err.code)
	end)

	it("keeps session DTO fields and normalizes location without modifying the input", function()
		local session = { id = "ses_1", location = { directory = "/project" }, metadata = { marker = false } }
		local original = vim.deepcopy(session)
		local normalized, err = v2.session(session)
		assert.is_nil(err)
		assert.equals("/project", normalized.directory)
		assert.equals(false, normalized.metadata.marker)
		assert.same(original, session)
		json({ data = session })
		local result = invoke("session_create", { body = { location = session.location } })
		assert.is_nil(result.err)
		assert.same(normalized, result.data)
		assert.same({ location = session.location }, vim.json.decode(requests[1].body))
		invoke("session_get", { path = { sessionID = "ses_a/#%" } })
		assert.equals("/api/session/ses_a%2F%23%25", requests[2].path)
	end)

	it("accepts 204 exactly once and sends empty objects as objects", function()
		response = { status = 204, headers = {}, body = "" }
		assert.is_true(invoke("session_delete", { path = { sessionID = "ses_1" } }).data)
		json({ data = { id = "ses_1", location = { directory = "/project" } } })
		invoke("session_create")
		assert.equals("{}", requests[2].body)
	end)

	it("rejects malformed envelopes and response media rather than returning empty success", function()
		for _, body in ipairs({ {}, { data = false }, { data = vim.NIL }, { data = {}, cursor = false } }) do
			json(body)
			assert.equals("incompatible_response", invoke("session_list").err.code)
		end
		response = { status = 200, headers = { ["content-type"] = "text/html" }, body = "<html>bad</html>" }
		assert.equals("invalid_content_type", invoke("info").err.code)
		response = { status = 200, headers = { ["content-type"] = "application/json" }, body = "{" }
		assert.equals("invalid_json", invoke("info").err.code)
	end)

	it("preserves domain errors and gives readable HTML/transport errors without fallback", function()
		for _, status in ipairs({ 401, 404, 500 }) do
			json({ _tag = "SessionNotFoundError", message = "Missing session test-password" }, status)
			local result = invoke("session_get", { path = { sessionID = "ses_missing" } })
			assert.equals(status, result.err.status)
			assert.equals("SessionNotFoundError", result.err.code)
			assert.equals("Missing session [redacted]", result.err.message)
			assert.equals(status == 500, result.err.retryable)
		end
		assert.equals(3, #requests)
		json({ _tag = "CommandNotFoundError", message = "No such command" }, 404)
		assert.equals("CommandNotFoundError", invoke("command", { path = { sessionID = "s" } }).err.code)
		response = { status = 502, headers = {}, body = "<html>test-password</html>" }
		assert.equals("HTTP 502", invoke("info").err.message)
		transport_error = { message = "Connection reset" }
		assert.equals("Connection reset", invoke("info").err.message)
	end)
	it("routes permission creation and official plugin RPC with typed failures", function()
		local request = { action = "neovim_edit", resources = { "/tmp/a" }, source = { type = "tool", messageID = "m", id = "call" } }
		json({ data = { id = "p", effect = "ask" } })
		assert.equals("ask", invoke("permission_create", { path = { sessionID = "s" }, body = request }).data.effect)
		assert.equals("/api/session/s/permission", requests[1].path)
		assert.same(request, vim.json.decode(requests[1].body))
		json({ data = { id = "p", effect = "unknown" } })
		assert.equals("incompatible_response", invoke("permission_create", { path = { sessionID = "s" }, body = request }).err.code)
		json({ output = { protocolVersion = 1 } })
		local args = { path = { rpcID = "opencode_nvim", method = "reviewGet" }, body = { input = { sessionID = "s", reviewID = "r" } } }
		assert.equals(1, invoke("rpc_call", args).data.protocolVersion)
		assert.equals("/api/rpc/opencode_nvim/reviewGet", requests[3].path)
		json({ _tag = "RpcError", type = "not_found", message = "Review not found" }, 400)
		assert.equals("not_found", invoke("rpc_call", args).err.rpc_type)
		json({})
		assert.equals("incompatible_response", invoke("rpc_call", args).err.code)
	end)

	it("uses the experimental MCP mutations with frozen location and rejects missing methods", function()
		for _, name in ipairs({ "mcp_connect", "mcp_disconnect" }) do
			response = { status = 204, headers = {}, body = "" }
			local args = { path = { server = "srv /%" }, query = { location = { directory = "/project one" } } }
			assert.is_true(invoke(name, args).data)
			local endpoint = name == "mcp_connect" and "connect" or "disconnect"
			assert.equals("/api/experimental/mcp/srv%20%2F%25/" .. endpoint .. "?location%5Bdirectory%5D=%2Fproject%20one", requests[#requests].path)
			json({ _tag = "NotFoundError", message = "Unavailable" }, 404)
			assert.equals(404, invoke(name, args).err.status)
		end
	end)

	it("generates transient session text through the JSON endpoint without a request timeout", function()
		json({ data = { text = "A concise answer" } })
		local answer
		require("opencode.client").generate_text("ses_1", "What changed?", function(err, text)
			assert.is_nil(err)
			answer = text
		end)
		assert.equals("A concise answer", answer)
		assert.equals("POST", requests[1].method)
		assert.equals("/api/session/ses_1/generate", requests[1].path)
		assert.same({ prompt = "What changed?" }, vim.json.decode(requests[1].body))
		assert.equals(0, requests[1].timeout)
		for _, body in ipairs({ {}, { data = {} }, { data = { text = 123 } } }) do
			json(body)
			assert.equals("incompatible_response", invoke("generate", {
				path = { sessionID = "ses_1" }, body = { prompt = "test" },
			}).err.code)
		end
	end)

	it("generates stateless completion with a separate model and returns the cancellation handle", function()
		json({ data = { text = "class Widget:\n    pass" } })
		local model = { providerID = "fast-provider", id = "code/model", variant = "completion" }
		local answer
		local handle = require("opencode.client").generate_completion("Complete at cursor", model, function(err, value)
			assert.is_nil(err)
			answer = value
		end, { timeout = 1500 })
		assert.equals(request_handle, handle)
		assert.equals("class Widget:\n    pass", answer)
		assert.equals(1, #requests)
		assert.equals("POST", requests[1].method)
		assert.equals("/api/experimental/generate", requests[1].path)
		assert.same({ prompt = "Complete at cursor", model = model }, vim.json.decode(requests[1].body))
		assert.equals(1500, requests[1].timeout)
		assert.truthy(requests[1].headers.Authorization)
		require("opencode.client").generate_completion("Use default model", nil, function() end, { timeout = 0 })
		assert.same({ prompt = "Use default model" }, vim.json.decode(requests[2].body))
		assert.equals(0, requests[2].timeout)
	end)

	it("sends explanation through sessionless generate without tools or chat fields", function()
		json({ data = { text = "L4–6 — Handles the input." } })
		local model = { providerID = "explain-provider", id = "explain-model", variant = "private-explanation" }
		local answer
		local handle = require("opencode.client").generate_explanation("Explain selected lines", model,
			function(err, value)
				assert.is_nil(err)
				answer = value
			end, { timeout = 60000 })
		assert.equals(request_handle, handle)
		assert.equals("L4–6 — Handles the input.", answer)
		assert.equals("POST", requests[1].method)
		assert.equals("/api/experimental/generate", requests[1].path)
		assert.same({ prompt = "Explain selected lines", model = model }, vim.json.decode(requests[1].body))
		assert.equals(60000, requests[1].timeout)
	end)

	it("preserves completion cancellation and rejects malformed generated text", function()
		transport_error = { code = "cancelled", cancelled = true, retryable = false, message = "Request cancelled" }
		local result = invoke("completion", { body = { prompt = "code" } })
		assert.equals(transport_error, result.err)
		assert.is_nil(result.data)
		transport_error = nil
		for _, body in ipairs({ {}, { data = {} }, { data = { text = 123 } } }) do
			json(body)
			assert.equals("incompatible_response", invoke("completion", { body = { prompt = "code" } }).err.code)
		end
	end)

	it("uses integration method and attempt IDs, validates status, and routes individual credentials", function()
		local path = { integrationID = "integration/#", attemptID = "attempt/%" }
		local location = { directory = "/original project" }
		local time = { created = 100, expires = 200 }
		json({ location = location, data = { attemptID = "attempt/%", time = time, url = "https://example.invalid", instructions = "test", mode = "code" } })
		assert.is_nil(invoke("integration_oauth_start", { path = path, body = { methodID = "stable-method" }, query = { location = location } }).err)
		assert.equals("/api/integration/integration%2F%23/connect/oauth?location%5Bdirectory%5D=%2Foriginal%20project", requests[1].path)
		assert.same({ methodID = "stable-method" }, vim.json.decode(requests[1].body))
		json({ location = location, data = { status = "pending", time = time } })
		assert.equals("pending", invoke("integration_oauth_status", { path = path }).data.status)
		assert.equals("/api/integration/integration%2F%23/connect/oauth/attempt%2F%25", requests[2].path)
		json({ location = location, data = { status = "unknown", time = time } })
		assert.equals("incompatible_response", invoke("integration_command_status", { path = path }).err.code)
		response = { status = 204, headers = {}, body = "" }
		for _, operation in ipairs({ "integration_key", "integration_oauth_complete", "integration_oauth_cancel", "integration_command_cancel" }) do
			assert.is_nil(invoke(operation, { path = path }).err)
		end
		for _, operation in ipairs({ "credential_remove", "credential_update", "credential_activate" }) do
			assert.is_nil(invoke(operation, { path = { credentialID = "account/1" } }).err)
			assert.truthy(requests[#requests].path:find("/api/credential/account%%2F1"))
			json({ message = "missing" }, 404)
			assert.equals(404, invoke(operation, { path = { credentialID = "missing" } }).err.status)
			response = { status = 204, headers = {}, body = "" }
		end
	end)

end)
