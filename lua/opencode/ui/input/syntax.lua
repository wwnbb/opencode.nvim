-- Fenced-code highlights for the editable input buffer.
local M = {}
local syntax = require("opencode.ui.syntax")
local fences = require("opencode.ui.code_blocks")
local memory = require("opencode.util.memo")
local memo = memory.new("input_syntax", { max_entries = 1000 })
local ast_memo = memory.new("input_syntax_trees", { max_entries = 1000 })
local namespace = vim.api.nvim_create_namespace("opencode_input_syntax")
local group = vim.api.nvim_create_augroup("OpenCodeInputSyntax", { clear = true })

local function component(value)
	value = value or ""
	return #value .. ":" .. value
end

local function source_key(value)
	return component(value.code) .. component(value.language) .. table.concat(value.offsets, ",")
end

-- Flat numeric captures and interned styles keep large drafts within the shared
-- memo budget. Live mark IDs belong to the buffer and cannot be evicted.
local function pack(captures, block, previous)
	local values, styles, style_ids = {}, {}, {}
	local index = 0
	-- Same projection as project_highlights with one unwrapped row per source
	-- line. Compare directly with the compact snapshot before allocating one.
	for _, hl in ipairs(captures) do
		local first, last = hl.line or 0, hl.end_line or hl.line or 0
		for row = first, math.min(last, #block.lines - 1) do
			local line = block.lines[row + 1]
			local first_col = row == first and (hl.col_start or 0) or 0
			local last_col = row == last and (hl.end_col or hl.col_end) or #line
			if last_col == nil or last_col == -1 then last_col = #line end
			first_col, last_col = math.max(first_col, 0), math.min(last_col, #line)
			if last_col > first_col then
				local offset = block.offsets[row + 1] or 0
				first_col, last_col = first_col + offset, last_col + offset
				if previous then
					local style = previous.styles[previous.values[index + 4]]
					if previous.values[index + 1] ~= row or previous.values[index + 2] ~= first_col
						or previous.values[index + 3] ~= last_col or not style
						or style[1] ~= hl.hl_group or style[2] ~= (hl.priority or false) then return pack(captures, block) end
				else
					local key = component(hl.hl_group) .. tostring(hl.priority)
					local style = style_ids[key]
					if not style then
						style = #styles + 1
						style_ids[key] = style
						styles[style] = { hl.hl_group, hl.priority or false }
					end
					values[index + 1], values[index + 2] = row, first_col
					values[index + 3], values[index + 4] = last_col, style
				end
				index = index + 4
			end
		end
	end
	if previous then return index == #previous.values and previous or pack(captures, block) end
	return { values = values, styles = styles }
end

local function tree_bytes(trees, source)
	-- Native trees are opaque to Lua's table-size estimator. Include source and
	-- per-node storage with headroom for hidden grammar nodes/scanner state; no
	-- LanguageTree/parser arenas are retained. Count only once upon admission.
	local bytes = #source * 16
	for _, tree in pairs(trees) do
		bytes = bytes + 4096
		local stack = { tree:root() }
		while #stack > 0 do
			local node = table.remove(stack)
			bytes = bytes + 192
			if bytes > 16 * 1024 * 1024 then return bytes end
			for index = 0, node:child_count() - 1 do stack[#stack + 1] = node:child(index) end
		end
	end
	return bytes
end

local function remove_marks(bufnr, ids, current)
	for _, id in ipairs(ids) do
		vim.api.nvim_buf_del_extmark(bufnr, namespace, id)
		if current then current[id] = nil end
	end
end

local function marks_match(record, packed, start_line, current)
	if not record or #record.ids ~= #packed.values / 4 then return false end
	for index = 1, #packed.values, 4 do
		local mark = current[record.ids[(index + 3) / 4]]
		local row, style = start_line + packed.values[index], packed.styles[packed.values[index + 3]]
		if not mark or mark[2] ~= row or mark[3] ~= packed.values[index + 1]
			or mark[4].end_row ~= row or mark[4].end_col ~= packed.values[index + 2]
			or mark[4].hl_group ~= style[1] or mark[4].priority ~= (style[2] or 0) then return false end
	end
	return true
end

local function create_marks(bufnr, packed, start_line)
	local ids = {}
	for index = 1, #packed.values, 4 do
		local style = packed.styles[packed.values[index + 3]]
		ids[#ids + 1] = vim.api.nvim_buf_set_extmark(bufnr, namespace,
			start_line + packed.values[index], packed.values[index + 1], {
				end_col = packed.values[index + 2], hl_group = style[1], priority = style[2] or nil,
			})
	end
	return ids
end

function M.attach(bufnr)
	local active, scheduled = true, false
	local colorscheme_autocmd, last_generation
	local records = {}

	local function clear()
		vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
		for _, record in ipairs(records) do memo:delete(record.owner); ast_memo:delete(record.owner) end
		records = {}
	end

	local function update()
		scheduled = false
		if not active or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return end
		if not syntax.is_enabled("input_markdown") then
			clear()
			last_generation = nil
			return
		end
		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		-- Always rescan the entire draft: edits to a delimiter can change every
		-- later block, including text that previously was outside any fence.
		local blocks = fences.parse(table.concat(lines, "\n"))
		local generation = syntax.get_cache_generation()
		local opts = { scope = "input_markdown", min_bytes = 0, _return_syntax_trees = true,
			priority = vim.hl and vim.hl.priorities and vim.hl.priorities.treesitter or 100 }
		local same_topology = #records == #blocks
		for index, block in ipairs(blocks) do
			block.shape = component(lines[block.open_line + 1])
				.. component(block.closed and lines[block.end_line + 1] or "") .. tostring(block.closed)
			block.language = syntax.normalize_language(block.info:match("^([^%s{]+)"))
			block.code = table.concat(block.lines, "\n")
			local cached = records[index] and memo:get(records[index].owner, "source")
			if not cached or cached.shape ~= block.shape then same_topology = false end
		end
		local full = not same_topology or last_generation ~= generation
		local candidates = {}
		if #records == #blocks then
			-- Missing/changed delimiter metadata forces capture computation, but
			-- ordinal mark ownership is still safe: every position and style is
			-- compared against the complete freshly computed result below.
			candidates = records
		else
			local old_by_source, new_counts, ambiguous = {}, {}, false
			for _, record in ipairs(records) do
				local cached = memo:get(record.owner, "source")
				if cached then
					local key = source_key(cached)
					if old_by_source[key] ~= nil then old_by_source[key] = false
					else old_by_source[key] = record end
				end
			end
			for index, block in ipairs(blocks) do
				local key = source_key(block)
				new_counts[key] = (new_counts[key] or 0) + 1
				if old_by_source[key] == false or new_counts[key] > 1 then ambiguous = true end
				candidates[index] = old_by_source[key] or nil
			end
			if ambiguous then clear(); candidates = {} end
		end
		local current = {}
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
			current[mark[1]] = mark
		end
		local next_records, retained, retained_ids, dependencies, pending_trees = {}, {}, {}, {}, {}
		for index, block in ipairs(blocks) do
			local previous = candidates[index]
			local owner = previous and previous.owner or {}
			local record = { owner = owner, ids = {} }
			local metadata = { code = block.code, language = block.language, offsets = block.offsets, shape = block.shape }
			local packed = { values = {}, styles = {} }
			if block.language and #block.lines > 0 then
				local dependency = dependencies[block.language]
				if not dependency then
					local signature, cacheable = syntax.highlight_cache_signature(block.language, opts)
					dependency = { signature = signature, cacheable = cacheable }
					dependencies[block.language] = dependency
				end
				local cached = memo:get(owner, "source")
				local matching = cached
					and cached.signature == dependency.signature and cached.code == block.code
					and cached.language == block.language and vim.deep_equal(cached.offsets, block.offsets)
				local reusable = not full and matching and cached.packed
					and (dependency.cacheable or cached.status == "skipped")
				local cached_trees = reusable and ast_memo:get(owner, dependency.signature) or nil
				if not cached_trees then ast_memo:delete(owner) end
				if reusable and cached.status == "skipped" then
					packed = cached.packed
				else
					opts._syntax_trees = cached_trees
					local captures, status, trees = syntax.highlight_text(block.code, block.language, opts)
					opts._syntax_trees = nil
					packed = pack(captures, block, reusable and cached.packed or nil)
					if (dependency.cacheable or status == "skipped") and not syntax.needs_retry(captures, status) then
						metadata.signature, metadata.packed, metadata.status = dependency.signature, packed, status
						if trees then
							if matching and cached.tree_bytes then metadata.tree_bytes = cached.tree_bytes
							else
								local ok, bytes = pcall(tree_bytes, trees, block.code)
								if ok then metadata.tree_bytes = bytes end
							end
							if metadata.tree_bytes then
								pending_trees[#pending_trees + 1] = { owner = owner, signature = dependency.signature,
									trees = trees, bytes = metadata.tree_bytes }
							end
						end
					end
					-- Retry metadata only supports exact fence mapping. There is no
					-- cached result: the next ordinary update captures again.
					if not metadata.tree_bytes then ast_memo:delete(owner) end
					if not reusable or packed ~= cached.packed or status ~= cached.status
						or metadata.tree_bytes ~= cached.tree_bytes then
						memo:put(owner, "source", metadata)
					end
				end
			else memo:put(owner, "source", metadata); ast_memo:delete(owner) end
			if marks_match(previous, packed, block.start_line, current) then record.ids = previous.ids
			else
				if previous then remove_marks(bufnr, previous.ids, current) end
				record.ids = create_marks(bufnr, packed, block.start_line)
			end
			retained[owner] = true
			for _, id in ipairs(record.ids) do retained_ids[id] = true end
			next_records[#next_records + 1] = record
		end
		for _, record in ipairs(records) do
			if not retained[record.owner] then
				remove_marks(bufnr, record.ids, current)
				memo:delete(record.owner)
				ast_memo:delete(record.owner)
			end
		end
		-- Undo or another namespace user can restore marks no longer tracked by
		-- a block. Keep only the freshly validated set, as a full refresh would.
		for id in pairs(current) do
			if not retained_ids[id] then vim.api.nvim_buf_del_extmark(bufnr, namespace, id) end
		end
		-- Admit optional native trees only after the compact source/projection
		-- metadata. Never evict warm metadata to retain an AST: a miss reparses
		-- just this fence, using its saved size estimate without recounting nodes.
		for _, pending in ipairs(pending_trees) do
			if ast_memo:get(pending.owner, pending.signature) ~= pending.trees then
				ast_memo:delete(pending.owner)
				local value_bytes = memory.estimate(pending.trees) + pending.bytes
				local entry_bytes = 256 + memory.estimate(pending.owner) + memory.estimate(pending.signature) + value_bytes
				local budget = memory.stats()
				if memo:get(pending.owner, "source") and entry_bytes <= budget.max_bytes - budget.bytes then
					ast_memo:put(pending.owner, pending.signature, pending.trees, value_bytes)
				end
			end
		end
		records = next_records
		last_generation = syntax.get_cache_generation()
	end

	local function schedule()
		if not active then return true end
		if scheduled then return end
		scheduled = true
		-- Buffer callbacks run under textlock. Coalesce edits and read the latest
		-- contents after typing, paste, completion or a programmatic draft update.
		vim.schedule(update)
	end

	local function detach()
		active = false
		for _, record in ipairs(records) do memo:delete(record.owner); ast_memo:delete(record.owner) end
		records = {}
		if colorscheme_autocmd then
			vim.api.nvim_del_autocmd(colorscheme_autocmd)
			colorscheme_autocmd = nil
		end
	end

	if not vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = schedule, on_reload = schedule, on_detach = detach,
	}) then return end
	colorscheme_autocmd = vim.api.nvim_create_autocmd("ColorScheme", {
		group = group, callback = schedule, desc = "Refresh code colors in the OpenCode input",
	})
	schedule()
end

return M
