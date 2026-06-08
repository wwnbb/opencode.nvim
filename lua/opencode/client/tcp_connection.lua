-- opencode.nvim - shared libuv TCP connection lifecycle

local M = {}

local uv = vim.uv

---@param message string
---@param extras? table
---@return table
function M.make_error(message, extras)
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
function M.normalize_target(opts)
	local host = opts and opts.host
	if type(host) ~= "string" or host == "" then
		return nil, nil, M.make_error("Host is required")
	end

	local port = tonumber(opts and opts.port)
	if not port then
		return nil, nil, M.make_error("Port is required")
	end

	if port < 1 or port > 65535 then
		return nil, nil, M.make_error("Invalid port: " .. tostring(opts and opts.port))
	end

	return host, math.floor(port), nil
end

---@param handle uv.uv_handle_t|nil
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

---@param timer uv.uv_timer_t|nil
local function stop_timer(timer)
	if not timer then
		return
	end

	local ok, closing = pcall(uv.is_closing, timer)
	if ok and closing then
		return
	end

	pcall(function()
		uv.timer_stop(timer)
	end)
	pcall(function()
		uv.close(timer)
	end)
end

---@param host string
---@param port integer
---@param callback function
local function resolve_target(host, port, callback)
	local req, req_err = uv.getaddrinfo(host, tostring(port), {
		family = 0,
		socktype = "stream",
		protocol = 0,
		addrconfig = false,
		v4mapped = false,
		all = false,
		numerichost = false,
		passive = false,
		numericserv = false,
		canonname = false,
	}, function(err, addresses)
		if err then
			callback(M.make_error("Failed to resolve host '" .. host .. "': " .. tostring(err)), nil)
			return
		end

		if not addresses or #addresses == 0 then
			callback(M.make_error("No address found for host '" .. host .. "'"), nil)
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
			callback(M.make_error("No usable address found for host '" .. host .. "'"), nil)
			return
		end

		callback(nil, targets)
	end)

	if req == nil then
		callback(M.make_error("Failed to start DNS lookup for '" .. host .. "': " .. tostring(req_err)), nil)
	end
end

---@param label string
---@param detail any
---@return table
local function labeled_error(label, detail)
	if detail == nil or detail == "" then
		return M.make_error(label)
	end
	return M.make_error(label .. ": " .. tostring(detail))
end

---@param opts table
---@return table|nil connection
---@return table|nil err
function M.open(opts)
	opts = opts or {}
	local host, port, target_err = M.normalize_target(opts)
	if target_err then
		return nil, target_err
	end

	local labels = vim.tbl_extend("force", {
		connect = "Connect failed",
		create_socket = "Failed to create TCP socket",
		read_start = "Failed to start read",
		write_start = "Failed to write request",
		write = "Write failed",
	}, opts.labels or {})

	local connection = {
		_active = true,
		_socket = nil,
		_timer = nil,
	}

	local function cleanup()
		stop_timer(connection._timer)
		connection._timer = nil

		if connection._socket then
			pcall(function()
				connection._socket:read_stop()
			end)
			safe_close(connection._socket)
			connection._socket = nil
		end
	end

	local function fail(reason, err)
		if not connection._active then
			return
		end
		connection._active = false
		cleanup()

		if type(opts.on_error) == "function" then
			opts.on_error(reason, err)
		end
	end

	function connection.close()
		if not connection._active then
			return
		end
		connection._active = false
		cleanup()
	end

	function connection.is_active()
		return connection._active
	end

	function connection.stop_timeout()
		stop_timer(connection._timer)
		connection._timer = nil
	end

	local timeout = tonumber(opts.timeout) or 0
	if timeout > 0 then
		connection._timer = uv.new_timer()
		if connection._timer then
			connection._timer:start(timeout, 0, vim.schedule_wrap(function()
				local message = opts.timeout_message or ("Connection timed out after " .. timeout .. "ms")
				fail("timeout", M.make_error(message, { timeout = true }))
			end))
		end
	end

	local request_data = opts.data or ""

	resolve_target(host, port, function(resolve_err, targets)
		if not connection._active then
			return
		end

		if resolve_err then
			fail("resolve_error", resolve_err)
			return
		end

		local function connect_next(index, last_error)
			if not connection._active then
				return
			end

			local target = targets[index]
			if not target then
				fail("connect_error", labeled_error(labels.connect, last_error))
				return
			end

			if connection._socket then
				safe_close(connection._socket)
				connection._socket = nil
			end

			connection._socket = uv.new_tcp()
			if not connection._socket then
				fail("connect_error", M.make_error(labels.create_socket))
				return
			end

			local connect_req, connect_err = connection._socket:connect(target.addr, target.port, function(connect_cb_err)
				if not connection._active then
					return
				end

				if connect_cb_err then
					safe_close(connection._socket)
					connection._socket = nil
					connect_next(index + 1, connect_cb_err)
					return
				end

				local read_req, read_start_err = connection._socket:read_start(function(read_err, data)
					if not connection._active then
						return
					end
					if type(opts.on_read) == "function" then
						opts.on_read(read_err, data)
					end
				end)
				if read_req == nil then
					fail("read_start_error", labeled_error(labels.read_start, read_start_err))
					return
				end

				local write_req, write_start_err = connection._socket:write(request_data, function(write_err)
					if not connection._active then
						return
					end
					if write_err then
						fail("write_error", labeled_error(labels.write, write_err))
					end
				end)
				if write_req == nil then
					fail("write_start_error", labeled_error(labels.write_start, write_start_err))
				end
			end)

			if connect_req == nil then
				safe_close(connection._socket)
				connection._socket = nil
				connect_next(index + 1, connect_err)
			end
		end

		connect_next(1, nil)
	end)

	return connection, nil
end

return M
