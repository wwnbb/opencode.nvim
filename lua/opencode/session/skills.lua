-- Resolve a skill selection against the location's skill catalog into
-- native prompt skill parts for the session draft.
local M = {}

---@param selected (table|string)[] Catalog records, IDs or names
---@param skills table[]|nil Catalog records
---@return table[]|nil parts Unique { type = "skill", id, name } parts in selection order
---@return string|nil unavailable Name or ID of the first selection missing from the catalog
function M.resolve(selected, skills)
	local parts, seen = {}, {}
	skills = type(skills) == "table" and skills or {}
	for _, wanted in ipairs(selected) do
		local found
		for _, skill in ipairs(skills) do
			if (type(wanted) == "table" and wanted.id == skill.id)
				or (type(wanted) == "string" and (wanted == skill.id or wanted == skill.name)) then found = skill; break end
		end
		if not found or type(found.id) ~= "string" or found.id == "" then
			return nil, tostring(type(wanted) == "table" and wanted.name or wanted)
		end
		if not seen[found.id] then
			seen[found.id] = true
			parts[#parts + 1] = { type = "skill", id = found.id, name = found.name }
		end
	end
	return parts
end

---Whether the picker already supplied catalog records, so no re-fetch is needed.
function M.are_catalog_records(selected)
	if #selected == 0 then return false end
	for _, wanted in ipairs(selected) do
		if type(wanted) ~= "table" or type(wanted.id) ~= "string" then return false end
	end
	return true
end

return M
