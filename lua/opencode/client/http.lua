-- opencode.nvim - HTTP client for OpenCode server API
-- Uses vim.uv sockets for async HTTP requests

local M = {}
local auth = require("opencode.client.auth")
local transport = require("opencode.client.transport")
local schedule_callback = require("opencode.util.schedule").schedule_callback

-- Default configuration (merged with user config)
M.opts = {
	host = "localhost",
	auth = {
		username = "opencode",
		password = nil,
	},
	timeout = 30000,
}

-- Merge headers
local function merge_headers(additional)
	local headers = {}
	local authorization, auth_err = auth.header(M.opts.auth.username, M.opts.auth.password)
	if auth_err then
		return nil, auth_err
	end
	if authorization then
		headers.Authorization = authorization
	end
	headers["Content-Type"] = "application/json"
	headers["Accept"] = "application/json"

	if additional then
		for k, v in pairs(additional) do
			headers[k] = v
		end
	end

	return headers
end

-- Handle HTTP response
local function handle_response(response, callback, request_meta)
	if not response then
		schedule_callback(callback, { error = "No response from server", message = "No response from server" }, nil)
		return
	end

	local meta = { status = response.status, headers = response.headers or {} }
	if response.status < 200 or response.status >= 300 then
		local ok, detail = pcall(vim.json.decode, response.body or "")
		local message = "HTTP " .. tostring(response.status)
		local code
		if ok and type(detail) == "table" then
			code = detail._tag or detail.code or detail.name
			if type(detail.message) == "string" then
				message = detail.message
			end
		end
		-- Do not surface arbitrary HTML or credentials in server error responses.
		local password = M.opts.auth.password
		if type(password) == "string" and password ~= "" then
			message = message:gsub(password:gsub("([^%w])", "%%%1"), "[redacted]")
		end
		schedule_callback(callback, {
			status = response.status, code = code, message = message, error = message,
			rpc_type = code == "RpcError" and type(detail.type) == "string" and detail.type or nil,
			retryable = response.status == 429 or response.status >= 500,
		}, nil, meta)
		return
	end

	-- Handle empty body (e.g., 204 No Content)
	if not response.body or response.body == "" then
		schedule_callback(callback, nil, true, meta)
		return
	end
	local content_type = meta.headers["content-type"] or meta.headers["Content-Type"]
	if content_type and not content_type:lower():match("^application/[%w.+-]*json") then
		schedule_callback(callback, { status = response.status, code = "invalid_content_type",
			message = "Expected a JSON response", retryable = false }, nil, meta)
		return
	end

	-- Parse JSON response
	local ok, body = pcall(vim.json.decode, response.body)
	if not ok then
		schedule_callback(callback, {
			status = response.status, code = "invalid_json", retryable = false,
			error = "Failed to parse JSON response", message = "Failed to parse JSON response",
		}, nil, meta)
		return
	end

	schedule_callback(callback, nil, body, meta)
end

-- Configure the HTTP client
---@param opts table Configuration options
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

-- Simple percent-encoder for URL query params
local function urlencode(s)
	s = tostring(s)
	return s:gsub("[^A-Za-z0-9%-_.~]", function(c)
		return string.format("%%%02X", c:byte())
	end)
end

---@param path string
---@param query? table
---@return string
local function build_path(path, query)
	if not query then
		return path
	end

	local query_parts = {}
	local function append(key, value)
		if type(value) == "table" then
			for _, child in ipairs(vim.tbl_keys(value)) do
				append(key .. "[" .. child .. "]", value[child])
			end
		elseif value ~= nil then
			local encoded = value == vim.NIL and "null" or tostring(value)
			table.insert(query_parts, urlencode(key) .. "=" .. urlencode(encoded))
		end
	end
	for key, value in pairs(query) do
		append(key, value)
	end
	table.sort(query_parts)

	if #query_parts == 0 then
		return path
	end

	return path .. (path:find("?", 1, true) and "&" or "?") .. table.concat(query_parts, "&")
end

---@param method string
---@param path string
---@param callback function
---@param opts? table
---@param body? string
local function request(method, path, callback, opts, body)
	opts = opts or {}
	local request_path = build_path(path, opts.query)
	local headers, headers_err = merge_headers(opts.headers)
	if headers_err then
		schedule_callback(callback, {
			error = headers_err,
			message = headers_err,
		}, nil)
		return
	end

	transport.request({
		host = M.opts.host,
		port = M.opts.port,
		method = method,
		path = request_path,
		headers = headers,
		timeout = opts.timeout or M.opts.timeout,
		body = body,
	}, function(err, response)
		if err then
			schedule_callback(callback, err, nil)
			return
		end
		handle_response(response, callback, { method = method, path = request_path })
	end)
end

-- GET request
---@param path string API path
---@param callback function(err, data)
---@param opts? table Optional request options (query params, headers)
function M.get(path, callback, opts)
	request("GET", path, callback, opts, nil)
end

-- POST request
---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.post(path, body, callback, opts)
	local ok, json_body = pcall(vim.json.encode, body)
	if not ok then
		schedule_callback(callback, {
			error = "Failed to encode request body: " .. tostring(json_body),
			message = "Failed to encode request body: " .. tostring(json_body),
		}, nil)
		return
	end

	request("POST", path, callback, opts, json_body)
end

-- PATCH request
---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.patch(path, body, callback, opts)
	local ok, json_body = pcall(vim.json.encode, body)
	if not ok then
		schedule_callback(callback, {
			error = "Failed to encode request body: " .. tostring(json_body),
			message = "Failed to encode request body: " .. tostring(json_body),
		}, nil)
		return
	end

	request("PATCH", path, callback, opts, json_body)
end

-- DELETE request
---@param path string API path
---@param callback function(err, data)
---@param opts? table Optional request options
function M.delete(path, callback, opts)
	request("DELETE", path, callback, opts, nil)
end

-- PUT request
---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.put(path, body, callback, opts)
	local json_body = nil
	if body ~= nil then
		local ok, encoded = pcall(vim.json.encode, body)
		if not ok then
			schedule_callback(callback, {
				error = "Failed to encode request body: " .. tostring(encoded),
				message = "Failed to encode request body: " .. tostring(encoded),
			}, nil)
			return
		end
		json_body = encoded
	end

	request("PUT", path, callback, opts, json_body)
end

-- Check server health
---@param callback function(err, data) data = v2 ServerInfo
function M.health(callback)
	require("opencode.client.v2").request("info", { timeout = 5000 }, callback)
end

-- Test connection synchronously (for startup checks)
---@return boolean connected
---@return string|nil error
function M.test_connection()
	local done = false
	local connected = false
	local error_message = nil

	M.health(function(err, data)
		if err then
			error_message = err.message or err.error or tostring(err)
			done = true
			return
		end

		if not data or not data.version then
			error_message = "Health check failed"
			done = true
			return
		end

		connected = true
		done = true
	end)

	local completed = vim.wait(5000, function()
		return done
	end, 20)

	if not completed then
		return false, "Connection timeout"
	end

	if not connected then
		return false, error_message or "Connection failed"
	end

	return true, nil
end

return M
