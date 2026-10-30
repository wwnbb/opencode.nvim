-- Tracked chat positions anchored to the render blocks that hold them.
--
-- Renderers record frame-absolute lines (start_line/end_line) while a frame
-- is built. When the frame finishes, anchor_frame() rewrites every tracked
-- position as offsets from the edges of the blocks that hold it (pos.block,
-- pos.first, pos.last_block, pos.last) and rebuilds the block row index. An
-- in-place update then shifts that O(blocks) index, and every position
-- resolves through it.
--
-- Read positions with range(). start_line/end_line on an anchored position
-- remain as computed fields (assigning them re-anchors) for other readers.
local cs = require("opencode.ui.chat.state")
return cs.factory("positions", function(view)
local M = {}

local state = view

-- Maps whose positions (and their children) lie in one block each.
M.MAPS = { "questions", "permissions", "edits", "tasks", "tools", "pending_inputs", "stream_blocks" }

---@class OpenCodeBlockIndex
---@field keys string[]
---@field at table<string, integer>
---@field start integer[] Current first buffer row per block
---@field count integer[] Current line count per block

local function row_of(index, key, n)
	local i = index.at[key]
	if not i then return nil end
	if n >= 0 then return index.start[i] + n end
	return index.start[i] + index.count[i] + n
end

---Block index holding a buffer row.
---@param index OpenCodeBlockIndex
---@param line integer
---@return integer|nil
local function index_at(index, line)
	local low, high = 1, #index.keys
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local start = index.start[mid]
		if line < start then
			high = mid - 1
		elseif line >= start + index.count[mid] then
			low = mid + 1
		else
			return mid
		end
	end
end

---@param pos table|nil
---@return integer|nil start_line 0-based first row
---@return integer|nil end_line 0-based last row (inclusive)
function M.range(pos)
	if type(pos) ~= "table" then return nil end
	local key = rawget(pos, "block")
	if key == nil then
		local s, e = rawget(pos, "start_line"), rawget(pos, "end_line")
		if type(s) == "number" and type(e) == "number" then return s, e end
		return nil
	end
	local index = state.block_index
	if not index then return nil end
	local s = row_of(index, key, pos.first)
	local e = row_of(index, pos.last_block or key, pos.last)
	if not s or not e then return nil end
	return s, e
end

local position_mt = {
	__index = function(pos, field)
		if field == "start_line" then return (M.range(pos)) end
		if field == "end_line" then
			local _, e = M.range(pos)
			return e
		end
	end,
	__newindex = function(pos, field, value)
		if field == "start_line" or field == "end_line" then
			local s, e = M.range(pos)
			if field == "start_line" then s = value else e = value end
			return M.place(pos, s, e)
		end
		rawset(pos, field, value)
	end,
}

-- A first row is an offset from the block start (negative: from its end, for
-- a separator the block above owns); a last row counts from the block end,
-- so a range ending in a block that grows in place grows with it.
local function encode_first(index, i, line)
	local offset = line - index.start[i]
	if offset > 0 and offset == index.count[i] - 1 then return -1 end
	return offset
end

local function encode_last(index, i, line)
	return line - index.start[i] - index.count[i]
end

local anchor_children

---Anchor a position to absolute rows of the current index. Children still
---carrying absolute rows are anchored too.
---@param pos table
---@param s integer|nil
---@param e integer|nil
---@return boolean anchored
function M.place(pos, s, e)
	local index = state.block_index
	local i = index and type(s) == "number" and type(e) == "number" and e >= s and index_at(index, s)
	local j = i and index_at(index, e)
	if not i or not j then
		-- Empty or unindexed ranges stay absolute: nothing resolves into them.
		rawset(pos, "block", nil)
		rawset(pos, "first", nil)
		rawset(pos, "last_block", nil)
		rawset(pos, "last", nil)
		rawset(pos, "start_line", s)
		rawset(pos, "end_line", e)
		return false
	end
	rawset(pos, "start_line", nil)
	rawset(pos, "end_line", nil)
	rawset(pos, "block", index.keys[i])
	rawset(pos, "first", encode_first(index, i, s))
	rawset(pos, "last_block", j ~= i and index.keys[j] or nil)
	rawset(pos, "last", encode_last(index, j, e))
	if getmetatable(pos) ~= position_mt then setmetatable(pos, position_mt) end
	anchor_children(pos.children)
	return true
end

local function anchor_raw(pos)
	if type(pos) ~= "table" or rawget(pos, "block") ~= nil then return end
	local s, e = rawget(pos, "start_line"), rawget(pos, "end_line")
	if type(s) == "number" and type(e) == "number" then
		M.place(pos, s, e)
	else
		anchor_children(pos.children)
	end
end

anchor_children = function(children)
	if type(children) ~= "table" then return end
	for _, child in pairs(children) do anchor_raw(child) end
end

---Rebuild the row index from a finished frame's blocks.
---@param blocks OpenCodeRenderBlock[]
function M.rebuild(blocks)
	local index = { keys = {}, at = {}, start = {}, count = {} }
	for i, block in ipairs(blocks or {}) do
		index.keys[i] = block.key
		index.at[block.key] = i
		index.start[i] = block.start
		index.count[i] = block.finish - block.start
	end
	state.block_index = index
end

function M.clear()
	state.block_index = nil
end

---Rebuild the index and anchor every position the frame recorded.
---@param blocks OpenCodeRenderBlock[]
function M.anchor_frame(blocks)
	M.rebuild(blocks)
	for _, name in ipairs(M.MAPS) do
		for _, pos in pairs(state[name] or {}) do anchor_raw(pos) end
	end
	for _, pos in ipairs(state.message_positions or {}) do anchor_raw(pos) end
	anchor_raw(state.spinner_footer)
end

---Buffer rows [start_line, end_line) were replaced by new_count rows. The
---block holding start_line takes the difference and later blocks move.
---@param start_line integer
---@param end_line integer
---@param new_count integer
function M.shift(start_line, end_line, new_count)
	local index = state.block_index
	local delta = new_count - (end_line - start_line)
	if not index or delta == 0 then return end
	local i = index_at(index, start_line)
	if not i then
		-- An insertion right after the last block extends it.
		local last = #index.keys
		if last == 0 or start_line ~= index.start[last] + index.count[last] then return end
		i = last
	end
	index.count[i] = math.max(0, index.count[i] + delta)
	for j = i + 1, #index.keys do index.start[j] = index.start[j] + delta end
end

---The animated spinner row of the processing footer.
---@return integer|nil
function M.spinner_line()
	return (M.range(state.spinner_footer))
end

return M

end)
