local M = {}

local ENCODING_ERROR = "Failed to encode Basic authentication credentials: no Base64 encoder succeeded"

local function default_encoders()
	return {
		modern = vim.base64 and vim.base64.encode or nil,
		legacy = vim.fn and vim.fn.base64encode or nil,
	}
end

local function try_encode(encoder, value)
	if type(encoder) ~= "function" then
		return nil
	end

	local ok, encoded = pcall(encoder, value)
	if ok and type(encoded) == "string" and encoded ~= "" then
		return encoded
	end

	return nil
end

---@param value string
---@param encoders? { modern?: function, legacy?: function }
---@return string|nil
function M.encode_base64(value, encoders)
	encoders = encoders or default_encoders()

	local encoded = try_encode(encoders.modern, value)
	if encoded then
		return encoded
	end

	return try_encode(encoders.legacy, value)
end

---@param username string
---@param password string|nil
---@param encoders? { modern?: function, legacy?: function }
---@return string|nil header
---@return string|nil error
function M.header(username, password, encoders)
	if not password then
		return nil, nil
	end

	local credentials = string.format("%s:%s", username, password)
	local encoded = M.encode_base64(credentials, encoders)
	if not encoded then
		return nil, ENCODING_ERROR
	end

	return "Basic " .. encoded, nil
end

return M
