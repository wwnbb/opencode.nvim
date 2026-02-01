-- opencode.nvim - HTTP client for OpenCode server API
-- Uses plenary.nvim for async HTTP requests

local M = {}

-- Check for plenary.nvim dependency
local has_plenary, curl = pcall(require, "plenary.curl")
if not has_plenary then
	vim.notify("opencode.nvim requires plenary.nvim. Please install nvim-lua/plenary.nvim", vim.log.levels.ERROR)
	return M
end

-- Default configuration (merged with user config)
M.opts = {
	host = "localhost",
	port = 9099,
	auth = {
		username = "opencode",
		password = nil,
	},
	timeout = 30000,
}

-- Build base URL from config
local function base_url()
	return string.format("http://%s:%d", M.opts.host, M.opts.port)
end

-- Build authentication header
local function auth_header()
	if not M.opts.auth.password then
		return nil
	end
	local credentials = string.format("%s:%s", M.opts.auth.username, M.opts.auth.password)
	local encoded = vim.fn.base64encode(credentials)
	return { Authorization = "Basic " .. encoded }
end

-- Merge headers
local function merge_headers(additional)
	local headers = auth_header() or {}
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
local function handle_response(response, callback)
	if not response then
		callback({ error = "No response from server" }, nil)
		return
	end

	if response.status >= 400 then
		local err = {
			status = response.status,
			message = response.body or "HTTP error",
		}
		callback(err, nil)
		return
	end

	-- Handle empty body (e.g., 204 No Content)
	if not response.body or response.body == "" then
		callback(nil, true)
		return
	end

	-- Parse JSON response
	local ok, body = pcall(vim.json.decode, response.body)
	if not ok then
		callback({ error = "Failed to parse JSON: " .. tostring(body) }, nil)
		return
	end

	callback(nil, body)
end

-- Configure the HTTP client
---@param opts table Configuration options
function M.setup(opts)
	M.opts = vim.tbl_deep_extend("force", M.opts, opts or {})
end

-- GET request
---@param path string API path
---@param callback function(err, data)
---@param opts? table Optional request options (query params, headers)
function M.get(path, callback, opts)
	opts = opts or {}

	local url = base_url() .. path
	if opts.query then
		local query_parts = {}
		for k, v in pairs(opts.query) do
			table.insert(query_parts, string.format("%s=%s", k, vim.fn.urlencode(tostring(v))))
		end
		if #query_parts > 0 then
			url = url .. "?" .. table.concat(query_parts, "&")
		end
	end

	curl.get(url, {
		headers = merge_headers(opts.headers),
		timeout = opts.timeout or M.opts.timeout,
		callback = function(response)
			vim.schedule(function()
				handle_response(response, callback)
			end)
		end,
	})
end

-- POST request
---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.post(path, body, callback, opts)
	opts = opts or {}

	local url = base_url() .. path
	local json_body = vim.json.encode(body)

	curl.post(url, {
		headers = merge_headers(opts.headers),
		body = json_body,
		timeout = opts.timeout or M.opts.timeout,
		callback = function(response)
			vim.schedule(function()
				handle_response(response, callback)
			end)
		end,
	})
end

-- PATCH request
---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.patch(path, body, callback, opts)
	opts = opts or {}

	local url = base_url() .. path
	local json_body = vim.json.encode(body)

	curl.patch(url, {
		headers = merge_headers(opts.headers),
		body = json_body,
		timeout = opts.timeout or M.opts.timeout,
		callback = function(response)
			vim.schedule(function()
				handle_response(response, callback)
			end)
		end,
	})
end

-- DELETE request
---@param path string API path
---@param callback function(err, data)
---@param opts? table Optional request options
function M.delete(path, callback, opts)
	opts = opts or {}

	local url = base_url() .. path

	curl.delete(url, {
		headers = merge_headers(opts.headers),
		timeout = opts.timeout or M.opts.timeout,
		callback = function(response)
			vim.schedule(function()
				handle_response(response, callback)
			end)
		end,
	})
end

-- PUT request
---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.put(path, body, callback, opts)
	opts = opts or {}

	local url = base_url() .. path
	local json_body = body and vim.json.encode(body) or nil

	curl.put(url, {
		headers = merge_headers(opts.headers),
		body = json_body,
		timeout = opts.timeout or M.opts.timeout,
		callback = function(response)
			vim.schedule(function()
				handle_response(response, callback)
			end)
		end,
	})
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
	local url = base_url() .. "/global/health"
	local result = nil
	local err = nil

	local job = curl.get(url, {
		headers = merge_headers(),
		timeout = 5000,
		synchronous = true,
	})

	if not job or job.status ~= 200 then
		return false, job and job.body or "Connection failed"
	end

	return true, nil
end

return M
