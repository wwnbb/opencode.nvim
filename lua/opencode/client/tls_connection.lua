-- Verified TLS byte channel using an installed OpenSSL process. HTTP/SSE and
-- WebSocket share it; request headers and payloads travel only over stdin.
local M = {}
local uv = vim.uv
local tcp_connection = require("opencode.client.tcp_connection")
local make_error = tcp_connection.make_error

function M.open(opts)
	local tls = opts.tls or {}
	if type(tls) ~= "table" then return nil, make_error("Invalid TLS configuration", { code = "invalid_endpoint", retryable = false }) end
	local command = tls.command or "openssl"
	if type(command) ~= "string" or (tls.ca_file ~= nil and (type(tls.ca_file) ~= "string" or tls.ca_file == "")) then
		return nil, make_error("Invalid TLS configuration", { code = "invalid_endpoint", retryable = false })
	end
	if vim.fn.executable(command) ~= 1 or not vim.system then
		return nil, make_error("HTTPS requires an installed OpenSSL and Neovim 0.10+", { code = "tls_unavailable", retryable = false })
	end
	local host, port, err = tcp_connection.normalize_target(opts)
	if err then return nil, err end
	local address = (host:find(":", 1, true) and "[" .. host .. "]" or host) .. ":" .. port
	local ip = host:find(":", 1, true) or host:match("^%d+%.%d+%.%d+%.%d+$")
	local args = { command, "s_client", "-quiet", "-verify_return_error", ip and "-verify_ip" or "-verify_hostname",
		host, "-servername", host, "-connect", address }
	if tls.ca_file then vim.list_extend(args, { "-CAfile", tls.ca_file }) end
	local connection = { _active = true }
	local process, timer, stderr = nil, nil, ""
	local function stop_timer()
		local previous = timer
		timer = nil
		if previous and not previous:is_closing() then
			previous:stop()
			previous:close()
		end
	end
	function connection.close()
		if not connection._active then return end
		connection._active = false
		stop_timer()
		if process then
			local previous = process
			process = nil
			pcall(previous.write, previous, nil)
			pcall(previous.kill, previous, 15)
		end
	end
	local function fail(reason, failure)
		if not connection._active then return end
		connection.close()
		if opts.on_error then opts.on_error(reason, failure) end
	end
	function connection.is_active() return connection._active end
	connection.stop_timeout = stop_timer
	function connection.send(data)
		if not connection._active or not process then return false end
		local ok = pcall(process.write, process, data)
		if not ok then
			fail("write_error", make_error("TLS write failed"))
			return false
		end
		return true
	end
	local ok, started = pcall(vim.system, args, { stdin = true, text = false,
		stdout = function(read_err, data)
			if not connection._active then return end
			if read_err then fail("read_error", make_error("TLS read failed"))
			elseif data and opts.on_read then opts.on_read(nil, data) end
		end,
		stderr = function(_, data)
			if data and #stderr < 16384 then stderr = stderr .. data:sub(1, 16384 - #stderr) end
		end,
	}, function(result)
		if not connection._active then return end
		process = nil
		stop_timer()
		if result.code ~= 0 then
			local diagnostic = stderr:lower()
			local certificate = diagnostic:find("certificate verify failed", 1, true) or diagnostic:find("verification error", 1, true)
			local unsupported = diagnostic:find("unknown option", 1, true) or diagnostic:find("unrecognized", 1, true)
			local invalid_ca = diagnostic:find("error setting certificate", 1, true) or diagnostic:find("no such file", 1, true)
			fail("tls_error", make_error(certificate and "TLS certificate verification failed" or unsupported and "Installed OpenSSL lacks the required TLS options" or "TLS connection failed",
				{ code = certificate and "tls_verification_failed" or "tls_error", retryable = not certificate and not unsupported and not invalid_ca }))
		else
			connection._active = false
			if opts.on_read then opts.on_read(nil, nil) end
		end
	end)
	if not ok then
		connection._active = false
		return nil, make_error("Could not start TLS connection", { code = "tls_unavailable", retryable = false })
	end
	process = started
	local timeout = tonumber(opts.timeout) or 0
	if timeout > 0 then
		timer = uv.new_timer()
		if not timer then
			fail("timer_error", make_error("Could not create TLS deadline timer"))
			return connection
		end
		timer:start(timeout, 0, vim.schedule_wrap(function()
			if timer then fail("timeout", make_error(opts.timeout_message or "TLS connection timed out", { timeout = true })) end
		end))
	end
	if opts.data and opts.data ~= "" then connection.send(opts.data) end
	return connection
end

return M
