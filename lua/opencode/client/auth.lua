local M = {}

local ENCODING_ERROR = "Failed to encode Basic authentication credentials: no Base64 encoder succeeded"

---@param value string
---@return string|nil
function M.encode_base64(value)
	local ok, encoded = pcall(vim.base64 and vim.base64.encode, value)
	if ok and type(encoded) == "string" and encoded ~= "" then
		return encoded
	end

	return nil
end

---@param username string
---@param password string|nil
---@return string|nil header
---@return string|nil error
function M.header(username, password)
	if not password then
		return nil, nil
	end

	local credentials = string.format("%s:%s", username, password)
	local encoded = M.encode_base64(credentials)
	if not encoded then
		return nil, ENCODING_ERROR
	end

	return "Basic " .. encoded, nil
end

return M
