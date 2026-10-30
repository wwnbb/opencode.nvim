-- Canonical JSON: object keys are sorted, so equal values always encode to the
-- same bytes. Prompts stay cacheable and option maps share one fingerprint.
-- The output has the same length as vim.json.encode, so byte budgets agree.
local M = {}

---@param value any
---@return boolean
function M.is_object(value)
	if type(value) ~= "table" then return false end
	for key in pairs(value) do
		if type(key) ~= "string" then return false end
	end
	return true
end

-- Rejects functions, cycles and non-finite numbers.
local function encode(value, seen)
	if value == vim.NIL then return "null" end
	local kind = type(value)
	if kind == "string" or kind == "boolean" then return vim.json.encode(value) end
	if kind == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return vim.json.encode(value)
	end
	if kind ~= "table" then error("Expected JSON value") end
	if seen[value] then error("Circular JSON value") end
	seen[value] = true
	local values = {}
	if vim.islist(value) then
		for _, item in ipairs(value) do values[#values + 1] = encode(item, seen) end
		seen[value] = nil
		return "[" .. table.concat(values, ",") .. "]"
	end
	if not M.is_object(value) then error("Expected JSON object or array") end
	for _, key in ipairs(vim.fn.sort(vim.tbl_keys(value))) do
		values[#values + 1] = vim.json.encode(key) .. ":" .. encode(value[key], seen)
	end
	seen[value] = nil
	return "{" .. table.concat(values, ",") .. "}"
end

---@param value any
---@return string
function M.encode(value)
	return encode(value, {})
end

return M
