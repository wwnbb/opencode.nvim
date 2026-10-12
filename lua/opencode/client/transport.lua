-- opencode.nvim - HTTP transport facade over shared TCP and decoder helpers

local M = {}

local http_decoder = require("opencode.client.http_decoder")
local schedule_callback = require("opencode.util.schedule").schedule_callback
local tcp_connection = require("opencode.client.tcp_connection")
local endpoint = require("opencode.client.endpoint")

local function target(opts)
	local resolved, err = endpoint.resolve(opts)
	if not resolved then return nil, err end
	if opts.path ~= nil and type(opts.path) ~= "string" then
		return nil, tcp_connection.make_error("Invalid HTTP request path", { code = "invalid_endpoint", retryable = false })
	end
	return vim.tbl_extend("force", {}, opts, { host = resolved.host, port = resolved.port,
		path = endpoint.join(resolved, opts.path or "/"), scheme = resolved.scheme })
end

local function open_connection(opts)
	return (opts.scheme == "https" and require("opencode.client.tls_connection") or tcp_connection).open(opts)
end

local make_error = tcp_connection.make_error
local HTTP_TOKEN = "^[!#$%%&'*+.^_`|~%w-]+$"

---@param opts table
---@return string|nil
---@return string|nil error
local function build_request(opts)
	local method = opts.method or "GET"
	if type(method) ~= "string" or not method:match(HTTP_TOKEN) then return nil, "Invalid HTTP method" end
	method = method:upper()
	local path = opts.path or "/"
	if type(path) ~= "string" or path:find("[%s%z]") then return nil, "Invalid HTTP request path" end
	if opts.body ~= nil and type(opts.body) ~= "string" then return nil, "HTTP body must be a string" end
	if path == "" then
		path = "/"
	end
	if path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end

	local host_value = tostring(opts.host)
	if host_value:find(":", 1, true) and not host_value:match("^%[.+%]$") then
		host_value = "[" .. host_value .. "]"
	end
	local defaults = { Host = string.format("%s:%d", host_value, opts.port), Connection = opts.connection or "close" }
	if opts.body ~= nil then defaults["Content-Length"] = tostring(#opts.body) end
	local headers, headers_err = require("opencode.client.headers").merge(defaults, opts.headers)
	if not headers then return nil, headers_err end

	local lines = { string.format("%s %s HTTP/1.1", method, path) }
	for key, value in pairs(headers) do
		if type(key) ~= "string" or not key:match(HTTP_TOKEN) then return nil, "Invalid HTTP header name" end
		local text = tostring(value)
		if text:find("[\r\n%z]") then return nil, "Invalid HTTP header value: " .. key end
		table.insert(lines, string.format("%s: %s", key, text))
	end
	table.insert(lines, "")
	table.insert(lines, opts.body or "")

	return table.concat(lines, "\r\n")
end

---@param opts table
---@param callback function
---@return table|nil request Handle with idempotent cancel() and is_active().
function M.request(opts, callback)
	opts = opts or {}
	local resolved, target_err = target(opts)
	if target_err then
		schedule_callback(callback, target_err, nil)
		return
	end
	opts = resolved
	local host, port = opts.host, opts.port
	local request_data, request_err = build_request(vim.tbl_extend("force", {}, opts, { host = host, port = port }))
	if not request_data then
		schedule_callback(callback, make_error(request_err), nil)
		return
	end

	local done = false
	local connection = nil
	local body_chunks = {}
	local response = {
		status = 0,
		headers = {},
		body = "",
	}

	local function finish(err, result)
		if done then
			return false
		end
		done = true

		if connection then
			connection.close()
			connection = nil
		end

		schedule_callback(callback, err, result)
		return true
	end

	local request = {}
	function request.cancel()
		return finish(make_error("Request cancelled", { code = "cancelled", cancelled = true, retryable = false }), nil)
	end
	function request.is_active()
		return not done
	end

	local decoder = http_decoder.new({
		method = opts.method,
		on_headers = function(status, headers)
			response.status = status
			response.headers = headers
		end,
		on_body = function(data)
			table.insert(body_chunks, data)
		end,
		on_complete = function()
			response.body = table.concat(body_chunks)
			finish(nil, response)
		end,
		on_error = function(err)
			finish(err, nil)
		end,
	})

	local open_err = nil
	connection, open_err = open_connection({
		host = host,
		port = port,
		scheme = opts.scheme,
		tls = opts.tls,
		data = request_data,
		timeout = opts.timeout,
		timeout_message = "Request timed out after " .. tostring(tonumber(opts.timeout) or 0) .. "ms",
		on_read = function(read_err, data)
			if done then
				return
			end

			if read_err then
				finish(make_error("Read failed: " .. tostring(read_err)), nil)
				return
			end

			if data then
				decoder:push(data)
				return
			end

			if not decoder:headers_parsed() then
				finish(make_error("Connection closed before response headers"), nil)
				return
			end

			decoder:finish_eof()
		end,
		on_error = function(_, err)
			finish(err, nil)
		end,
	})

	if not connection then
		finish(open_err or make_error("Failed to open connection"), nil)
	elseif done then
		-- A synchronous connection failure may finish before open() returns.
		connection.close()
		connection = nil
	end
	return request
end

---@param opts table
---@return table|nil stream
---@return table|nil err
function M.open_stream(opts)
	opts = opts or {}
	local resolved, target_err = target(opts)
	if target_err then
		return nil, target_err
	end
	opts = resolved
	local host, port = opts.host, opts.port
	local request_data, request_err = build_request(vim.tbl_extend("force", {}, opts, {
		host = host, port = port, connection = opts.connection or "keep-alive",
	}))
	if not request_data then return nil, make_error(request_err) end

	local active = true
	local connection = nil

	local function close_stream(reason, err)
		if not active then
			return
		end
		active = false

		if connection then
			connection.close()
			connection = nil
		end

		if err then
			schedule_callback(opts.on_error, err)
		end
		schedule_callback(opts.on_close, reason)
	end

	local decoder = http_decoder.new({
		method = opts.method,
		on_headers = function(status, headers)
			if connection then
				connection.stop_timeout()
			end
			schedule_callback(opts.on_headers, status, headers)
		end,
		on_body = function(data)
			schedule_callback(opts.on_data, data)
		end,
		on_complete = function()
			close_stream("eof", nil)
		end,
		on_error = function(err)
			close_stream("decode_error", err)
		end,
	})

	local open_err = nil
	connection, open_err = open_connection({
		host = host,
		port = port,
		scheme = opts.scheme,
		tls = opts.tls,
		data = request_data,
		timeout = opts.timeout,
		timeout_message = "Stream request timed out after " .. tostring(opts.timeout) .. "ms",
		labels = {
			connect = "Stream connect failed",
			create_socket = "Failed to create TCP socket",
			read_start = "Failed to start stream read",
			write_start = "Failed to start stream write",
			write = "Failed to write stream request",
		},
		on_read = function(read_err, data)
			if not active then
				return
			end

			if read_err then
				close_stream("read_error", make_error("Stream read failed: " .. tostring(read_err)))
				return
			end

			if data then
				decoder:push(data)
				return
			end

			if not decoder:headers_parsed() then
				close_stream("eof", make_error("Stream closed before response headers"))
				return
			end

			decoder:finish_eof()
		end,
		on_error = function(reason, err)
			close_stream(reason, err)
		end,
	})

	if not connection then
		return nil, open_err or make_error("Failed to open stream")
	end

	local stream = {}

	function stream.close()
		close_stream("closed", nil)
	end

	function stream.is_active()
		return active
	end

	return stream, nil
end

return M
