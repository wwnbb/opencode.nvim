-- Unit checks for shared TCP lifecycle and HTTP body decoding.
-- Run with: ./tests/run.sh unit

describe("opencode transport", function()
	it("handles shared TCP lifecycle and HTTP bodies", function()
vim.opt.runtimepath:append(vim.fn.getcwd())

local uv = vim.uv
local transport = require("opencode.client.transport")

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

local function wait_until(predicate, message)
	assert_true(vim.wait(2000, predicate, 10), message)
end

local function safe_close(handle)
	if not handle then
		return
	end
	local ok, closing = pcall(uv.is_closing, handle)
	if ok and closing then
		return
	end
	pcall(function()
		uv.close(handle)
	end)
end

local function close_stream(stream)
	if not stream then
		return
	end
	local ok, closing = pcall(uv.is_closing, stream)
	if ok and closing then
		return
	end
	local shutdown_ok, req = pcall(function()
		return stream:shutdown(function()
			safe_close(stream)
		end)
	end)
	if not shutdown_ok or req == nil then
		safe_close(stream)
	end
end

local function write_sequence(client, chunks, close_after)
	local index = 1

	local function write_next()
		local chunk = chunks[index]
		if not chunk then
			if close_after then
				close_stream(client)
			end
			return
		end

		index = index + 1
		client:write(chunk, function(write_err)
			if write_err then
				close_stream(client)
				return
			end

			local timer = uv.new_timer()
			timer:start(10, 0, function()
				safe_close(timer)
				write_next()
			end)
		end)
	end

	write_next()
end

local function start_server(chunks, close_after)
	local server = assert(uv.new_tcp())
	assert(server:bind("127.0.0.1", 0))
	local address = assert(server:getsockname())
	local clients = {}
	local requests, closed_clients = 0, 0

	assert(server:listen(16, function(listen_err)
		assert(not listen_err, listen_err)

		local client = assert(uv.new_tcp())
		table.insert(clients, client)
		assert(server:accept(client))

		local request_buffer = ""
		local received = false
		client:read_start(function(read_err, data)
			-- Cancelling with an unread response may reset instead of gracefully closing.
			if read_err == "ECONNRESET" or not data then
				closed_clients = closed_clients + 1
				client:read_stop()
				return
			end
			assert(not read_err, read_err)
			if received then return end

			request_buffer = request_buffer .. data
			if request_buffer:find("\r\n\r\n", 1, true) then
				received = true
				requests = requests + 1
				write_sequence(client, chunks, close_after)
			end
		end)
	end))

	return {
		port = address.port,
		requests = function() return requests end,
		closed_clients = function() return closed_clients end,
		close = function()
			for _, client in ipairs(clients) do
				close_stream(client)
			end
			safe_close(server)
		end,
	}
end

local function run_request(chunks, close_after)
	local server = start_server(chunks, close_after)
	local done = false
	local result_err = nil
	local result_response = nil

	transport.request({
		host = "127.0.0.1",
		port = server.port,
		method = "GET",
		path = "/test",
		timeout = 1000,
	}, function(err, response)
		result_err = err
		result_response = response
		done = true
	end)

	wait_until(function()
		return done
	end, "request callback did not run")

	server.close()
	return result_err, result_response
end

do
	local err, response = run_request({
		"HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\nhe",
		"llo ",
		"world",
	}, false)

	assert_eq(err, nil, "content-length request should not error")
	assert_eq(response.status, 200, "content-length status")
	assert_eq(response.body, "hello world", "content-length body")
end

do
	local err, response = run_request({
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhel",
		"lo\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: ok\r\n\r\n",
	}, false)

	assert_eq(err, nil, "chunked request should not error")
	assert_eq(response.status, 200, "chunked status")
	assert_eq(response.body, "hello world", "chunked body")
end

do
	local err, response = run_request({
		"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\nclose-body",
	}, true)

	assert_eq(err, nil, "close-delimited request should not error")
	assert_eq(response.status, 200, "close-delimited status")
	assert_eq(response.body, "close-body", "close-delimited body")
end

do
	local err, response = run_request({
		"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nZ\r\n",
	}, false)

	assert_true(err ~= nil, "invalid chunk request should error")
	assert_true((err.message or err.error or ""):find("chunked", 1, true) ~= nil, "invalid chunk error should mention chunked")
	assert_eq(response, nil, "invalid chunk response")
end

do
	local server = start_server({
		"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\npartial",
		"late bytes",
	}, false)
	local callbacks, result_err, result_response = 0, nil, nil
	local request = transport.request({
		host = "127.0.0.1", port = server.port, path = "/completion", timeout = 100,
	}, function(err, response)
		callbacks = callbacks + 1
		result_err, result_response = err, response
	end)
	assert_true(request.is_active(), "new request should be active")
	wait_until(function() return server.requests() == 1 end, "server did not receive completion")
	assert_true(request.cancel(), "first cancellation should finish the request")
	assert_eq(request.cancel(), false, "repeat cancellation is a no-op")
	assert_eq(request.is_active(), false, "cancelled request should be inactive")
	wait_until(function() return callbacks == 1 and server.closed_clients() == 1 end, "cancellation should close the TCP socket")
	vim.wait(150, function() return callbacks > 1 end, 10)
	assert_eq(callbacks, 1, "late response and original timeout must not call back again")
	assert_eq(result_err.code, "cancelled", "structured cancellation error")
	assert_eq(result_err.cancelled, true, "cancellation marker")
	assert_eq(result_err.retryable, false, "cancellation should not trigger retry")
	assert_eq(result_response, nil, "cancelled response")
	server.close()
end

do
	local server = start_server({}, false)
	local callbacks, result_err = 0, nil
	local request = transport.request({
		host = "127.0.0.1", port = server.port, path = "/completion", timeout = 40,
	}, function(err)
		callbacks = callbacks + 1
		result_err = err
	end)
	wait_until(function() return callbacks == 1 and server.closed_clients() == 1 end, "request timeout should close the socket")
	assert_eq(result_err.timeout, true, "request timeout marker")
	assert_eq(request.is_active(), false, "timed out request should be inactive")
	assert_eq(request.cancel(), false, "cancellation after timeout is a no-op")
	assert_eq(callbacks, 1, "timeout callback should run once")
	server.close()
end

do
	local payload_a = "event: message\n"
	local payload_b = "data: {\"ok\":true}\n\n"
	local frame_a = string.format("%X\r\n%s\r\n", #payload_a, payload_a)
	local frame_b = string.format("%X\r\n%s\r\n", #payload_b, payload_b)
	local server = start_server({
		"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n",
		frame_a:sub(1, 4),
		frame_a:sub(5, 12),
		frame_a:sub(13) .. frame_b:sub(1, 3),
		frame_b:sub(4),
		"0\r\n\r\n",
	}, false)

	local headers_status = nil
	local data_chunks = {}
	local stream_err = nil
	local close_reason = nil

	local stream, err = transport.open_stream({
		host = "127.0.0.1",
		port = server.port,
		method = "GET",
		path = "/events",
		timeout = 1000,
		on_headers = function(status)
			headers_status = status
		end,
		on_data = function(data)
			table.insert(data_chunks, data)
		end,
		on_error = function(received_err)
			stream_err = received_err
		end,
		on_close = function(reason)
			close_reason = reason
		end,
	})

	assert_eq(err, nil, "chunked stream open should not error")
	assert_true(stream ~= nil, "chunked stream should be returned")
	wait_until(function()
		return close_reason ~= nil
	end, "chunked stream should close after terminal chunk")

	assert_eq(stream_err, nil, "chunked stream should not error")
	assert_eq(headers_status, 200, "chunked stream status")
	assert_eq(table.concat(data_chunks), payload_a .. payload_b, "chunked stream data should be decoded SSE payload")
	assert_eq(table.concat(data_chunks):find("\r\n", 1, true), nil, "chunked stream data should not include chunk framing")

	server.close()
end

do
	local server = start_server({}, true)
	local stream_err = nil
	local close_reason = nil

	local stream, err = transport.open_stream({
		host = "127.0.0.1",
		port = server.port,
		method = "GET",
		path = "/events",
		timeout = 1000,
		on_error = function(received_err)
			stream_err = received_err
		end,
		on_close = function(reason)
			close_reason = reason
		end,
	})

	assert_eq(err, nil, "EOF-before-headers stream open should not error synchronously")
	assert_true(stream ~= nil, "EOF-before-headers stream should be returned")
	wait_until(function()
		return close_reason ~= nil
	end, "EOF-before-headers stream should close")

	assert_eq(close_reason, "eof", "EOF-before-headers close reason")
	assert_true(stream_err ~= nil, "EOF-before-headers stream should error")
	assert_true(
		(stream_err.message or stream_err.error or ""):find("Stream closed before response headers", 1, true) ~= nil,
		"EOF-before-headers error message"
	)

	server.close()
end

print("Transport checks passed")
	end)
end)
