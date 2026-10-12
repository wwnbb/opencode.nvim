-- opencode.nvim - HTTP client for OpenCode server API

local M = {}
local auth = require("opencode.client.auth")
local transport = require("opencode.client.transport")
local schedule_callback = require("opencode.util.schedule").schedule_callback

M.opts = {
	host = "localhost",
	auth = {
		username = "opencode",
	},
	timeout = 30000,
}

local function merge_headers(additional)
	local authorization, auth_err = auth.header(M.opts.auth.username, M.opts.auth.password)
	if auth_err then
		return nil, auth_err
	end

	return require("opencode.client.headers").merge({
		Authorization = authorization,
		["Content-Type"] = "application/json",
		Accept = "application/json",
	}, additional)
end

local function handle_response(response, callback, password)
	local meta = { status = response.status, headers = response.headers }
	if response.status < 200 or response.status >= 300 then
		local ok, detail = pcall(vim.json.decode, response.body)
		local message = "HTTP " .. tostring(response.status)
		local code, force_required
		if ok and type(detail) == "table" then
			code = detail._tag or detail.code or detail.name
			if type(detail.message) == "string" then
				message = detail.message
			end
			if code == "WorktreeError" and type(detail.data) == "table" then
				if type(detail.data.message) == "string" then message = detail.data.message end
				force_required = detail.data.forceRequired == true
			end
		end
		-- Do not surface arbitrary HTML or credentials in server error responses.
		if type(password) == "string" and password ~= "" then
			message = message:gsub(password:gsub("([^%w])", "%%%1"), "[redacted]")
		end
		schedule_callback(callback, {
			status = response.status, code = code, message = message, error = message,
			rpc_type = code == "RpcError" and type(detail.type) == "string" and detail.type or nil,
			force_required = force_required,
			retryable = response.status == 429 or response.status >= 500,
		}, nil, meta)
		return
	end

	-- Handle empty body (e.g., 204 No Content)
	if response.body == "" then
		schedule_callback(callback, nil, true, meta)
		return
	end
	local content_type = meta.headers["content-type"]
	local media_type = content_type and vim.trim(content_type:match("^[^;]*")):lower()
	if media_type and media_type ~= "application/json" and not media_type:match("^application/[^%s/]+%+json$") then
		schedule_callback(callback, { status = response.status, code = "invalid_content_type",
			message = "Expected a JSON response", retryable = false }, nil, meta)
		return
	end

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

---@param opts table Configuration options
function M.setup(opts)
	M.opts = vim.tbl_extend("force", M.opts, opts or {})
	M.opts.auth = vim.tbl_extend("force", { username = "opencode" }, M.opts.auth)
end

local urlencode = require("opencode.util.text").encode_uri_component

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
			for child, child_value in pairs(value) do
				append(key .. "[" .. child .. "]", child_value)
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
	local password = M.opts.auth.password
	local headers, headers_err = merge_headers(opts.headers)
	if headers_err then
		schedule_callback(callback, {
			error = headers_err,
			message = headers_err,
		}, nil)
		return
	end

	return transport.request({
		url = M.opts.url,
		host = M.opts.host,
		port = M.opts.port,
		tls = M.opts.tls,
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
		handle_response(response, callback, password)
	end)
end

local function request_json(method, path, body, callback, opts)
	local ok, json_body = pcall(vim.json.encode, body)
	if not ok then
		local message = "Failed to encode request body: " .. tostring(json_body)
		schedule_callback(callback, {
			error = message,
			message = message,
		}, nil)
		return
	end

	return request(method, path, callback, opts, json_body)
end

---@param path string API path
---@param callback function(err, data)
---@param opts? table Optional request options (query params, headers)
function M.get(path, callback, opts)
	return request("GET", path, callback, opts)
end

---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.post(path, body, callback, opts)
	return request_json("POST", path, body, callback, opts)
end

---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.patch(path, body, callback, opts)
	return request_json("PATCH", path, body, callback, opts)
end

---@param path string API path
---@param callback function(err, data)
---@param opts? table Optional request options
function M.delete(path, callback, opts)
	if opts and opts.body ~= nil then return request_json("DELETE", path, opts.body, callback, opts) end
	return request("DELETE", path, callback, opts)
end

---@param path string API path
---@param body table Request body
---@param callback function(err, data)
---@param opts? table Optional request options
function M.put(path, body, callback, opts)
	if body == nil then
		return request("PUT", path, callback, opts)
	end
	return request_json("PUT", path, body, callback, opts)
end

---@param callback function(err, data) data = v2 ServerInfo
function M.health(callback)
	return require("opencode.client.api").request("info", { timeout = 5000 }, callback)
end

return M
