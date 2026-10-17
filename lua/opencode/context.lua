-- Frozen editor context for prompt placeholders; never reads files from disk.
local M = {}
local last
local DEFAULT_BYTES = 24576
local TRUNCATED = "[Context truncated: byte limit]"
local definitions = {
	{ name = "this", description = "Selection, range, or cursor line" },
	{ name = "buffer", description = "Current editor buffer" },
	{ name = "buffers", description = "Loaded listed editor buffers" },
	{ name = "diagnostics", description = "Diagnostics in the selection or buffer" },
	{ name = "marks", description = "Global marks" },
	{ name = "quickfix", description = "Current quickfix list" },
	{ name = "visible", description = "Visible text in the editor tab" },
}
local known = {}
for _, item in ipairs(definitions) do known[item.name] = true end

local function ordinary(buf)
	return vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf)
		and vim.bo[buf].buftype == "" and not vim.bo[buf].filetype:match("^opencode")
end

local function editor_window(win)
	return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == ""
		and not vim.api.nvim_win_get_config(win).external and ordinary(vim.api.nvim_win_get_buf(win))
end

local function path(buf)
	local name = vim.api.nvim_buf_get_name(buf)
	return name ~= "" and require("opencode.util.path").absolute(name) or ""
end

local function label(buf) local name = path(buf); return name ~= "" and name or ("[Buffer %d]"):format(buf) end

function M.items(query)
	local result = {}
	query = (query or ""):lower():gsub("^@", "")
	for _, item in ipairs(definitions) do
		if item.name:find(query, 1, true) then result[#result + 1] = vim.deepcopy(item) end
	end
	return result
end

function M.observe()
	local win = vim.api.nvim_get_current_win()
	if not editor_window(win) then return end
	local buf, cursor = vim.api.nvim_win_get_buf(win), vim.api.nvim_win_get_cursor(win)
	last = { bufnr = buf, winid = win, tabpage = vim.api.nvim_win_get_tabpage(win), path = path(buf),
		filetype = vim.bo[buf].filetype, row = cursor[1] - 1, col = cursor[2], changedtick = vim.api.nvim_buf_get_changedtick(buf) }
	local mode = vim.api.nvim_get_mode().mode
	if mode == "v" or mode == "V" or mode == "\022" then
		local first, final = vim.fn.getpos("v"), vim.fn.getpos(".")
		first[1], final[1] = buf, buf
		last.selection = { mode = mode, first = first, last = final, exclusive = vim.o.selection == "exclusive" }
		if mode == "\022" then
			local a, b = vim.fn.virtcol("v", true), vim.fn.virtcol(".", true)
			local right = math.max(a[2], b[2])
			local end_on_right = first[2] < final[2] and b[1] > a[1]
				or first[2] > final[2] and a[1] > b[1] or first[2] == final[2] and a[1] ~= b[1]
			if last.selection.exclusive and end_on_right then
				local anchor_end = first[2] < final[2] and a[2] or b[2]
				right = math.max(anchor_end, math.max(a[1], b[1]) - 1)
			end
			last.selection.left, last.selection.right = math.min(a[1], b[1]), right
			last.selection.padding = vim.wo.virtualedit:find("all", 1, true) or vim.wo.virtualedit:find("block", 1, true)
		end
	end
end

function M.setup()
	vim.api.nvim_create_autocmd({ "BufEnter", "BufLeave", "WinLeave" }, {
		group = vim.api.nvim_create_augroup("OpenCodeContext", { clear = true }), callback = M.observe,
	})
	M.observe()
end

function M.source() M.observe(); return last and vim.deepcopy(last) end
function M.clear() last = nil end

-- Native tab creation briefly enters an ordinary buffer in the new tab.
function M.preserve_source(fn)
	M.observe()
	local source, values, count = last
	local function capture(...) values, count = { ... }, select("#", ...) end
	local ok, err = xpcall(function() capture(fn()) end, debug.traceback)
	last = source
	if not ok then error(err, 0) end
	return (table.unpack or unpack)(values, 1, count)
end

local function provider(limit) return { blocks = {}, remaining = limit } end

local function add_line(value, line)
	if #line + 1 > value.remaining then value.truncated = true; return false end
	value.remaining = value.remaining - #line - 1
	value.blocks[#value.blocks + 1] = { text = line }
	return true
end

local function add_code(value, buf, first, final, read_line, suffix)
	local header = ("%s:%d-%d%s"):format(label(buf), first, final, suffix or "")
	local cost = #header + #vim.bo[buf].filetype + 10
	if cost > value.remaining then value.truncated = true; return end
	local block = { header = header, language = vim.bo[buf].filetype, lines = {} }
	value.remaining = value.remaining - cost
	value.blocks[#value.blocks + 1] = block
	local row = first
	while row <= final do
		local line, next_row
		if read_line then line, next_row = read_line(row)
		else line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] end
		if line ~= nil then
			if #line + 1 > value.remaining then value.truncated = true; break end
			block.lines[#block.lines + 1] = line
			value.remaining = value.remaining - #line - 1
		end
		row = next_row or row + 1
	end
end

local function selected_line(source, row)
	local selection = source.selection
	local first, final = selection.first, selection.last
	if first[2] > final[2] or (first[2] == final[2] and first[3] > final[3]) then first, final = final, first end
	if selection.mode == "V" then return vim.api.nvim_buf_get_lines(source.bufnr, row - 1, row, false)[1] end
	local a, b = { source.bufnr, row, 1, 0 }, { source.bufnr, row, 2147483647, 0 }
	local region_type, prefix = selection.mode, ""
	if selection.mode == "\022" then
		local line = vim.api.nvim_buf_get_lines(source.bufnr, row - 1, row, false)[1] or ""
		local width = vim.fn.strdisplaywidth(line)
		local right = selection.padding and selection.right or math.min(selection.right, width)
		if right < selection.left then return "" end
		local function position(column)
			local col = vim.fn.virtcol2col(0, row, column)
			if col <= 0 or column > width then
				return { source.bufnr, row, #line + 1, math.max(0, column - width - 1) }
			end
			local start = vim.fn.virtcol({ row, col }, true)[1]
			return { source.bufnr, row, col, column - start }
		end
		local left = selection.left
		a = position(left)
		if a[4] > 0 and a[3] <= #line and line:sub(a[3], a[3]) ~= "\t" then
			local cells = math.min(vim.fn.virtcol({ row, a[3] }, true)[2] - left + 1, right - left + 1)
			prefix, left = string.rep(" ", cells), left + cells
			if left > right then return prefix end
			a = position(left)
		end
		b = a
		region_type = selection.mode .. (right - left + 1)
	else
		if row == first[2] then a = first end
		if row == final[2] then b = final
		else
			local line = vim.api.nvim_buf_get_lines(source.bufnr, row - 1, row, false)[1] or ""
			if row ~= first[2] or line == "" then return line end
			b[3] = #line + 1
		end
	end
	local exclusive = selection.mode ~= "\022" and (row < final[2] or selection.exclusive)
	local virtualedit = vim.wo.virtualedit
	-- getregion ignores offsets within tabs unless virtual editing is enabled.
	if selection.mode == "\022" then vim.wo.virtualedit = "all" end
	local ok, lines = pcall(vim.fn.getregion, a, b, { type = region_type, exclusive = exclusive })
	if selection.mode == "\022" then vim.wo.virtualedit = virtualedit end
	if not ok then error(lines) end
	return prefix .. (lines[1] or "")
end

local function valid_range(range, source)
	if type(range) ~= "table" or type(range[1]) ~= "number" or type(range[2]) ~= "number"
		or range[1] % 1 ~= 0 or range[2] % 1 ~= 0 or range[1] < 1 or range[2] < range[1]
		or not source or range[2] > vim.api.nvim_buf_line_count(source.bufnr) then
		return nil, "Context range must contain valid inclusive source-buffer line numbers"
	end
	return range[1], range[2]
end

local function capture_source(values, source, range, limit)
	if not source then
		for _, name in ipairs({ "this", "buffer", "diagnostics", "visible" }) do values[name] = { error = "No source editor buffer available" } end
		return
	end
	local buf, first, final = source.bufnr, source.row + 1, source.row + 1
	if range then first, final = range[1], range[2]
	elseif source.selection then
		local selection = source.selection
		first, final = math.min(selection.first[2], selection.last[2]), math.max(selection.first[2], selection.last[2])
		local finish = selection.first[2] == final and selection.first or selection.last
		if selection.mode == "v" and selection.exclusive and first < final and finish[3] == 1 then final = final - 1 end
	end
	values.this, values.buffer, values.diagnostics, values.visible = provider(limit), provider(limit), provider(limit), provider(limit)
	local reader = not range and source.selection and function(row) return selected_line(source, row) end or nil
	local suffix = not range and not source.selection and (" (cursor column %d)"):format(source.col + 1) or nil
	if reader then
		vim.api.nvim_buf_call(buf, function() add_code(values.this, buf, first, final, reader, suffix) end)
	else add_code(values.this, buf, first, final, reader, suffix) end
	add_code(values.buffer, buf, 1, vim.api.nvim_buf_line_count(buf))
	local severity = { "ERROR", "WARN", "INFO", "HINT" }
	local diagnostics = vim.diagnostic.get(buf)
	table.sort(diagnostics, function(a, b) return a.lnum == b.lnum and a.col < b.col or a.lnum < b.lnum end)
	for _, item in ipairs(diagnostics) do
		local last_row = item.end_lnum or item.lnum
		if last_row > item.lnum and item.end_col == 0 then last_row = last_row - 1 end
		if not (range or source.selection) or (item.lnum <= final - 1 and last_row >= first - 1) then
			if not add_line(values.diagnostics, ("%s:%d:%d [%s] %s"):format(label(buf), item.lnum + 1, item.col + 1,
				severity[item.severity] or "INFO", item.message)) then break end
		end
	end
	if #values.diagnostics.blocks == 0 and not values.diagnostics.truncated then add_line(values.diagnostics, "No diagnostics.") end
	if vim.api.nvim_tabpage_is_valid(source.tabpage) then
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(source.tabpage)) do
			if editor_window(win) then
				vim.api.nvim_win_call(win, function()
					local current = vim.api.nvim_win_get_buf(win)
					local start, finish = vim.fn.line("w0"), vim.fn.line("w$")
					add_code(values.visible, current, start, finish, function(row)
						local fold = vim.fn.foldclosed(row)
						if fold == -1 then return vim.api.nvim_buf_get_lines(current, row - 1, row, false)[1] end
						local line = fold == row and vim.api.nvim_buf_get_lines(current, row - 1, row, false)[1] or nil
						return line, vim.fn.foldclosedend(row) + 1
					end)
				end)
				if values.visible.truncated then break end
			end
		end
	end
	if #values.visible.blocks == 0 and not values.visible.truncated then add_line(values.visible, "No visible editor text.") end
end

function M.capture(opts)
	opts = opts or {}
	local config = require("opencode.state").get_config() or {}
	local limit = opts.max_bytes or (config.context or {}).max_bytes or DEFAULT_BYTES
	if type(limit) ~= "number" or limit < 1 or limit ~= math.floor(limit) or limit == math.huge then
		return nil, "context.max_bytes must be a positive integer"
	end
	local source = M.source()
	if source and not ordinary(source.bufnr) then source = nil end
	if opts.range ~= nil then local _, err = valid_range(opts.range, source); if type(err) == "string" then return nil, err end end
	local values = {}
	capture_source(values, source, opts.range, limit)
	values.buffers, values.marks, values.quickfix = provider(limit), provider(limit), provider(limit)
	local buffers = vim.api.nvim_list_bufs()
	table.sort(buffers, function(a, b)
		if source and a == source.bufnr then return b ~= a end
		if source and b == source.bufnr then return false end
		return a < b
	end)
	for _, buf in ipairs(buffers) do
		if ordinary(buf) and vim.bo[buf].buflisted then
			add_code(values.buffers, buf, 1, vim.api.nvim_buf_line_count(buf))
			if values.buffers.truncated then break end
		end
	end
	if #values.buffers.blocks == 0 and not values.buffers.truncated then add_line(values.buffers, "No loaded editor buffers.") end
	for _, item in ipairs(vim.fn.getmarklist()) do
		local buf, row, col = item.pos[1], item.pos[2], item.pos[3]
		local name = buf > 0 and vim.api.nvim_buf_is_valid(buf) and label(buf) or item.file or "[unknown]"
		local text = ("%s %s:%d:%d"):format(item.mark, name, row, col)
		if buf > 0 and vim.api.nvim_buf_is_loaded(buf) and row > 0 then
			text = text .. " " .. (vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
		end
		if not add_line(values.marks, text) then break end
	end
	if #values.marks.blocks == 0 and not values.marks.truncated then add_line(values.marks, "No global marks.") end
	for _, item in ipairs(vim.fn.getqflist()) do
		local name = item.bufnr > 0 and vim.api.nvim_buf_is_valid(item.bufnr) and label(item.bufnr) or "[unknown]"
		if not add_line(values.quickfix, ("%s:%d:%d%s %s"):format(name, item.lnum, item.col,
			item.type ~= "" and (" [" .. item.type .. "]") or "", item.text)) then break end
	end
	if #values.quickfix.blocks == 0 and not values.quickfix.truncated then add_line(values.quickfix, "No quickfix entries.") end
	return { values = values, max_bytes = limit, source = source, range = vim.deepcopy(opts.range) }
end

local function references(text, opts, resolve)
	local result = {}
	for _, group in ipairs({ opts.context or {}, opts.parts or {} }) do
		for _, part in ipairs(group) do
			if part.type == "agent" or part.type == "skill" or part.type == "file" then
				local source = type(part.source) == "table" and (part.source.text or part.source)
				if type(source) == "table" and type(source.value) == "string" and source.value ~= "" then
					local first, final = source.start, source["end"]
					local valid = type(first) == "number" and type(final) == "number" and first >= 0 and final > first and final <= #text
						and first % 1 == 0 and final % 1 == 0 and text:sub(first + 1, final) == source.value
					if not valid and part.type == "file" then
						local a, b = text:find(source.value, 1, true)
						if a and not text:find(source.value, b + 1, true) then first, final, valid = a - 1, b, true end
					end
					if valid then result[#result + 1] = { first = first, last = final, source = source }
					elseif resolve and part.type == "file" then
						-- Do not let the protocol attach a marker introduced by expanded source text.
						part.source = nil
					end
				end
			end
		end
	end
	return result
end

local function boundary(char)
	return char == "" or char:match("[%s%(%)%[%]{}<>,;:!?=+\"']") ~= nil
end

local function scan(text, refs)
	local found = {}
	for first, name, after in text:gmatch("()@([a-z]+)()") do
		if known[name] then
			local escaped = text:sub(first - 1, first - 1) == "\\"
			local start = escaped and first - 1 or first
			local before, next_char = text:sub(start - 1, start - 1), text:sub(after, after)
			local ending = boundary(next_char) or (next_char == "." and boundary(text:sub(after + 1, after + 1)))
			if boundary(before) and ending then
				local protected = false
				for _, ref in ipairs(refs) do if start - 1 < ref.last and after - 1 > ref.first then protected = true; break end end
				if not protected then found[#found + 1] = { first = start - 1, last = after - 1, name = name, escaped = escaped } end
			end
		end
	end
	return found
end

function M.has(text, opts)
	for _, item in ipairs(scan(text, references(text, opts or {}))) do if not item.escaped then return true end end
	return false
end

local function render(value, budget)
	local chunks, consumed, truncated = {}, 0, false
	for _, block in ipairs(value.blocks) do
		local separator = #chunks > 0 and 1 or 0
		local output = block.text
		if not output then
			local lines, bytes, fence = {}, 0, 3
			for _, line in ipairs(block.lines) do
				local longest = fence
				for run in line:gmatch("`+") do longest = math.max(longest, #run + 1) end
				local next_bytes = bytes + #line + (#lines > 0 and 1 or 0)
				if #block.header + #block.language + next_bytes + 2 * longest + 3 + separator > budget - consumed then
					truncated = true; break
				end
				lines[#lines + 1], bytes, fence = line, next_bytes, longest
			end
			output = block.header .. "\n" .. require("opencode.util.text").fence_code(table.concat(lines, "\n"), block.language)
		end
		if #output + separator > budget - consumed then truncated = true; break end
		chunks[#chunks + 1], consumed = output, consumed + #output + separator
		if truncated then break end
	end
	local output = table.concat(chunks, "\n")
	if truncated or value.truncated then output = output .. (output ~= "" and "\n" or "") .. TRUNCATED end
	return output, consumed
end

function M.expand(text, opts, snapshot)
	opts = vim.deepcopy(opts or {})
	local refs = references(text, opts, true)
	local edits, used = scan(text, refs), false
	for _, edit in ipairs(edits) do if not edit.escaped then used = true; break end end
	if used and not snapshot then
		local err; snapshot, err = M.capture(opts)
		if not snapshot then return nil, err end
	end
	local budget = snapshot and snapshot.max_bytes or 0
	for _, edit in ipairs(edits) do
		if edit.escaped then edit.value = "@" .. edit.name
		else
			local value = snapshot.values[edit.name]
			if value.error then return nil, "@" .. edit.name .. ": " .. value.error end
			local consumed; edit.value, consumed = render(value, budget); budget = budget - consumed
			local suffix = text:sub(edit.last + 1, edit.last + 1)
			if edit.value:match("\n`+$") and suffix ~= "" and suffix ~= "\n" then edit.value = edit.value .. "\n" end
		end
	end
	local chunks, cursor = {}, 1
	for _, edit in ipairs(edits) do
		chunks[#chunks + 1], chunks[#chunks + 2] = text:sub(cursor, edit.first), edit.value
		cursor = edit.last + 1
	end
	chunks[#chunks + 1] = text:sub(cursor)
	for _, ref in ipairs(refs) do
		local offset = 0
		for _, edit in ipairs(edits) do if edit.last <= ref.first then offset = offset + #edit.value - (edit.last - edit.first) end end
		ref.source.start, ref.source["end"] = ref.first + offset, ref.last + offset
	end
	if used and opts.context then
		local parts = {}; for _, part in ipairs(opts.context) do if not part._editor_context then parts[#parts + 1] = part end end
		opts.context = parts
	end
	return { text = table.concat(chunks), options = opts, used = used }
end

return M
