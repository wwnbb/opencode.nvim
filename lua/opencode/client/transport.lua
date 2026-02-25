-- opencode.nvim - libuv transport helpers for HTTP and streaming connections

local M = {}

local uv = vim.uv
local unpack = table.unpack or unpack

---@param callback function|nil
local function schedule(callback, ...)
	if not callback then
		return
	end

	local argc = select("#", ...)
	local args = { ... }
	vim.schedule(function()
		callback(unpack(args, 1, argc))
	end)
end

---@param message string
---@param extras? table
---@return table
local function make_error(message, extras)
	local err = {
		error = message,
		message = message,
	}

	if extras then
		for key, value in pairs(extras) do
			err[key] = value
		end
	end

	return err
end

---@param opts table
---@return string|nil host
---@return integer|nil port
---@return table|nil err
local function normalize_target(opts)
	local host = opts and opts.host
	if type(host) ~= "string" or host == "" then
		return nil, nil, make_error("Host is required")
	end

	local port = tonumber(opts and opts.port)
	if not port then
		return nil, nil, make_error("Port is required")
	end

	if port < 1 or port > 65535 then
		return nil, nil, make_error("Invalid port: " .. tostring(opts and opts.port))
	end

	return host, math.floor(port), nil
end

---@param host string
---@param port integer
---@param callback function
local function resolve_target(host, port, callback)
	local req, req_err = uv.getaddrinfo(host, tostring(port), { socktype = "stream" }, function(err, addresses)
		if err then
			callback(make_error("Failed to resolve host '" .. host .. "': " .. tostring(err)), nil)
			return
		end

		if not addresses or #addresses == 0 then
			callback(make_error("No address found for host '" .. host .. "'"), nil)
			return
		end

		local targets = {}
		for _, address in ipairs(addresses) do
			if address and address.addr then
				table.insert(targets, {
					addr = address.addr,
					port = address.port or port,
				})
			end
		end

		if #targets == 0 then
			callback(make_error("No usable address found for host '" .. host .. "'"), nil)
			return
		end

		callback(nil, targets)
	end)

	if req == nil then
		callback(make_error("Failed to start DNS lookup for '" .. host .. "': " .. tostring(req_err)), nil)
	end
end

---@param handle uv_handle_t|nil
local function safe_close(handle)
	if not handle then
		return
	end

	if uv.is_closing(handle) then
		return
	end

	pcall(function()
		handle:close()
	end)
end

---@param timer uv_timer_t|nil
local function stop_timer(timer)
	if not timer then
		return
	end

	if uv.is_closing(timer) then
		return
	end

	pcall(function()
		timer:stop()
	end)
	pcall(function()
		timer:close()
	end)
end

---@param request_buffer string
---@return table|nil parsed
---@return string|nil remaining
---@return string|nil parse_error
local function parse_headers(request_buffer)
	local header_end = request_buffer:find("\r\n\r\n", 1, true)
	local delimiter_size = 4
	if not header_end then
		header_end = request_buffer:find("\n\n", 1, true)
		delimiter_size = 2
	end

	if not header_end then
		return nil, nil, nil
	end

	local header_blob = request_buffer:sub(1, header_end - 1)
	local remaining = request_buffer:sub(header_end + delimiter_size)
	local lines = {}
	for line in header_blob:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	local status_line = lines[1] or ""
	local status = tonumber(status_line:match("^HTTP/%d+%.%d+%s+(%d%d%d)"))
	if not status then
		return nil, nil, "Invalid HTTP status line: " .. status_line
	end

	local headers = {}
	for i = 2, #lines do
		local key, value = lines[i]:match("^([^:]+):%s*(.*)$")
		if key and value then
			local normalized = key:lower()
			local existing = headers[normalized]
			if existing then
				headers[normalized] = existing .. ", " .. value
			else
				headers[normalized] = value
			end
		end
	end

	return {
		status = status,
		headers = headers,
	}, remaining, nil
end

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
	local host, port, target_err = normalize_target(opts or {})
	if target_err then
		schedule(callback, target_err, nil)
		return
	end

	local socket = nil

	local done = false
	local headers_parsed = false
	local header_buffer = ""
	local timer = nil
	local response = {
		status = 0,
		headers = {},
		body = "",
	}
	local body_mode = "close"
	local expected_length = nil
	local body_bytes = 0
	local body_chunks = {}
	local chunk_buffer = ""
	local chunk_size = nil
	local chunk_done = false

	local function append_body(data)
		if not data or data == "" then
			return
		end
		body_bytes = body_bytes + #data
		table.insert(body_chunks, data)
	end

	local function cleanup()
		stop_timer(timer)
		if socket then
			pcall(function()
				socket:read_stop()
			end)
			safe_close(socket)
			socket = nil
		end
	end

	local function finish(err, result)
		if done then
			return
		end
		done = true
		cleanup()
		schedule(callback, err, result)
	end

	local function complete_response()
		response.body = table.concat(body_chunks)
		finish(nil, response)
	end

	local function decode_chunked()
		while true do
			if chunk_done then
				return true
			end

			if not chunk_size then
				local line_end = chunk_buffer:find("\r\n", 1, true)
				if not line_end then
					return false
				end

				local size_line = chunk_buffer:sub(1, line_end - 1)
				local size_hex = size_line:match("^%s*([0-9a-fA-F]+)")
				local parsed_size = size_hex and tonumber(size_hex, 16) or nil
				if not parsed_size then
					return nil, "Invalid chunk size"
				end

				chunk_size = parsed_size
				chunk_buffer = chunk_buffer:sub(line_end + 2)

				if chunk_size == 0 then
					local trailer_end = chunk_buffer:find("\r\n\r\n", 1, true)
					if trailer_end then
						chunk_buffer = chunk_buffer:sub(trailer_end + 4)
						chunk_done = true
						return true
					end
					if chunk_buffer:sub(1, 2) == "\r\n" then
						chunk_buffer = chunk_buffer:sub(3)
						chunk_done = true
						return true
					end
					return false
				end
			end

			local needed = chunk_size + 2
			if #chunk_buffer < needed then
				return false
			end

			local chunk = chunk_buffer:sub(1, chunk_size)
			local terminator = chunk_buffer:sub(chunk_size + 1, chunk_size + 2)
			if terminator ~= "\r\n" then
				return nil, "Invalid chunk terminator"
			end

			append_body(chunk)
			chunk_buffer = chunk_buffer:sub(needed + 1)
			chunk_size = nil
		end
	end

	local function process_body(data)
		if done or not data or data == "" then
			return
		end

		if body_mode == "none" then
			return
		end

		if body_mode == "length" then
			local remaining = (expected_length or 0) - body_bytes
			if remaining <= 0 then
				return
			end

			local body_piece = #data > remaining and data:sub(1, remaining) or data
			append_body(body_piece)

			if expected_length and body_bytes >= expected_length then
				complete_response()
			end
			return
		end

		if body_mode == "chunked" then
			chunk_buffer = chunk_buffer .. data
			local ok, parse_err = decode_chunked()
			if ok == nil then
				finish(make_error("Failed to decode chunked response: " .. tostring(parse_err)), nil)
				return
			end
			if ok then
				complete_response()
			end
			return
		end

		append_body(data)
	end

	local function process_data(data)
		if done then
			return
		end

		if headers_parsed then
			process_body(data)
			return
		end

		header_buffer = header_buffer .. data
		local parsed, remaining, parse_err = parse_headers(header_buffer)
		if parse_err then
			finish(make_error(parse_err), nil)
			return
		end
		if not parsed then
			return
		end

		headers_parsed = true
		header_buffer = ""
		response.status = parsed.status
		response.headers = parsed.headers

		local method = (opts.method or "GET"):upper()
		local transfer_encoding = (parsed.headers["transfer-encoding"] or ""):lower()
		local content_length = tonumber(parsed.headers["content-length"])
		local status = parsed.status

		if method == "HEAD" or status == 204 or status == 304 or (status >= 100 and status < 200) then
			body_mode = "none"
			complete_response()
			return
		end

		if transfer_encoding:find("chunked", 1, true) then
			body_mode = "chunked"
		elseif content_length then
			expected_length = content_length
			if expected_length <= 0 then
				body_mode = "none"
				complete_response()
				return
			end
			body_mode = "length"
		else
			body_mode = "close"
		end

		if remaining and remaining ~= "" then
			process_body(remaining)
		end
	end

	local function on_timeout()
		local timeout = tonumber(opts.timeout) or 0
		finish(make_error("Request timed out after " .. timeout .. "ms", { timeout = true }), nil)
	end

	local function on_read(read_err, data)
		if done then
			return
		end

		if read_err then
			finish(make_error("Read failed: " .. tostring(read_err)), nil)
			return
		end

		if data then
			process_data(data)
			return
		end

		if not headers_parsed then
			finish(make_error("Connection closed before response headers"), nil)
			return
		end

		if body_mode == "close" then
			complete_response()
			return
		end

		if body_mode == "length" then
			if expected_length and body_bytes >= expected_length then
				complete_response()
				return
			end
			finish(make_error("Connection closed before full response body"), nil)
			return
		end

		if body_mode == "chunked" then
			if chunk_done then
				complete_response()
				return
			end
			finish(make_error("Connection closed before chunked response completed"), nil)
			return
		end

		complete_response()
	end

	if opts.timeout and opts.timeout > 0 then
		timer = uv.new_timer()
		if timer then
			timer:start(opts.timeout, 0, vim.schedule_wrap(on_timeout))
		end
	end

	local request_data = build_request(vim.tbl_extend("force", {}, opts, {
		host = host,
		port = port,
	}))

	resolve_target(host, port, function(resolve_err, targets)
		if done then
			return
		end

		if resolve_err then
			finish(resolve_err, nil)
			return
		end

		local function connect_next(index, last_error)
			if done then
				return
			end

			local target = targets[index]
			if not target then
				if last_error then
					finish(make_error("Connect failed: " .. tostring(last_error)), nil)
				else
					finish(make_error("Connect failed"), nil)
				end
				return
			end

			if socket then
				safe_close(socket)
				socket = nil
			end

			socket = uv.new_tcp()
			if not socket then
				finish(make_error("Failed to create TCP socket"), nil)
				return
			end

			local connect_req, connect_err = socket:connect(target.addr, target.port, function(connect_cb_err)
				if done then
					return
				end

				if connect_cb_err then
					safe_close(socket)
					socket = nil
					connect_next(index + 1, connect_cb_err)
					return
				end

				local read_req, read_start_err = socket:read_start(on_read)
				if read_req == nil then
					finish(make_error("Failed to start read: " .. tostring(read_start_err)), nil)
					return
				end

				local write_req, write_start_err = socket:write(request_data, function(write_err)
					if done then
						return
					end
					if write_err then
						finish(make_error("Write failed: " .. tostring(write_err)), nil)
					end
				end)
				if write_req == nil then
					finish(make_error("Failed to write request: " .. tostring(write_start_err)), nil)
				end
			end)

			if connect_req == nil then
				safe_close(socket)
				socket = nil
				connect_next(index + 1, connect_err)
			end
		end

		connect_next(1, nil)
	end)
end

---@param opts table
---@return table|nil stream
---@return table|nil err
function M.open_stream(opts)
	local host, port, target_err = normalize_target(opts or {})
	if target_err then
		return nil, target_err
	end

	local socket = nil

	local active = true
	local headers_parsed = false
	local header_buffer = ""
	local timer = nil

	local function cleanup()
		stop_timer(timer)
		if socket then
			pcall(function()
				socket:read_stop()
			end)
			safe_close(socket)
			socket = nil
		end
	end

	local function close_stream(reason, err)
		if not active then
			return
		end
		active = false
		cleanup()

		if err then
			schedule(opts.on_error, err)
		end
		schedule(opts.on_close, reason)
	end

	if opts.timeout and opts.timeout > 0 then
		timer = uv.new_timer()
		if timer then
			timer:start(opts.timeout, 0, vim.schedule_wrap(function()
				close_stream(
					"timeout",
					make_error("Stream request timed out after " .. tostring(opts.timeout) .. "ms", { timeout = true })
				)
			end))
		end
	end

	local request_data = build_request(vim.tbl_extend("force", {}, opts, {
		host = host,
		port = port,
		connection = opts.connection or "keep-alive",
	}))

	local function on_read(read_err, data)
		if not active then
			return
		end

		if read_err then
			close_stream("read_error", make_error("Stream read failed: " .. tostring(read_err)))
			return
		end

		if not data then
			if not headers_parsed then
				close_stream("eof", make_error("Stream closed before response headers"))
				return
			end
			close_stream("eof", nil)
			return
		end

		if headers_parsed then
			schedule(opts.on_data, data)
			return
		end

		header_buffer = header_buffer .. data
		local parsed, remaining, parse_err = parse_headers(header_buffer)
		if parse_err then
			close_stream("invalid_headers", make_error(parse_err))
			return
		end
		if not parsed then
			return
		end

		headers_parsed = true
		header_buffer = ""
		stop_timer(timer)
		timer = nil

		schedule(opts.on_headers, parsed.status, parsed.headers)

		if remaining and remaining ~= "" then
			schedule(opts.on_data, remaining)
		end
	end

	resolve_target(host, port, function(resolve_err, targets)
		if not active then
			return
		end

		if resolve_err then
			close_stream("resolve_error", resolve_err)
			return
		end

		local function connect_next(index, last_error)
			if not active then
				return
			end

			local target = targets[index]
			if not target then
				if last_error then
					close_stream("connect_error", make_error("Stream connect failed: " .. tostring(last_error)))
				else
					close_stream("connect_error", make_error("Stream connect failed"))
				end
				return
			end

			if socket then
				safe_close(socket)
				socket = nil
			end

			socket = uv.new_tcp()
			if not socket then
				close_stream("connect_error", make_error("Failed to create TCP socket"))
				return
			end

			local connect_req, connect_err = socket:connect(target.addr, target.port, function(connect_cb_err)
				if not active then
					return
				end

				if connect_cb_err then
					safe_close(socket)
					socket = nil
					connect_next(index + 1, connect_cb_err)
					return
				end

				local read_req, read_start_err = socket:read_start(on_read)
				if read_req == nil then
					close_stream("read_start_error", make_error("Failed to start stream read: " .. tostring(read_start_err)))
					return
				end

				local write_req, write_start_err = socket:write(request_data, function(write_err)
					if not active then
						return
					end
					if write_err then
						close_stream("write_error", make_error("Failed to write stream request: " .. tostring(write_err)))
					end
				end)
				if write_req == nil then
					close_stream("write_start_error", make_error("Failed to start stream write: " .. tostring(write_start_err)))
				end
			end)

			if connect_req == nil then
				safe_close(socket)
				socket = nil
				connect_next(index + 1, connect_err)
			end
		end

		connect_next(1, nil)
	end)

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
