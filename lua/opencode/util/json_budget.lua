-- Exact incremental sizing for the plain JSON arrays/objects built by editor
-- context collectors. Callers still use their original encoder for final output.
local M = {}
local Budget = {}
Budget.__index = Budget

function M.new(encoded_bytes, max_bytes)
	return setmetatable({ bytes = encoded_bytes, max_bytes = max_bytes }, Budget)
end

function Budget:add(list, value, prepend)
	local extra = #vim.json.encode(value) + (#list > 0 and 1 or 0)
	if self.bytes + extra > self.max_bytes then return false end
	table.insert(list, prepend and 1 or (#list + 1), value)
	self.bytes = self.bytes + extra
	return true
end

function Budget:remove_last(list)
	local extra = #vim.json.encode(list[#list]) + (#list > 1 and 1 or 0)
	table.remove(list)
	self.bytes = self.bytes - extra
end

function Budget:field(data, key, value)
	local previous = data[key]
	local extra = #vim.json.encode(value)
	if previous ~= nil then
		extra = extra - #vim.json.encode(previous)
	else
		extra = extra + #vim.json.encode(key) + 1 + (next(data) ~= nil and 1 or 0)
	end
	-- Keep the original insertion/removal even on rejection: changing the hash
	-- layout can affect the final JSON object's key order.
	data[key] = value
	if self.bytes + extra > self.max_bytes then
		data[key] = previous
		return false
	end
	self.bytes = self.bytes + extra
	return true
end

return M
