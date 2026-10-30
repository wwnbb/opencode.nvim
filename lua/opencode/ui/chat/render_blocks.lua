-- Keyed blocks of one rendered chat frame. The render context records where
-- each block starts while it builds the flat frame; the flat frame stays the
-- source of truth and blocks only partition its lines and content highlights.
--
-- A block owns every line pushed while it is the newest block, except blank
-- separators pushed before its first own line: those belong to the nearest
-- block above that has lines (the first block keeps its own).
local M = {}

---@class OpenCodeRenderBlock
---@field key string Unique within a frame: kind, or kind .. ":" .. id
---@field kind string
---@field id any
---@field signature string|nil Render-cache key of the block's content; nil when unknown
---@field start integer 0-based first line
---@field finish integer Exclusive end line
---@field highlight_start integer 1-based first index into the frame's content highlights
---@field highlight_finish integer Inclusive last index into the frame's content highlights

---@param kind string
---@param id any
---@return string
function M.key(kind, id)
	if id == nil then return kind end
	return kind .. ":" .. tostring(id)
end

---@param blocks table[] Open block list of a render context
---@param kind string
---@param id any
---@param signature string|nil
---@param line_count integer Lines in the frame so far
---@param highlight_count integer Content highlights in the frame so far
function M.begin(blocks, kind, id, signature, line_count, highlight_count)
	blocks[#blocks + 1] = {
		key = M.key(kind, id),
		kind = kind,
		id = id,
		signature = signature,
		start = line_count,
		highlight_start = highlight_count + 1,
	}
end

---Lines were removed from the end of the frame: no block may start past it.
---@param blocks table[]
---@param line_count integer
function M.truncate(blocks, line_count)
	for i = #blocks, 1, -1 do
		local block = blocks[i]
		if block.start <= line_count then return end
		block.start = line_count
	end
end

---A blank separator was just pushed as the last line. Blocks without a line of
---their own before it start after it, so it belongs to the block above.
---@param blocks table[]
---@param line_count integer
function M.separator_pushed(blocks, line_count)
	for i = #blocks, 2, -1 do
		local block = blocks[i]
		if block.start < line_count - 1 then return end
		block.start = line_count
	end
end

---Close the block list. Empty blocks are dropped unless they recorded
---highlights, which then show up as verifier violations.
---@param blocks table[]
---@param line_count integer
---@param highlight_count integer
---@return OpenCodeRenderBlock[]
function M.finish(blocks, line_count, highlight_count)
	local result = {}
	for i, block in ipairs(blocks) do
		local following = blocks[i + 1]
		block.finish = following and following.start or line_count
		block.highlight_finish = following and (following.highlight_start - 1) or highlight_count
		if block.finish > block.start or block.highlight_finish >= block.highlight_start then
			result[#result + 1] = block
		end
	end
	return result
end

---A block's slice of the flat frame, with highlights relative to its first line.
---@param frame table { lines: string[], nui_lines?: NuiLine[], highlights: table[] }
---@param block OpenCodeRenderBlock
---@return table { lines: string[], nui_lines: NuiLine[], highlights: table[] }
function M.content(frame, block)
	local lines, nui_lines, highlights = {}, {}, {}
	for row = block.start + 1, block.finish do
		lines[#lines + 1] = frame.lines[row]
		if frame.nui_lines then nui_lines[#nui_lines + 1] = frame.nui_lines[row] end
	end
	for index = block.highlight_start, block.highlight_finish do
		local hl = frame.highlights[index]
		local copy = vim.tbl_extend("force", {}, hl)
		copy.line = (hl.line or 0) - block.start
		if hl.end_line then copy.end_line = hl.end_line - block.start end
		highlights[#highlights + 1] = copy
	end
	return { lines = lines, nui_lines = nui_lines, highlights = highlights }
end

---@param blocks OpenCodeRenderBlock[]
---@param line integer 0-based
---@return OpenCodeRenderBlock|nil
function M.block_at(blocks, line)
	local low, high = 1, #blocks
	while low <= high do
		local mid = math.floor((low + high) / 2)
		local block = blocks[mid]
		if line < block.start then
			high = mid - 1
		elseif line >= block.finish then
			low = mid + 1
		else
			return block
		end
	end
end

---Widget maps whose positions carry highlights of their own, applied at the
---position's start line. Their order is the order highlights are written in.
M.WIDGET_MAPS = { "questions", "permissions", "edits", "tasks", "tools" }

---@param a table
---@param b table
---@return boolean
local function entry_before(a, b)
	if a.base ~= b.base then return a.base < b.base end
	if a.order ~= b.order then return a.order < b.order end
	return tostring(a.id) < tostring(b.id)
end

---Widget-map highlights grouped by the block that holds their position. Each
---entry keeps the highlight list by reference and its base line relative to
---the block, so later in-place shifts of the position do not change it.
local function absolute(pos)
	return pos.start_line, pos.end_line
end

---@param blocks OpenCodeRenderBlock[]
---@param maps table[] Position maps in M.WIDGET_MAPS order
---@param range? fun(pos: table): integer|nil Resolves a position's first row (positions.range)
---@return table<string, table[]>
function M.owned_highlights(blocks, maps, range)
	range = range or absolute
	local owned = {}
	for order, map in ipairs(maps) do
		for id, pos in pairs(map) do
			local list, first = pos.highlights, range(pos)
			if type(list) == "table" and list[1] ~= nil and type(first) == "number" then
				local block = M.block_at(blocks, first)
				if block then
					local entries = owned[block.key]
					if not entries then
						entries = {}
						owned[block.key] = entries
					end
					entries[#entries + 1] = { base = first - block.start, highlights = list, order = order, id = id }
				end
			end
		end
	end
	for _, entries in pairs(owned) do
		if entries[2] then table.sort(entries, entry_before) end
	end
	return owned
end

---@param blocks OpenCodeRenderBlock[]
---@return string|nil key The first key that occurs twice
function M.duplicate_key(blocks)
	local seen = {}
	for _, block in ipairs(blocks) do
		if seen[block.key] then return block.key end
		seen[block.key] = true
	end
end

-- ─── Diff against the applied frame ──────────────────────────────────────────
--
-- A frame for diffing is { lines, nui_lines, highlights, blocks, owned, dirty? }.
-- dirty[key] = line count marks a block an in-place update rewrote: its
-- snapshot no longer describes the buffer, so it always compares as changed.

---@param frame table
---@param block OpenCodeRenderBlock
---@return integer
local function buffer_count(frame, block)
	local dirty = frame.dirty and frame.dirty[block.key]
	return dirty or (block.finish - block.start)
end

local function same_value(a, b)
	return a == b or (type(a) == "table" and type(b) == "table" and vim.deep_equal(a, b))
end

-- NuiText extmark options; id is the text's last mark and end_col is derived.
local function same_extmark(a, b)
	for key, value in pairs(a) do
		if key ~= "id" and key ~= "end_col" and not same_value(value, b[key]) then return false end
	end
	for key in pairs(b) do
		if key ~= "id" and key ~= "end_col" and a[key] == nil then return false end
	end
	return true
end

local function next_mark(texts, index, column)
	while true do
		index = index + 1
		local text = texts[index]
		if not text then return index, column, nil, column end
		local start = column
		column = column + text:length()
		if text.extmark then return index, column, text, start end
	end
end

---Whether two NuiLines with equal content place the same text marks.
local function same_text_marks(a, b)
	local a_texts, b_texts = a and a._texts or {}, b and b._texts or {}
	local i, j, a_col, b_col = 0, 0, 0, 0
	while true do
		local x, y, x_start, y_start
		i, a_col, x, x_start = next_mark(a_texts, i, a_col)
		j, b_col, y, y_start = next_mark(b_texts, j, b_col)
		if x == nil or y == nil then return x == y end
		if x_start ~= y_start or x:length() ~= y:length() or not same_extmark(x.extmark, y.extmark) then
			return false
		end
	end
end

local function same_highlight(a, a_base, b, b_base)
	if a == b and a_base == b_base then return true end
	if type(a) ~= "table" or type(b) ~= "table" then return a == b end
	if (a.line or 0) - a_base ~= (b.line or 0) - b_base then return false end
	if (a.end_line == nil) ~= (b.end_line == nil) then return false end
	if a.end_line and a.end_line - a_base ~= b.end_line - b_base then return false end
	return (a.col_start or 0) == (b.col_start or 0)
		and (a.col_end or a.end_col) == (b.col_end or b.end_col)
		and a.hl_group == b.hl_group and a.priority == b.priority and a.hl_eol == b.hl_eol
end

local function same_owned(a, b)
	if a == nil or b == nil then return a == b end
	if #a ~= #b then return false end
	for index, x in ipairs(a) do
		local y = b[index]
		if x.base ~= y.base then return false end
		local xs, ys = x.highlights, y.highlights
		if xs ~= ys then
			if #xs ~= #ys then return false end
			for k, hl in ipairs(xs) do
				if not same_highlight(hl, 0, ys[k], 0) then return false end
			end
		end
	end
	return true
end

---Compare two blocks of equal line count.
---@return string "same", "marks" (equal lines, other highlights) or "lines"
local function compare_content(old, o, new, n)
	local count = o.finish - o.start
	local old_lines, new_lines = old.lines, new.lines
	for k = 1, count do
		if old_lines[o.start + k] ~= new_lines[n.start + k] then return "lines" end
	end
	local old_nui, new_nui = old.nui_lines or {}, new.nui_lines or {}
	for k = 1, count do
		local a, b = old_nui[o.start + k], new_nui[n.start + k]
		if a ~= b and not same_text_marks(a, b) then return "marks" end
	end
	local span = o.highlight_finish - o.highlight_start
	if span ~= n.highlight_finish - n.highlight_start then return "marks" end
	for d = 0, span do
		if not same_highlight(old.highlights[o.highlight_start + d], o.start, new.highlights[n.highlight_start + d], n.start) then
			return "marks"
		end
	end
	return same_owned(old.owned and old.owned[o.key], new.owned and new.owned[n.key]) and "same" or "marks"
end

---Runs that turn the buffer showing old into new. Blocks match by key in
---order; a reordered block is a removal plus an insertion. A matched block is
---unchanged when its signature and line count agree, else when its content
---does. Each run is { start, finish, old_start, old_finish, first?, last?, marks? }:
---new frame rows [start, finish) replace buffer rows [old_start, old_finish)
---(pre-apply coordinates), and first..last index the new blocks it writes.
---A marks run keeps its lines and only rewrites their highlights. Applied
---top-down, a run starts at buffer row start, since earlier runs are applied.
---@param old table Applied frame
---@param new table New frame
---@param opts? table { check_signatures?: boolean }
---@return table[] runs
---@return string[]|nil mismatches Keys whose signature matched but content differs (check_signatures only)
function M.diff(old, new, opts)
	local check = opts and opts.check_signatures
	local old_blocks, new_blocks = old.blocks, new.blocks
	local index = {}
	for i, block in ipairs(old_blocks) do index[block.key] = i end

	local runs, mismatches, run = {}, nil, nil
	local old_row, new_row, next_old = 0, 0, 1
	local function open(marks)
		if run and run.marks ~= marks then run = nil end
		if not run then
			run = { start = new_row, finish = new_row, old_start = old_row, old_finish = old_row, marks = marks }
			runs[#runs + 1] = run
		end
		return run
	end
	local function remove(o)
		local count = buffer_count(old, o)
		local current = open(nil)
		current.old_finish = current.old_finish + count
		old_row = old_row + count
	end
	local function insert(j, n, marks)
		local count = n.finish - n.start
		local current = open(marks)
		current.finish = current.finish + count
		current.first = current.first or j
		current.last = j
		new_row = new_row + count
	end
	local function compare(o, n)
		if old.dirty and old.dirty[o.key] then return "lines" end
		if o.finish - o.start ~= n.finish - n.start then return "lines" end
		if n.signature ~= nil and n.signature == o.signature then
			local result = check and compare_content(old, o, new, n)
			if result and result ~= "same" then
				mismatches = mismatches or {}
				mismatches[#mismatches + 1] = n.key
				return result
			end
			return "same"
		end
		return compare_content(old, o, new, n)
	end

	for j, n in ipairs(new_blocks) do
		local m = index[n.key]
		if m and m >= next_old then
			for i = next_old, m - 1 do remove(old_blocks[i]) end
			next_old = m + 1
			local o = old_blocks[m]
			local result = compare(o, n)
			if result == "same" then
				run = nil
				old_row = old_row + (o.finish - o.start)
				new_row = new_row + (n.finish - n.start)
			elseif result == "marks" then
				insert(j, n, true)
				run.old_finish = run.old_finish + (o.finish - o.start)
				old_row = old_row + (o.finish - o.start)
			else
				remove(o)
				insert(j, n)
			end
		else
			insert(j, n)
		end
	end
	for i = next_old, #old_blocks do remove(old_blocks[i]) end

	local result = {}
	for _, item in ipairs(runs) do
		if item.finish > item.start or item.old_finish > item.old_start then result[#result + 1] = item end
	end
	return result, mismatches
end

---The block of the applied frame whose current buffer rows contain
---[start, finish), honoring in-place line count changes.
---@param applied table
---@param start integer 0-based
---@param finish integer Exclusive
---@return OpenCodeRenderBlock|nil block
---@return integer|nil row The block's current first buffer row
---@return integer|nil count The block's current line count
function M.applied_block(applied, start, finish)
	if finish <= start then return nil end
	local blocks = applied.blocks or {}
	if not applied.dirty then
		local block = M.block_at(blocks, start)
		if block and finish <= block.finish then return block, block.start, block.finish - block.start end
		return nil
	end
	local row = 0
	for _, block in ipairs(blocks) do
		local count = buffer_count(applied, block)
		if start < row + count then
			if finish <= row + count and start >= row then return block, row, count end
			return nil
		end
		row = row + count
	end
end

---An in-place update rewrote lines of one block: the block now has new_count
---lines and compares as changed on the next frame, whatever its content.
---@param applied table
---@param key string
---@param new_count integer
---@param tick integer The buffer's changedtick after the update
---@return boolean replaced False when the frame has no such block
function M.replace(applied, key, new_count, tick)
	local target
	for _, block in ipairs(applied.blocks or {}) do
		if block.key == key then target = block; break end
	end
	if not target then return false end
	local old_count = buffer_count(applied, target)
	applied.dirty = applied.dirty or {}
	applied.dirty[key] = new_count
	applied.line_count = applied.line_count + new_count - old_count
	applied.tick = tick
	return true
end

local POSITION_KINDS = {
	questions = "question",
	permissions = "permission",
	edits = "edit",
	tasks = "task",
	tools = "tool",
	pending_inputs = "user",
}

---Key of the block that must contain a tracked widget position.
---@param map_name string questions|permissions|edits|tasks|tools|pending_inputs|stream_blocks
---@param id any Key in that map
---@param pos table
---@return string|nil
function M.position_key(map_name, id, pos)
	if map_name == "stream_blocks" then
		return pos.part_id and M.key("text", pos.part_id) or nil
	end
	if map_name == "tools" and pos.kind == "activity" then
		return M.key("activity", id)
	end
	local kind = POSITION_KINDS[map_name]
	return kind and M.key(kind, id) or nil
end

---Tracked positions of a chat view, as the verifier reads them.
---@param view table Chat view state
---@return table
function M.positions(view)
	local result = { spinner_footer = view.spinner_footer }
	for name in pairs(POSITION_KINDS) do result[name] = view[name] end
	result.stream_blocks = view.stream_blocks
	return result
end

local function bounds(hl, base)
	local line = base + (hl.line or 0)
	return line, hl.end_line and (base + hl.end_line) or line
end

---Check that a frame's blocks partition its lines and content highlights, that
---keys are unique, and that every content highlight, widget range and widget
---highlight lies within one block (the one its owner key names).
---@param frame table { lines: string[], highlights: table[], blocks: OpenCodeRenderBlock[], positions?: table }
---@param range? fun(pos: table): integer|nil, integer|nil Resolves a position's rows (positions.range)
---@return string[] violations Empty when the frame is consistent
function M.verify(frame, range)
	range = range or absolute
	local violations = {}
	local function fail(fmt, ...) violations[#violations + 1] = string.format(fmt, ...) end
	local blocks, lines, highlights = frame.blocks or {}, frame.lines or {}, frame.highlights or {}

	local seen, expected_line, expected_hl = {}, 0, 1
	for index, block in ipairs(blocks) do
		if type(block.key) ~= "string" then fail("block %d has no key", index) end
		if seen[block.key] then fail("duplicate key %s (blocks %d and %d)", block.key, seen[block.key], index) end
		seen[block.key] = index
		if block.start ~= expected_line then
			fail("block %s starts at %d, expected %d", block.key, block.start, expected_line)
		end
		if block.finish <= block.start then fail("block %s is empty", block.key) end
		if block.highlight_start ~= expected_hl then
			fail("block %s highlights start at %d, expected %d", block.key, block.highlight_start, expected_hl)
		end
		for hl_index = block.highlight_start, block.highlight_finish do
			local hl = highlights[hl_index]
			if type(hl) == "table" then
				local first, last = bounds(hl, 0)
				if first < block.start or last >= block.finish then
					fail("highlight %d (%s, lines %d-%d) leaves block %s [%d, %d)", hl_index, tostring(hl.hl_group),
						first, last, block.key, block.start, block.finish)
				end
			end
		end
		expected_line, expected_hl = block.finish, block.highlight_finish + 1
	end
	if expected_line ~= #lines then fail("blocks cover %d of %d lines", expected_line, #lines) end
	if expected_hl ~= #highlights + 1 then
		fail("blocks cover %d of %d content highlights", expected_hl - 1, #highlights)
	end

	local function contained(label, first, last, block)
		local first_block, last_block = M.block_at(blocks, first), M.block_at(blocks, last)
		if not first_block or first_block ~= last_block or (block and first_block ~= block) then
			fail("%s lines %d-%d span %s..%s%s", label, first, last, first_block and first_block.key or "nil",
				last_block and last_block.key or "nil", block and (" (owner " .. block.key .. ")") or "")
			return nil
		end
		return first_block
	end

	local function check_children(label, children, block)
		for child_id, child in pairs(children or {}) do
			local first, last
			if type(child) == "table" then first, last = range(child) end
			if first and last >= first then
				contained(label .. "/" .. tostring(child_id), first, last, block)
				check_children(label .. "/" .. tostring(child_id), child.children, block)
			end
		end
	end

	local positions = frame.positions or {}
	for map_name, map in pairs(positions) do
		if type(map) == "table" and map_name ~= "spinner_footer" then
			for id, pos in pairs(map) do
				local first, last = range(pos)
				if type(first) == "number" and type(last) == "number" and last >= first then
					local label = map_name .. "." .. tostring(id)
					local block = contained(label, first, last)
					local key = M.position_key(map_name, id, pos)
					if block and key and block.key ~= key then
						fail("%s lies in block %s, expected %s", label, block.key, key)
					end
					if block then
						for hl_index, hl in ipairs(type(pos.highlights) == "table" and pos.highlights or {}) do
							if type(hl) == "table" and hl.hl_group then
								local hl_first, hl_last = bounds(hl, first)
								contained(label .. " highlight " .. hl_index .. " (" .. hl.hl_group .. ")", hl_first, hl_last, block)
							end
						end
						check_children(label, pos.children, block)
					end
				end
			end
		end
	end
	local spinner = positions.spinner_footer and range(positions.spinner_footer)
	if type(spinner) == "number" then
		local block = M.block_at(blocks, spinner)
		if not block or block.key ~= "processing" then
			fail("spinner footer line %d lies in block %s", spinner, block and block.key or "nil")
		end
	end
	return violations
end

return M
