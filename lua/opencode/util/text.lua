local M = {}

---@param value any
---@return boolean
function M.is_nil(value)
	return value == nil or value == vim.NIL
end

---@param value any
---@return boolean
function M.is_present(value)
	return not M.is_nil(value) and tostring(value) ~= ""
end

---@param text string
---@return string
function M.strip_ansi(text)
	local esc = string.char(27)
	local bel = string.char(7)
	text = text:gsub(esc .. "%][^" .. bel .. "]*" .. bel, "")
	text = text:gsub(esc .. "%[[0-?]*[ -/]*[@-~]", "")
	return text
end

---@param value any
---@param stringify function
---@return string
function M.normalize_text(value, stringify)
	return M.strip_ansi(stringify(value)):gsub("\r\n", "\n"):gsub("\r", "\n")
end

---@param stringify function
---@param ... any
---@return string
function M.first_nonempty_text(stringify, ...)
	for i = 1, select("#", ...) do
		local text = M.normalize_text(select(i, ...), stringify)
		if text ~= "" then
			return text
		end
	end
	return ""
end

---@param stringify function
---@param ... any
---@return string
function M.first_nonempty_trimmed_text(stringify, ...)
	for i = 1, select("#", ...) do
		local text = vim.trim(M.normalize_text(select(i, ...), stringify))
		if text ~= "" then
			return text
		end
	end
	return ""
end

---@param text string|nil
---@return string
function M.trim_edge_newlines(text)
	return (text or ""):gsub("^\n+", ""):gsub("\n+$", "")
end

return M
