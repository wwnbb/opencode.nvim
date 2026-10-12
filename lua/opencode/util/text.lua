local M = {}

---Percent-encode a single URI path segment or query component.
---@param value any
---@return string
function M.encode_uri_component(value)
	return (tostring(value):gsub("[^A-Za-z0-9%-_.~]", function(char)
		return string.format("%%%02X", char:byte())
	end))
end

---Keep snippets containing their own Markdown fences inside one block.
---@param text string
---@param language? string
---@return string
function M.fence_code(text, language)
	local length = 3
	for run in text:gmatch("`+") do
		length = math.max(length, #run + 1)
	end
	local fence = string.rep("`", length)
	return fence .. (language or "") .. "\n" .. text .. "\n" .. fence
end

---Fit complete UTF-8 characters into display cells, with an optional suffix.
---@param text string|nil
---@param width number
---@param suffix? string
---@return string
function M.truncate(text, width, suffix)
	text = tostring(text or "")
	if width <= 0 then return "" end
	if vim.fn.strdisplaywidth(text) <= width then return text end
	suffix = suffix or ""
	local available = width - vim.fn.strdisplaywidth(suffix)
	if available < 0 then return M.truncate(suffix, width) end
	local low, high = 0, vim.fn.strchars(text)
	while low < high do
		local middle = math.ceil((low + high) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, middle)) <= available then
			low = middle
		else
			high = middle - 1
		end
	end
	return vim.fn.strcharpart(text, 0, low) .. suffix
end

---Count added and removed lines, excluding unified diff file headers.
---@param diff string|nil
---@return number additions
---@return number deletions
function M.diff_stats(diff)
	local additions, deletions = 0, 0
	if type(diff) ~= "string" then return additions, deletions end
	local old_left, new_left
	for line in diff:gmatch("[^\n]+") do
		local old_count, new_count = line:match("^@@ %-%d+,?(%d*) %+%d+,?(%d*) @@")
		if old_count then
			old_left, new_left = tonumber(old_count) or 1, tonumber(new_count) or 1
		else
			local prefix = line:sub(1, 1)
			local in_hunk = old_left and (old_left > 0 or new_left > 0)
			if prefix == "+" and (in_hunk or line:sub(1, 3) ~= "+++") then additions = additions + 1
			elseif prefix == "-" and (in_hunk or line:sub(1, 3) ~= "---") then deletions = deletions + 1 end
			-- Hunk sizes distinguish content from the next file's headers, even
			-- when multiple unified diffs are concatenated without a git header.
			if in_hunk then
				if prefix == "-" or prefix == " " then old_left = old_left - 1 end
				if prefix == "+" or prefix == " " then new_left = new_left - 1 end
			end
		end
	end
	return additions, deletions
end

---Display-cell offset used by native v2 mention ranges, including newlines.
---@param text string
---@return number
function M.display_cells(text)
	local width = 0
	for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
		width = width + vim.fn.strdisplaywidth(line) + 1
	end
	return width - 1
end

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
	local osc = esc .. "%][^" .. bel .. esc .. "]*"
	text = text:gsub(osc .. bel, "")
	text = text:gsub(osc .. esc .. "\\", "")
	text = text:gsub(esc .. "%[[0-?]*[ -/]*[@-~]", "")
	return text
end

---@param value any
---@param stringify function
---@return string
function M.normalize_text(value, stringify)
	return (M.strip_ansi(stringify(value)):gsub("\r\n?", "\n"))
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
	return ((text or ""):gsub("^\n+", ""):gsub("\n+$", ""))
end

---@param path string|nil
---@return string
function M.normalize_path(path)
	if not M.is_present(path) then
		return ""
	end

	local normalized = tostring(path)
	if normalized:match("^file://") then
		local ok, filepath = pcall(vim.uri_to_fname, normalized)
		if ok and filepath and filepath ~= "" then
			normalized = filepath
		end
	end
	return vim.fn.fnamemodify(normalized, ":~:.")
end

---@param ... any
---@return string|nil
function M.first_string(...)
	for i = 1, select("#", ...) do
		local value = select(i, ...)
		if type(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

return M
