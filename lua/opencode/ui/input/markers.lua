-- Draft markers: the visible tokens (@file, @skill, [Image 1]) that tie
-- attached parts to positions in the composer text.
local M = {}

---The source span of a part's marker, if it has one.
---@param part table
---@return table|nil
function M.source(part)
	return type(part.source) == "table" and (part.source.text or part.source) or nil
end

---@param part any
---@return string|nil
function M.skill_id(part)
	local id = type(part) == "table" and (part.skillID or part.id) or nil
	return type(id) == "string" and id ~= "" and id or nil
end

---Locate a marker as a whole token, preferring its recorded source span.
---@return integer|nil first, integer|nil last 1-based inclusive byte range
function M.range(text, marker, source)
	if type(marker) ~= "string" or marker == "" then return nil end
	local function boundary(index, direction)
		local char = text:sub(index, index)
		-- A terminal period is punctuation; a dot within an identifier is not.
		while char == "." do index = index + direction; char = text:sub(index, index) end
		return index < 1 or index > #text or char:match("[%s,;:!?%(%){%}%[%]<>\"']") ~= nil
	end
	local first = type(source) == "table" and source.start
	local last = type(source) == "table" and source["end"]
	if type(first) == "number" and type(last) == "number" and first >= 0 and last <= #text
		and first % 1 == 0 and last - first == #marker and text:sub(first + 1, last) == marker
		and boundary(first, -1) and boundary(last + 1, 1) then return first + 1, last end
	local from = 1
	while true do
		local found_first, found_last = text:find(marker, from, true)
		if not found_first then return nil end
		if boundary(found_first - 1, -1) and boundary(found_last + 1, 1) then return found_first, found_last end
		from = found_last + 1
	end
end

return M
