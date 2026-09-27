-- Shared budget for recomputable render/memo data. The separate code-highlight
-- cache has its own 8 MiB budget and is deliberately not registered here.
local M = {}
local MAX_BYTES = 16 * 1024 * 1024
local pools = {}
local first, last, bytes, count = nil, nil, 0, 0
local Pool = {}
Pool.__index = Pool

-- Conservative retained-size estimate, with cycle protection and an early exit
-- once a single value cannot fit. Strings are counted at each retained position.
function M.estimate(value)
	local seen, total = {}, 0
	local function visit(item)
		local kind = type(item)
		if kind == "string" then total = total + 32 + #item
		elseif kind == "table" and not seen[item] then
			seen[item] = true
			total = total + 64
			-- Dense Lua arrays store values without a hash node or an explicit
			-- numeric key. Allow 16 bytes of slot/capacity overhead, then account
			-- the retained value (another 8 bytes for a scalar). Sparse numeric
			-- keys and named fields keep the conservative hash-node estimate.
			local array_length = 0
			while rawget(item, array_length + 1) ~= nil do
				array_length = array_length + 1
				total = total + 16
				visit(rawget(item, array_length))
				if total > MAX_BYTES then return end
			end
			for key, child in pairs(item) do
				if type(key) ~= "number" or key < 1 or key > array_length or key % 1 ~= 0 then
					total = total + 40
					visit(key)
					visit(child)
				end
				if total > MAX_BYTES then break end
			end
		elseif kind == "function" or kind == "userdata" or kind == "thread" then total = total + 128
		else total = total + 8 end
	end
	visit(value)
	return total
end

local function remove(entry)
	local pool = entry.pool
	if entry.previous then entry.previous.next = entry.next else first = entry.next end
	if entry.next then entry.next.previous = entry.previous else last = entry.previous end
	if entry.pool_previous then entry.pool_previous.pool_next = entry.pool_next else pool.first = entry.pool_next end
	if entry.pool_next then entry.pool_next.pool_previous = entry.pool_previous else pool.last = entry.pool_previous end
	pool.entries[entry.owner] = nil
	pool.count, pool.bytes = pool.count - 1, pool.bytes - entry.bytes
	count, bytes = count - 1, bytes - entry.bytes
end

---Create a named namespace sharing the global budget; repeated lookup reuses it.
---@param name string
---@param opts? { max_entries?: integer }
function M.new(name, opts)
	if pools[name] then return pools[name] end
	local pool = setmetatable({ name = name, entries = {}, count = 0, bytes = 0,
		max_entries = (opts or {}).max_entries or 1000 }, Pool)
	pools[name] = pool
	return pool
end

---Values are private immutable snapshots. Callers copy any publicly mutable data.
---Owner and signature must be exact stable keys (usually strings or numbers).
function Pool:get(owner, signature)
	local entry = self.entries[owner]
	if entry and entry.signature == signature then return entry.value end
end

---Replace this owner's old entry before admission. Oversized results are returned
---uncached; eviction never truncates the value. Optional size estimates cover the
---value only; owner/signature/node overhead is always included by this module.
function Pool:put(owner, signature, value, estimated_bytes)
	self:delete(owner)
	if owner == nil or value == nil then return value, false end
	local size = 256 + M.estimate(owner) + M.estimate(signature)
		+ (estimated_bytes or M.estimate(value))
	if size > MAX_BYTES or self.max_entries < 1 then return value, false end
	while self.count >= self.max_entries do remove(self.first) end
	while bytes + size > MAX_BYTES do remove(first) end
	local entry = { owner = owner, signature = signature, value = value, bytes = size, pool = self,
		previous = last, pool_previous = self.last }
	if last then last.next = entry else first = entry end
	if self.last then self.last.pool_next = entry else self.first = entry end
	last, self.last = entry, entry
	self.entries[owner] = entry
	self.count, self.bytes = self.count + 1, self.bytes + size
	count, bytes = count + 1, bytes + size
	return value, true
end

function Pool:delete(owner)
	local entry = owner ~= nil and self.entries[owner]
	if entry then remove(entry) end
end

function Pool:clear()
	while self.first do remove(self.first) end
end

function Pool:stats()
	return { entries = self.count, bytes = self.bytes, max_entries = self.max_entries }
end

function M.clear_all()
	while first do remove(first) end
end

function M.stats()
	return { entries = count, bytes = bytes, max_bytes = MAX_BYTES }
end

return M
