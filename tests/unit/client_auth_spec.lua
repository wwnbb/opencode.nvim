-- Unit checks for HTTP and SSE Basic authentication behavior.
-- Run with: ./tests/run.sh tests/unit/client_auth_spec.lua

local AUTH_ERROR = "Failed to encode Basic authentication credentials: no Base64 encoder succeeded"
local MODULE_NAMES = {
	"opencode.client",
	"opencode.client.auth",
	"opencode.client.http",
	"opencode.client.sse",
	"opencode.client.transport",
}

describe("opencode client Basic auth", function()
	local original_modules
	local original_schedule
	local request_calls
	local stream_calls
	local open_stream_handler

	before_each(function()
		original_modules = {}
		for _, name in ipairs(MODULE_NAMES) do
			original_modules[name] = package.loaded[name]
		end
		original_schedule = vim.schedule

		request_calls = {}
		stream_calls = {}
		open_stream_handler = nil

		package.loaded["opencode.client"] = nil
		package.loaded["opencode.client.auth"] = nil
		package.loaded["opencode.client.http"] = nil
		package.loaded["opencode.client.sse"] = nil
		package.loaded["opencode.client.transport"] = {
			request = function(opts, callback)
				table.insert(request_calls, opts)
				callback(nil, { status = 204, headers = {}, body = "" })
			end,
			open_stream = function(opts)
				table.insert(stream_calls, opts)
				if open_stream_handler then
					return open_stream_handler(opts)
				end
				return { close = function() end }, nil
			end,
		}

		vim.schedule = function(callback)
			callback()
		end
	end)

	after_each(function()
		local sse = package.loaded["opencode.client.sse"]
		if sse then
			pcall(sse.disconnect)
			pcall(sse.clear_listeners)
		end

		vim.schedule = original_schedule
		for _, name in ipairs(MODULE_NAMES) do
			package.loaded[name] = original_modules[name]
		end
	end)

	local function stub_auth(header, err)
		package.loaded["opencode.client.auth"] = {
			header = function()
				return header, err
			end,
		}
	end

	local function setup_http(password)
		local http = require("opencode.client.http")
		http.setup({
			host = "localhost",
			port = 4096,
			auth = { username = "alice", password = password },
		})
		return http
	end

	it("overrides default HTTP headers without regard to their spelling case", function()
		stub_auth("Basic default")
		local http = setup_http("test-secret")
		local extra = { authorization = "Bearer custom", ["content-type"] = "custom/type", ACCEPT = "custom/accept" }
		http.get("/test", function() end, { headers = extra })
		assert.same({ Authorization = "Bearer custom", ["Content-Type"] = "custom/type", Accept = "custom/accept" }, request_calls[1].headers)
		assert.same({ authorization = "Bearer custom", ["content-type"] = "custom/type", ACCEPT = "custom/accept" }, extra)
	end)

	it("reports malformed and ambiguous HTTP headers through the callback", function()
		stub_auth(nil)
		local http = setup_http(nil)
		for _, headers in ipairs({ "not a table", { [1] = "value" }, { Authorization = "one", authorization = "two" } }) do
			local received
			http.get("/test", function(err) received = err end, { headers = headers })
			assert.is_table(received)
			assert.is_string(received.message)
			assert.same({}, request_calls)
		end
	end)

	it("requires an exact JSON media type or a structured JSON suffix", function()
		stub_auth(nil)
		local http = setup_http(nil)
		local cases = {
			{ "application/json", true }, { "Application/JSON; charset=utf-8", true },
			{ "application/vnd.vendor+json", true }, { "application/vnd_custom+json ; charset=utf-8", true },
			{ "application/json-seq", false }, { "application/jsonp", false },
			{ "application/notjson", false }, { "application/json extra", false }, { "text/json", false },
		}
		for _, case in ipairs(cases) do
			package.loaded["opencode.client.transport"].request = function(_, callback)
				callback(nil, { status = 200, headers = { ["content-type"] = case[1] }, body = "{}" })
			end
			local received, result, completions = nil, nil, 0
			http.get("/test", function(err, body)
				received, result, completions = err, body, completions + 1
			end)
			assert.equals(1, completions)
			if case[2] then assert.is_nil(received); assert.is_table(result)
			else assert.equals("invalid_content_type", received and received.code); assert.is_nil(result) end
		end
	end)

	local function setup_client(password)
		local client = require("opencode.client")
		client.setup({
			host = "localhost",
			port = 4096,
			auth = { username = "alice", password = password },
			reconnect = true,
			reconnect_delay = 60000,
		})
		return client
	end

	it("uses modern encoding first and safely falls back or fails", function()
		local auth = require("opencode.client.auth")
		local legacy_calls = 0

		local header, err = auth.header("alice", "secret", {
			modern = function(value)
				assert.equals("alice:secret", value, "modern encoder input")
				return "YWxpY2U6c2VjcmV0"
			end,
			legacy = function()
				legacy_calls = legacy_calls + 1
				return "legacy"
			end,
		})
		assert.equals("Basic YWxpY2U6c2VjcmV0", header, "modern header")
		assert.equals(nil, err, "modern error")
		assert.equals(0, legacy_calls, "modern precedence")

		header, err = auth.header("alice", "secret", {
			modern = function()
				error("modern failure")
			end,
			legacy = function(value)
				assert.equals("alice:secret", value, "legacy encoder input")
				return "YWxpY2U6c2VjcmV0"
			end,
		})
		assert.equals("Basic YWxpY2U6c2VjcmV0", header, "legacy header")
		assert.equals(nil, err, "legacy error")

		header, err = auth.header("alice", "secret", {})
		assert.equals(nil, header, "unavailable encoder header")
		assert.equals(AUTH_ERROR, err, "unavailable encoder error")

		local ok, failed_header, failed_err = pcall(auth.header, "alice", "secret", {
			modern = function()
				error("modern failure")
			end,
			legacy = function()
				error("E117: Unknown function: base64encode")
			end,
		})
		assert.is_truthy(ok, "throwing encoders should not escape")
		assert.equals(nil, failed_header, "throwing encoder header")
		assert.equals(AUTH_ERROR, failed_err, "throwing encoder error")

		local encoder_calls = 0
		header, err = auth.header("alice", nil, {
			modern = function()
				encoder_calls = encoder_calls + 1
			end,
			legacy = function()
				encoder_calls = encoder_calls + 1
			end,
		})
		assert.equals(nil, header, "passwordless header")
		assert.equals(nil, err, "passwordless error")
		assert.equals(0, encoder_calls, "passwordless encoder calls")
	end)

	it("preserves passwordless HTTP and SSE and applies generated HTTP auth", function()
		package.loaded["opencode.client.auth"] = {
			header = function(_, password)
				if not password then
					return nil, nil
				end
				return "Basic encoded", nil
			end,
		}

		local callback_count = 0
		local http = setup_http(nil)
		http.get("/test", function()
			callback_count = callback_count + 1
		end)

		local client = setup_client(nil)
		assert.equals(true, client.connect_events(), "passwordless SSE result")

		http.setup({ auth = { username = "alice", password = "secret" } })
		http.get("/authenticated", function()
			callback_count = callback_count + 1
		end)

		assert.equals(2, #request_calls, "HTTP request count")
		assert.equals(nil, request_calls[1].headers.Authorization, "passwordless HTTP header")
		assert.equals("Basic encoded", request_calls[2].headers.Authorization, "authenticated HTTP header")
		assert.equals(2, callback_count, "HTTP callback count")
		assert.equals(1, #stream_calls, "passwordless SSE stream count")
		assert.equals(nil, stream_calls[1].headers.Authorization, "passwordless SSE header")
	end)

	it("schedules one HTTP auth error and never calls transport", function()
		stub_auth(nil, AUTH_ERROR)
		local scheduled = {}
		vim.schedule = function(callback)
			table.insert(scheduled, callback)
		end

		local callback_count = 0
		local callback_err
		local callback_data
		local ok, thrown = pcall(function()
			setup_http("secret").get("/test", function(err, data)
				callback_count = callback_count + 1
				callback_err = err
				callback_data = data
			end)
		end)

		assert.is_truthy(ok, "HTTP auth failure threw: " .. tostring(thrown))
		assert.equals(0, #request_calls, "HTTP transport calls")
		assert.equals(1, #scheduled, "scheduled callback count")
		assert.equals(0, callback_count, "callback should be deferred")

		scheduled[1]()
		assert.equals(1, callback_count, "HTTP callback count")
		assert.equals(nil, callback_data, "HTTP callback data")
		assert.equals(AUTH_ERROR, callback_err.error, "HTTP error field")
		assert.equals(AUTH_ERROR, callback_err.message, "HTTP message field")
	end)

	it("clears old credentials when configuring a passwordless server", function()
		local http = setup_http("old-test-secret")
		http.get("/authenticated", function() end)
		assert.is_string(request_calls[1].headers.Authorization)
		http.setup({ port = 4999, auth = { username = "alice" } })
		http.get("/passwordless", function() end)
		assert.is_nil(request_calls[2].headers.Authorization)

		local client = setup_client("old-test-secret")
		assert.is_true(client.connect_events())
		assert.is_string(stream_calls[1].headers.Authorization)
		client.disconnect_events()
		client.setup({ host = "localhost", port = 4999, reconnect = false })
		assert.is_true(client.connect_events())
		assert.is_nil(stream_calls[2].headers.Authorization)
	end)

	it("keeps auth on unrelated updates and uses the default username for new credentials", function()
		local http = setup_http("old-test-secret")
		http.get("/initial", function() end)
		http.setup({ timeout = 10 })
		http.get("/retained", function() end)
		assert.equals(request_calls[1].headers.Authorization, request_calls[2].headers.Authorization)
		local credentials = { password = "new-test-secret" }
		http.setup({ auth = credentials })
		credentials.password = "changed-after-setup"
		http.get("/new", function() end)
		assert.equals(require("opencode.client.auth").header("opencode", "new-test-secret"), request_calls[3].headers.Authorization)
	end)

	it("redacts errors using the credentials of the original request", function()
		local http = setup_http("old-test-secret")
		local reply, captured
		package.loaded["opencode.client.transport"].request = function(_, callback) reply = callback end
		http.get("/pending", function(err) captured = err end)
		http.setup({ auth = { username = "opencode", password = "new-test-secret" } })
		reply(nil, { status = 401, headers = {}, body = vim.json.encode({ message = "Rejected old-test-secret" }) })
		assert.equals("Rejected [redacted]", captured.message)
	end)

	it("returns true after assigning or reusing an SSE stream", function()
		stub_auth("Basic encoded", nil)
		local client = setup_client("secret")

		assert.equals(true, client.connect_events(), "initial SSE result")
		assert.equals(true, client.connect_events(), "existing SSE result")
		assert.equals(1, #stream_calls, "SSE stream calls")
		assert.equals("Basic encoded", stream_calls[1].headers.Authorization, "SSE Authorization header")
		assert.is_truthy(client.sse.status().has_stream, "SSE stream state")
	end)

	it("returns fatal SSE auth failure without a stream or reconnect", function()
		stub_auth(nil, AUTH_ERROR)
		local client = setup_client("secret")
		local errors = {}
		client.on_event("error", function(message)
			table.insert(errors, message)
		end)

		local connected, err = client.connect_events()
		assert.equals(false, connected, "SSE auth result")
		assert.equals(AUTH_ERROR, err, "SSE auth error")
		assert.equals(1, #errors, "SSE auth error emissions")
		assert.equals(AUTH_ERROR, errors[1], "SSE emitted auth error")
		assert.equals(0, #stream_calls, "SSE auth stream calls")

		local status = client.sse.status()
		assert.equals(false, status.connected, "SSE auth connected state")
		assert.equals(false, status.has_stream, "SSE auth stream state")
		assert.equals(0, status.reconnect_count, "SSE auth reconnect count")
	end)

	it("returns synchronous SSE stream-open failure after scheduling reconnect", function()
		stub_auth("Basic encoded", nil)
		open_stream_handler = function()
			return nil, { message = "dial failed" }
		end

		local client = setup_client("secret")
		local errors = {}
		client.on_event("error", function(message)
			table.insert(errors, message)
		end)

		local connected, err = client.connect_events()
		assert.equals(false, connected, "SSE open result")
		assert.equals("dial failed", err, "SSE open error")
		assert.equals(1, #errors, "SSE open error emissions")
		assert.equals("dial failed", errors[1], "SSE emitted open error")
		assert.equals(1, #stream_calls, "SSE open calls")

		local status = client.sse.status()
		assert.equals(false, status.connected, "SSE open connected state")
		assert.equals(false, status.has_stream, "SSE open stream state")
		assert.equals(1, status.reconnect_count, "SSE open reconnect count")
	end)

	it("resets SSE reconnect_count on disconnect", function()
		stub_auth("Basic encoded", nil)
		open_stream_handler = function()
			return nil, { message = "dial failed" }
		end

		local client = setup_client("secret")
		client.connect_events()
		assert.equals(1, client.sse.status().reconnect_count, "failed open increments reconnect")

		client.disconnect_events()
		assert.equals(0, client.sse.status().reconnect_count, "disconnect resets reconnect")
	end)

	it("emits an error when SSE reconnect gives up", function()
		stub_auth("Basic encoded", nil)
		open_stream_handler = function()
			return nil, { message = "dial failed" }
		end

		local client = require("opencode.client")
		client.setup({
			host = "localhost",
			port = 4096,
			auth = { username = "alice", password = "secret" },
			reconnect = true,
			reconnect_delay = 60000,
			max_reconnects = 0,
		})
		local errors = {}
		client.on_event("error", function(message)
			table.insert(errors, message)
		end)

		client.connect_events()
		local found = false
		for _, message in ipairs(errors) do
			if tostring(message):find("gave up", 1, true) then
				found = true
			end
		end
		assert.is_truthy(found, "give-up error")
	end)

	it("ignores a stale SSE close after a newer stream is connected", function()
		stub_auth("Basic encoded", nil)
		local client = setup_client("secret")

		assert.equals(true, client.connect_events(), "first stream")
		local first_on_close = stream_calls[1].on_close
		client.disconnect_events()
		assert.equals(true, client.connect_events(), "second stream")
		assert.equals(2, #stream_calls, "second stream opened")

		first_on_close("stale close")
		assert.is_truthy(client.sse.status().has_stream, "new stream survives stale close")
	end)
end)
