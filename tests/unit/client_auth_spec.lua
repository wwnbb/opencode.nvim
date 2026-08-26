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

local function assert_eq(actual, expected, message)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", message, vim.inspect(expected), vim.inspect(actual)))
	end
end

local function assert_true(value, message)
	if not value then
		error(message)
	end
end

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
				assert_eq(value, "alice:secret", "modern encoder input")
				return "YWxpY2U6c2VjcmV0"
			end,
			legacy = function()
				legacy_calls = legacy_calls + 1
				return "legacy"
			end,
		})
		assert_eq(header, "Basic YWxpY2U6c2VjcmV0", "modern header")
		assert_eq(err, nil, "modern error")
		assert_eq(legacy_calls, 0, "modern precedence")

		header, err = auth.header("alice", "secret", {
			modern = function()
				error("modern failure")
			end,
			legacy = function(value)
				assert_eq(value, "alice:secret", "legacy encoder input")
				return "YWxpY2U6c2VjcmV0"
			end,
		})
		assert_eq(header, "Basic YWxpY2U6c2VjcmV0", "legacy header")
		assert_eq(err, nil, "legacy error")

		header, err = auth.header("alice", "secret", {})
		assert_eq(header, nil, "unavailable encoder header")
		assert_eq(err, AUTH_ERROR, "unavailable encoder error")

		local ok, failed_header, failed_err = pcall(auth.header, "alice", "secret", {
			modern = function()
				error("modern failure")
			end,
			legacy = function()
				error("E117: Unknown function: base64encode")
			end,
		})
		assert_true(ok, "throwing encoders should not escape")
		assert_eq(failed_header, nil, "throwing encoder header")
		assert_eq(failed_err, AUTH_ERROR, "throwing encoder error")

		local encoder_calls = 0
		header, err = auth.header("alice", nil, {
			modern = function()
				encoder_calls = encoder_calls + 1
			end,
			legacy = function()
				encoder_calls = encoder_calls + 1
			end,
		})
		assert_eq(header, nil, "passwordless header")
		assert_eq(err, nil, "passwordless error")
		assert_eq(encoder_calls, 0, "passwordless encoder calls")
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
		assert_eq(client.connect_events(), true, "passwordless SSE result")

		http.setup({ auth = { username = "alice", password = "secret" } })
		http.get("/authenticated", function()
			callback_count = callback_count + 1
		end)

		assert_eq(#request_calls, 2, "HTTP request count")
		assert_eq(request_calls[1].headers.Authorization, nil, "passwordless HTTP header")
		assert_eq(request_calls[2].headers.Authorization, "Basic encoded", "authenticated HTTP header")
		assert_eq(callback_count, 2, "HTTP callback count")
		assert_eq(#stream_calls, 1, "passwordless SSE stream count")
		assert_eq(stream_calls[1].headers.Authorization, nil, "passwordless SSE header")
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

		assert_true(ok, "HTTP auth failure threw: " .. tostring(thrown))
		assert_eq(#request_calls, 0, "HTTP transport calls")
		assert_eq(#scheduled, 1, "scheduled callback count")
		assert_eq(callback_count, 0, "callback should be deferred")

		scheduled[1]()
		assert_eq(callback_count, 1, "HTTP callback count")
		assert_eq(callback_data, nil, "HTTP callback data")
		assert_eq(callback_err.error, AUTH_ERROR, "HTTP error field")
		assert_eq(callback_err.message, AUTH_ERROR, "HTTP message field")
	end)

	it("returns true after assigning or reusing an SSE stream", function()
		stub_auth("Basic encoded", nil)
		local client = setup_client("secret")

		assert_eq(client.connect_events(), true, "initial SSE result")
		assert_eq(client.connect_events(), true, "existing SSE result")
		assert_eq(#stream_calls, 1, "SSE stream calls")
		assert_eq(stream_calls[1].headers.Authorization, "Basic encoded", "SSE Authorization header")
		assert_true(client.sse.status().has_stream, "SSE stream state")
	end)

	it("returns fatal SSE auth failure without a stream or reconnect", function()
		stub_auth(nil, AUTH_ERROR)
		local client = setup_client("secret")
		local errors = {}
		client.on_event("error", function(message)
			table.insert(errors, message)
		end)

		local connected, err = client.connect_events()
		assert_eq(connected, false, "SSE auth result")
		assert_eq(err, AUTH_ERROR, "SSE auth error")
		assert_eq(#errors, 1, "SSE auth error emissions")
		assert_eq(errors[1], AUTH_ERROR, "SSE emitted auth error")
		assert_eq(#stream_calls, 0, "SSE auth stream calls")

		local status = client.sse.status()
		assert_eq(status.connected, false, "SSE auth connected state")
		assert_eq(status.has_stream, false, "SSE auth stream state")
		assert_eq(status.reconnect_count, 0, "SSE auth reconnect count")
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
		assert_eq(connected, false, "SSE open result")
		assert_eq(err, "dial failed", "SSE open error")
		assert_eq(#errors, 1, "SSE open error emissions")
		assert_eq(errors[1], "dial failed", "SSE emitted open error")
		assert_eq(#stream_calls, 1, "SSE open calls")

		local status = client.sse.status()
		assert_eq(status.connected, false, "SSE open connected state")
		assert_eq(status.has_stream, false, "SSE open stream state")
		assert_eq(status.reconnect_count, 1, "SSE open reconnect count")
	end)

	it("resets SSE reconnect_count on disconnect", function()
		stub_auth("Basic encoded", nil)
		open_stream_handler = function()
			return nil, { message = "dial failed" }
		end

		local client = setup_client("secret")
		client.connect_events()
		assert_eq(client.sse.status().reconnect_count, 1, "failed open increments reconnect")

		client.disconnect_events()
		assert_eq(client.sse.status().reconnect_count, 0, "disconnect resets reconnect")
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
		assert_true(found, "give-up error")
	end)

	it("ignores a stale SSE close after a newer stream is connected", function()
		stub_auth("Basic encoded", nil)
		local client = setup_client("secret")

		assert_eq(client.connect_events(), true, "first stream")
		local first_on_close = stream_calls[1].on_close
		client.disconnect_events()
		assert_eq(client.connect_events(), true, "second stream")
		assert_eq(#stream_calls, 2, "second stream opened")

		first_on_close("stale close")
		assert_true(client.sse.status().has_stream, "new stream survives stale close")
	end)
end)
