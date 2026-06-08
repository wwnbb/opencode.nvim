-- opencode.nvim - HTTP transport facade over shared TCP and decoder helpers

local M = {}

local http_decoder = require("opencode.client.http_decoder")
local schedule_callback = require("opencode.util.schedule").schedule_callback
local tcp_connection = require("opencode.client.tcp_connection")

local make_error = tcp_connection.make_error

---@param opts table
---@return string
local function build_request(opts)
	local method = (opts.method or "GET"):upper()
	local path = opts.path or "/"
	if path == "" then
		path = "/"
	end
	if path:sub(1, 1) ~= "/" then
		path = "/" .. path
	end

	local headers = vim.tbl_extend("force", {}, opts.headers or {})
	if not headers.Host and not headers.host then
		local host_value = tostring(opts.host)
		if host_value:find(":", 1, true) and not host_value:match("^%[.+%]$") then
			host_value = "[" .. host_value .. "]"
		end
		headers.Host = string.format("%s:%d", host_value, opts.port)
	end
	if not headers.Connection and not headers.connection then
		headers.Connection = opts.connection or "close"
	end
	if opts.body ~= nil and not headers["Content-Length"] and not headers["content-length"] then
		headers["Content-Length"] = tostring(#opts.body)
	end

	local lines = { string.format("%s %s HTTP/1.1", method, path) }
	for key, value in pairs(headers) do
		table.insert(lines, string.format("%s: %s", key, tostring(value)))
	end
	table.insert(lines, "")
	table.insert(lines, opts.body or "")

	return table.concat(lines, "\r\n")
end

---@param opts table
---@param callback function
function M.request(opts, callback)
	opts = opts or {}
	local host, port, target_err = tcp_connection.normalize_target(opts)
	if target_err then
		schedule_callback(callback, target_err, nil)
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
			return
		end
		done = true

		if connection then
			connection.close()
			connection = nil
		end

		schedule_callback(callback, err, result)
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

	local request_data = build_request(vim.tbl_extend("force", {}, opts, {
		host = host,
		port = port,
	}))

	local open_err = nil
	connection, open_err = tcp_connection.open({
		host = host,
		port = port,
		data = request_data,
		timeout = opts.timeout,
		timeout_message = "Request timed out after " .. tostring(tonumber(opts.timeout) or 0) .. "ms",
		labels = {
			connect = "Connect failed",
			create_socket = "Failed to create TCP socket",
			read_start = "Failed to start read",
			write_start = "Failed to write request",
			write = "Write failed",
		},
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
	end
end

---@param opts table
---@return table|nil stream
---@return table|nil err
function M.open_stream(opts)
	opts = opts or {}
	local host, port, target_err = tcp_connection.normalize_target(opts)
	if target_err then
		return nil, target_err
	end

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

	local request_data = build_request(vim.tbl_extend("force", {}, opts, {
		host = host,
		port = port,
		connection = opts.connection or "keep-alive",
	}))

	local open_err = nil
	connection, open_err = tcp_connection.open({
		host = host,
		port = port,
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
