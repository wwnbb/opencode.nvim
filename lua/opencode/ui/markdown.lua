-- Assistant text follows OpenCode TextPart + OpenTUI Markdown's top-level mode.
-- See docs/opencode_source_code/opencode/packages/tui/src/routes/session/index.tsx
-- and docs/opentui/packages/core/src/renderables/{Markdown,TextTable}.ts.
local M = {}
local NuiLine = require("nui.line")
local syntax = require("opencode.ui.syntax")
local inline = require("opencode.ui.markdown.inline")
local wrap = require("opencode.ui.markdown.wrap")
local code_blocks = require("opencode.ui.code_blocks")


local function children(node, kind)
	local result = {}
	for child in node:iter_children() do
		if child:named() and (not kind or child:type() == kind) then result[#result + 1] = child end
	end
	return result
end

local function text(node, source)
	return vim.treesitter.get_node_text(node, source)
end

-- Remove ancestor container prefixes using parser ranges, including nested
-- quote/list continuations inside code. Never strip indentation by guessing.
local function container_text(node, source)
	local raw = text(node, source)
	local first_row, first_col = node:start()
	local lines = vim.split(raw, "\n", { plain = true })
	local removals = {}
	local function collect(parent)
		for child in parent:iter_children() do
			if child:type() == "block_continuation" then
				local row, col, _, end_col = child:range()
				local index = row - first_row + 1
				local offset = row == first_row and first_col or 0
				if lines[index] and end_col > col then
					removals[#removals + 1] = { index, math.max(0, col - offset), math.max(0, end_col - offset) }
				end
			else collect(child) end
		end
	end
	collect(node)
	for i = #removals, 1, -1 do
		local range = removals[i]
		lines[range[1]] = lines[range[1]]:sub(1, range[2]) .. lines[range[1]]:sub(range[3] + 1)
	end
	return table.concat(lines, "\n")
end

local function flatten(chunks)
	local parts, captures, col = {}, {}, 0
	for _, chunk in ipairs(chunks) do
		-- OpenTUI TextBuffer's default tab width is two fixed cells.
		local value = chunk.text:gsub("\t", "  ")
		parts[#parts + 1] = value
		if chunk.hl then captures[#captures + 1] = { line = 0, col_start = col,
			col_end = col + #value, hl_group = chunk.hl, priority = 4100 } end
		col = col + #value
	end
	return table.concat(parts), captures
end

-- TextTable uses full width, equal expansion and proportional shrinking with
-- a two-cell preferred minimum (one cell when the viewport is too narrow).
local function fit_columns(widths, available)
	local total = 0
	for _, width in ipairs(widths) do total = total + width end
	if total <= available then
		local extra = available - total
		for i = 1, #widths do widths[i] = widths[i] + math.floor(extra / #widths) + (i <= extra % #widths and 1 or 0) end
		return
	end
	local minimum, floors, shrinkable, fractions = 0, {}, {}, {}
	for i, width in ipairs(widths) do floors[i] = math.min(2, width); minimum = minimum + floors[i] end
	if minimum > available then for i = 1, #widths do floors[i] = 1 end; minimum = #widths end
	local shrink, capacity = total - math.max(minimum, available), total - minimum
	local used = 0
	for i, width in ipairs(widths) do
		local exact = capacity > 0 and (width - floors[i]) / capacity * shrink or 0
		local whole = math.floor(exact)
		shrinkable[i], fractions[i] = width - floors[i] - whole, exact - whole
		widths[i], used = width - whole, used + whole
	end
	for _ = 1, shrink - used do
		local best
		for i = 1, #widths do
			if shrinkable[i] > 0 and (not best or fractions[i] > fractions[best]) then best = i end
		end
		if not best then break end
		widths[best], shrinkable[best], fractions[best] = widths[best] - 1, shrinkable[best] - 1, 0
	end
end

function M.render(content, opts, render)
	opts = opts or {}
	local result = { _opencode_highlights = {}, _opencode_plain_append = false }
	local source = vim.trim(code_blocks.normalize_text(content))
	if source == "" then return result end
	-- The block grammar requires a terminating newline (notably for H1 at EOF).
	-- This is parser input only; block renderers strip their terminal newline.
	source = source .. "\n"
	local width = math.max(1, render.get_chat_text_width() - 3)
	local retry, references = false, {}
	local function add(text_value, spans, prefix, continuation, max_width)
		prefix, continuation = prefix or "", continuation or prefix or ""
		local rows = {}
		local chunks = wrap.ranges(text_value, max_width or math.max(1, width - vim.fn.strdisplaywidth(prefix)))
		for i, chunk in ipairs(chunks) do
			local decoration = "   " .. (i == 1 and prefix or continuation)
			local line = NuiLine()
			line:append(decoration .. chunk.text)
			rows[#rows + 1] = { line_index = #result, byte_start = chunk.byte_start,
				byte_end = chunk.byte_end, col_offset = #decoration }
			local row_index = #result
			result[#result + 1] = line
			local cursor = 1
			while true do
				local column = decoration:find("│", cursor, true)
				if not column then break end
				result._opencode_highlights[#result._opencode_highlights + 1] = {
					line = row_index, col_start = column - 1, col_end = column - 1 + #"│", hl_group = "OpenCodeMarkdownBorder",
				}
				cursor = column + #"│"
			end
		end
		vim.list_extend(result._opencode_highlights, syntax.project_highlights(spans, { text_value }, { rows }))
		return rows
	end
	local function blank()
		if #result > 0 and result[#result]:content() ~= "" then result[#result + 1] = NuiLine() end
	end
	local function prose(value, base, prefix, language)
		local chunks, unavailable = inline.parse(value, base or ((prefix or ""):find("│", 1, true) and "OpenCodeMarkdownQuote" or nil), language)
		retry = retry or unavailable
		-- Inline ranges can cross source newlines; split chunks without losing styles.
		local line_chunks = {}
		for _, chunk in ipairs(chunks) do
			local parts = vim.split(chunk.text, "\n", { plain = true })
			for i, part in ipairs(parts) do
				if i > 1 then
					local value_text, spans = flatten(line_chunks); add(value_text, spans, prefix)
					line_chunks = {}
				end
				line_chunks[#line_chunks + 1] = { text = part, hl = chunk.hl }
			end
		end
		local value_text, spans = flatten(line_chunks); add(value_text, spans, prefix)
	end
	local function code(value, lang, prefix, open_line)
		value = value:gsub("\t", "  ")
		local source_lines = vim.split(value, "\n", { plain = true })
		local start, rows = #result, {}
		for i, line in ipairs(source_lines) do rows[i] = add(line, {}, prefix) end
		lang = syntax.normalize_language(lang)
		if lang and syntax.is_enabled("assistant_markdown") then
			local captures = (opts.highlight_code or syntax.highlight_text)(value, lang,
				{ scope = "assistant_markdown", min_bytes = 0 }, { open_line = open_line or start })
			retry = retry or #captures == 0
			vim.list_extend(result._opencode_highlights, syntax.project_highlights(captures, source_lines, rows))
		end
	end
	local function table_block(node, prefix)
		local data, widths = {}, {}
		-- Marked's splitCells accepts empty/short rows which the block grammar
		-- can report as ERROR nodes. Split the original rows, not named cells.
		for row_index, raw in ipairs(vim.split(container_text(node, source):gsub("\n+$", ""), "\n", { plain = true })) do
			if row_index ~= 2 then
				local cells, values, cursor, escaped = {}, {}, 1, false
				raw = vim.trim(raw)
				if raw:sub(1, 1) == "|" then cursor = 2 end
				for column = cursor, #raw do
					local char = raw:sub(column, column)
					if char == "|" and not escaped then values[#values + 1] = raw:sub(cursor, column - 1); cursor = column + 1 end
					escaped = char == "\\" and not escaped
				end
				if cursor <= #raw then values[#values + 1] = raw:sub(cursor) end
				for i, cell in ipairs(values) do
					local chunks = inline.table(vim.trim(cell), references)
					if #data == 0 then for _, chunk in ipairs(chunks) do chunk.hl = "OpenCodeMarkdownHeading" end end
					local value, spans = flatten(chunks)
					cells[i] = { text = value, spans = spans }
					if #data == 0 then widths[i] = math.max(1, vim.fn.strdisplaywidth(value))
					elseif widths[i] then widths[i] = math.max(widths[i], vim.fn.strdisplaywidth(value)) end
				end
				data[#data + 1] = cells
			end
		end
		if #widths == 0 then return end
		-- OpenTUI leaves header-only tables as Markdown until a data row arrives.
		if #data == 1 then prose(text(node, source):gsub("\n+$", ""), nil, prefix); return end
		fit_columns(widths, width - vim.fn.strdisplaywidth(prefix or "") - #widths - 1)
		local function border(left, middle, right)
			local pieces = {}
			for _, w in ipairs(widths) do pieces[#pieces + 1] = string.rep("─", w) end
			local value = left .. table.concat(pieces, middle) .. right
			add(value, { { line = 0, col_start = 0, col_end = #value, hl_group = "OpenCodeMarkdownBorder" } }, prefix)
		end
		border("┌", "┬", "┐")
		for ri, row in ipairs(data) do
			local wrapped, height = {}, 1
			for ci, w in ipairs(widths) do
				wrapped[ci] = wrap.ranges(row[ci] and row[ci].text or "", w)
				height = math.max(height, #wrapped[ci])
			end
			for y = 1, height do
				local line, byte = NuiLine(), 3 + #(prefix or "")
				line:append("   " .. (prefix or ""))
				local function vertical_border()
					line:append("│")
					result._opencode_highlights[#result._opencode_highlights + 1] = {
						line = #result, col_start = byte, col_end = byte + #"│", hl_group = "OpenCodeMarkdownBorder",
					}
					byte = byte + #"│"
				end
				vertical_border()
				for ci, w in ipairs(widths) do
					local chunk = wrapped[ci][y]
					local value = chunk and chunk.text or ""
					if chunk and row[ci] then
						vim.list_extend(result._opencode_highlights, syntax.project_highlights(row[ci].spans, { row[ci].text }, { { {
							line_index = #result, byte_start = chunk.byte_start, byte_end = chunk.byte_end, col_offset = byte,
						} } }))
					end
					value = value .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(value)))
					line:append(value); byte = byte + #value
					vertical_border()
				end
				result[#result + 1] = line
			end
			if ri < #data then border("├", "┼", "┤") end
		end
		border("└", "┴", "┘")
	end
	local ok, parser = pcall(vim.treesitter.get_string_parser, source, "markdown")
	local parsed, trees = false, nil
	if ok then parsed, trees = pcall(parser.parse, parser) end
	if not parsed or not trees[1] then
		-- Missing optional parsers must leave the response readable, never empty.
		for _, line in ipairs(vim.split(source:sub(1, -2), "\n", { plain = true })) do add(line, {}) end
		result._opencode_syntax_retry = true
		return result
	end
	local function collect_references(node)
		if node:type() == "link_reference_definition" then
			local label, destination
			for child in node:iter_children() do
				if child:type() == "link_label" then label = text(child, source):sub(2, -2):gsub("%s+", " "):lower() end
				if child:type() == "link_destination" then destination = text(child, source):gsub("^<", ""):gsub(">$", "") end
			end
			if label and destination and not references[label] then references[label] = destination end
		else for child in node:iter_children() do collect_references(child) end end
	end
	collect_references(trees[1]:root())
	local visit, blocks
	local function inline_content(node)
		local values = {}
		for _, child in ipairs(children(node)) do
			if child:type() == "inline" then
				values[#values + 1] = container_text(child, source)
			end
		end
		return table.concat(values, "\n")
	end
	local function block_children(node)
		local result_nodes = {}
		for _, child in ipairs(children(node)) do
			if child:type() == "section" then vim.list_extend(result_nodes, block_children(child))
			elseif child:type() ~= "block_continuation" and child:type() ~= "block_quote_marker" then result_nodes[#result_nodes + 1] = child end
		end
		return result_nodes
	end
	local separated = { atx_heading = true, setext_heading = true, list = true, fenced_code_block = true,
		indented_code_block = true, pipe_table = true, block_quote = true, thematic_break = true }
	blocks = function(node, prefix)
		local previous
		for _, child in ipairs(block_children(node)) do
			if previous and (separated[previous:type()] or separated[child:type()]
				or (previous:type() == "paragraph" and child:type() == "paragraph")) then blank() end
			visit(child, prefix)
			previous = child
		end
	end
	visit = function(node, prefix, in_list)
		local kind = node:type()
		if kind == "paragraph" then prose(inline_content(node), nil, prefix)
		elseif kind == "atx_heading" or kind == "setext_heading" then
			local raw = container_text(node, source)
			prose(in_list and raw or raw:gsub("\n+$", ""), nil, prefix, "markdown")
		elseif kind == "fenced_code_block" then
			local fence = code_blocks.parse(container_text(node, source))[1]
			if fence then
				-- Marked's code token has no closing fence or terminal line break.
				if not fence.closed and fence.lines[#fence.lines] == "" then table.remove(fence.lines) end
				code(table.concat(fence.lines, "\n"), fence.info:match("^([^%s{]+)"), prefix, node:start())
			end
		elseif kind == "indented_code_block" then
			local raw = container_text(node, source):gsub("\n+$", "")
			local lines = vim.split(raw, "\n", { plain = true })
			for i, line in ipairs(lines) do lines[i] = line:gsub("^    ", "") end
			code(table.concat(lines, "\n"), nil, prefix, node:start())
		elseif kind == "thematic_break" then
			local value = string.rep("─", math.max(1, width - vim.fn.strdisplaywidth(prefix or "")))
			add(value, { { line = 0, col_start = 0, col_end = #value, hl_group = "OpenCodeMarkdownBorder" } }, prefix)
		elseif kind == "pipe_table" then table_block(node, prefix)
		elseif kind == "block_quote" then
			-- OpenTUI uses a single CodeRenderable here, not nested Markdown.
			local raw = text(node, source):gsub("^ *> ?", ""):gsub("\n *> ?", "\n"):gsub("\n$", "")
			prose(raw, "OpenCodeMarkdownQuote", (prefix or "") .. "│ ", "markdown")
		elseif kind == "list" then
			local items = children(node, "list_item")
			local start, marker_width, ordered = 1, 1, false
			if items[1] then
				local marker = items[1]:named_child(0)
				local number = marker and text(marker, source):match("^(%d+)")
				if number then start, ordered = tonumber(number), true; marker_width = #tostring(start + #items - 1) + 1 end
			end
			for i, item in ipairs(items) do
				local marker = ordered and tostring(start + i - 1) .. "." or "-"
				marker = string.rep(" ", marker_width - #marker) .. marker .. " "
				local first = #result + 1
				local body_prefix = (prefix or "") .. string.rep(" ", marker_width + 1)
				local previous_end
				for _, child in ipairs(block_children(item)) do
					local child_kind = child:type()
					if not child_kind:match("^list_marker") and not child_kind:match("^task_list_marker") and child_kind ~= "block_continuation" then
						local sr = child:start()
						if previous_end and sr > previous_end and child_kind ~= "list" then blank() end
						visit(child, body_prefix, true)
						previous_end = select(3, child:range())
					end
				end
				if not result[first] then add("", {}, body_prefix) end
				local line = result[first]:content()
				local offset = 3 + #(prefix or "")
				local replacement = NuiLine(); replacement:append(line:sub(1, offset))
				replacement:append(marker); replacement:append(line:sub(offset + #marker + 1))
				result[first] = replacement
				result._opencode_highlights[#result._opencode_highlights + 1] = {
					line = first - 1, col_start = offset, col_end = offset + #marker, hl_group = "OpenCodeMarkdownList",
				}
				if i < #items and text(item, source):match("\n[ \t]*\n$") then blank() end
			end
		else
			prose(container_text(node, source):gsub("\n+$", ""), nil, prefix, "markdown")
		end
	end
	blocks(trees[1]:root(), "", true)
	result._opencode_syntax_retry = retry
	return result
end

return M
