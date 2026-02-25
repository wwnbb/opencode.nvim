-- opencode.nvim - HTTP client for OpenCode server API
-- Uses vim.uv sockets for async HTTP requests

local M = {}
local transport = require("opencode.client.transport")

-- Default configuration (merged with user config)
M.opts = {
	host = "localhost",
	auth = {
		username = "opencode",
		password = nil,
	},
	timeout = 30000,
}

-- Build authentication header
local function auth_header()
	if not M.opts.auth.password then
		return nil
	end
	local credentials = string.format("%s:%s", M.opts.auth.username, M.opts.auth.password)
	local encoded = vim.fn.base64encode(credentials)
	return "Basic " .. encoded
end

-- Merge headers
local function merge_headers(additional)
	local headers = {}
	local auth = auth_header()
	if auth then
		headers.Authorization = auth
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

---@param callback function
---@param err table|nil
---@param data any
local function schedule_callback(callback, err, data)
	vim.schedule(function()
		callback(err, data)
	end)
end

-- Handle HTTP response
local function handle_response(response, callback)
	if not response then
		schedule_callback(callback, { error = "No response from server", message = "No response from server" }, nil)
		return
	end

	if response.status >= 400 then
		local err = {
			status = response.status,
			message = response.body or "HTTP error",
			error = response.body or "HTTP error",
		}
		schedule_callback(callback, err, nil)
		return
	end

	-- Handle empty body (e.g., 204 No Content)
	if not response.body or response.body == "" then
		schedule_callback(callback, nil, true)
		return
	end

	-- Parse JSON response
	local ok, body = pcall(vim.json.decode, response.body)
	if not ok then
		schedule_callback(callback, {
			error = "Failed to parse JSON: " .. tostring(body),
			message = "Failed to parse JSON: " .. tostring(body),
		}, nil)
		return
	end

	schedule_callback(callback, nil, body)
end

-- Configure the HTTP client
---@param opts table Configuration options
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

---@param path string
---@param query? table
---@return string
local function build_path(path, query)
	if not query then
		return path
	end

	local query_parts = {}
	for key, value in pairs(query) do
		table.insert(query_parts, string.format(
			"%s=%s",
			vim.fn.urlencode(tostring(key)),
			vim.fn.urlencode(tostring(value))
		))
	end

	if #query_parts == 0 then
		return path
	end

	return path .. "?" .. table.concat(query_parts, "&")
end

---@param method string
---@param path string
---@param callback function
---@param opts? table
---@param body? string
local function request(method, path, callback, opts, body)
	opts = opts or {}

	transport.request({
		host = M.opts.host,
		port = M.opts.port,
		method = method,
		path = build_path(path, opts.query),
		headers = merge_headers(opts.headers),
		timeout = opts.timeout or M.opts.timeout,
		body = body,
	}, function(err, response)
		if err then
			schedule_callback(callback, err, nil)
			return
		end
		handle_response(response, callback)
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
---@param callback function(err, data) data = { healthy = true, version = string }
function M.health(callback)
	M.get("/global/health", callback, { timeout = 5000 })
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

		if not data or not data.healthy then
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
