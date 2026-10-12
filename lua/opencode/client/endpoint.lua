-- One endpoint parser for REST, SSE and WebSocket transports.
local M = {}
local tcp_connection = require("opencode.client.tcp_connection")
local make_error = tcp_connection.make_error

function M.resolve(opts)
	opts = opts or {}
	local scheme, host, port, path = "http", opts.host, opts.port, ""
	if opts.url then
		if type(opts.url) ~= "string" or opts.url:find("[%s%c?#]") then
			return nil, make_error("Server URL must be an HTTP(S) URL without a query or fragment", { code = "invalid_endpoint", retryable = false })
		end
		local authority
		scheme, authority, path = opts.url:match("^(https?)://([^/]+)(.*)$")
		if not scheme or authority:find("@", 1, true) then
			return nil, make_error("Use an HTTP(S) server URL and configure Basic auth separately", { code = "invalid_endpoint", retryable = false })
		end
		if authority:sub(1, 1) == "[" then
			host, port = authority:match("^%[([%x:%.]+)%]:(%d*)$")
			if not host then
				host = authority:match("^%[([%x:%.]+)%]$")
			end
		else
			host, port = authority:match("^([%w_.%-]+):?(%d*)$")
		end
		port = port ~= "" and port or (scheme == "https" and 443 or 80)
	end
	local normalized, number, err = tcp_connection.normalize_target({ host = host, port = port })
	if err or normalized:find("[%s%c/@?#]") then
		return nil, make_error("Invalid server host or port", { code = "invalid_endpoint", retryable = false })
	end
	local visible_host = normalized:find(":", 1, true) and "[" .. normalized .. "]" or normalized
	local origin = scheme .. "://" .. visible_host .. ":" .. number
	return { scheme = scheme, host = normalized, port = number, base_path = path:gsub("/+$", ""), origin = origin }
end

function M.join(endpoint, path)
	return endpoint.base_path .. (path:sub(1, 1) == "/" and path or "/" .. path)
end

return M
