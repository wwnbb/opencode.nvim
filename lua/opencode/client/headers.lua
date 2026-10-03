local M = {}

-- Header names are case-insensitive; caller values override defaults once.
function M.merge(defaults, additional)
	if additional ~= nil and type(additional) ~= "table" then return nil, "HTTP headers must be a table" end
	local headers = vim.tbl_extend("force", {}, defaults)
	local names, seen = {}, {}
	for name in pairs(headers) do names[name:lower()] = name end
	for name, value in pairs(additional or {}) do
		if type(name) ~= "string" then return nil, "Invalid HTTP header name" end
		local key = name:lower()
		if seen[key] then return nil, "Duplicate HTTP header: " .. key end
		seen[key] = true
		headers[names[key] or name] = value
	end
	return headers
end

return M
