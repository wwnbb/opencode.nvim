-- OpenTUI tree-sitter-styled-text: query-driven concealment and style cascade.
-- The queries are copied from the local OpenTUI reference, not from the user's
-- installed Markdown highlight rules. Those may use different conceal rules.
local M = {}
local styles = require("opencode.ui.markdown.styles")
local directory = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/queries/"
local queries = {}

local function parse(source, language)
	local parser = vim.treesitter.get_string_parser(source, language, { injections = { [language] = "" } })
	return parser:parse()[1]:root()
end

local function offsets(source)
	local rows, offset = {}, 0
	for index, line in ipairs(vim.split(source, "\n", { plain = true })) do rows[index], offset = offset, offset + #line + 1 end
	return rows
end

function M.parse(source, base, language)
	language = language or "markdown_inline"
	local captures, boundaries, endings = {}, {}, {}
	local function collect(value, lang, origin, injection)
		-- Native Tree-sitter needs a final line ending for ATX headings, while
		-- the reference WASM scanner accepts EOF once five UTF-16 units exist.
		-- Keep shorter/incomplete markers literal, as the reference does.
		local input = value
		if lang == "markdown" and (value:match("^#+[ \t]+") and vim.str_utfindex(value, "utf-16") >= 5 or value:sub(-3) == "```") then input = value .. "\n" end
		local root = parse(input, lang)
		if not queries[lang] then queries[lang] = vim.treesitter.query.parse(lang, table.concat(vim.fn.readfile(directory .. lang .. ".scm"), "\n")) end
		local query, rows = queries[lang], offsets(input)
		local function offset(node)
			local sr, sc, er, ec = node:range()
			return math.min(#value, rows[sr + 1] + sc), math.min(#value, rows[er + 1] + ec)
		end
		for id, node, metadata in query:iter_captures(root, value, 0, -1) do
			local first, last = offset(node)
			if first < last then
				local name = query.captures[id]
				local meta = vim.tbl_extend("force", metadata, metadata[id] or {})
				local capture = { first = origin + first, last = origin + last, name = name,
					hl = styles.capture(name), conceal = meta.conceal, conceal_lines = meta.conceal_lines,
					injection = injection, specificity = select(2, name:gsub("%.", "")) }
				capture.index = #captures + 1
				captures[#captures + 1] = capture
				endings[capture.last] = endings[capture.last] or {}
				table.insert(endings[capture.last], capture)
				boundaries[#boundaries + 1] = capture.first
				boundaries[#boundaries + 1] = capture.last
			end
		end
		if lang == "markdown" then
			local function injections(node)
				if node:type() == "inline" or node:type() == "pipe_table_cell" then
					local first = offset(node)
					collect(vim.treesitter.get_node_text(node, value), "markdown_inline", origin + first, true)
				else for child in node:iter_children() do injections(child) end end
			end
			injections(root)
		end
	end
	local ok = pcall(collect, source, language, 0, language == "markdown_inline")
	if not ok then return { { text = source, hl = base } }, true end
	boundaries[#boundaries + 1] = 0
	boundaries[#boundaries + 1] = #source
	table.sort(boundaries)
	table.sort(captures, function(a, b) return a.first == b.first and a.index < b.index or a.first < b.first end)
	local chunks, cursor, next_capture, active = {}, 0, 1, {}
	local function append(value, hl)
		if value == "" then return end
		local last = chunks[#chunks]
		if last and last.hl == hl then last.text = last.text .. value else chunks[#chunks + 1] = { text = value, hl = hl } end
	end
	for _, finish in ipairs(boundaries) do
		if finish > cursor then
			while captures[next_capture] and captures[next_capture].first <= cursor do
				active[#active + 1] = captures[next_capture]
				next_capture = next_capture + 1
			end
			local conceal
			for index = #active, 1, -1 do
				local capture = active[index]
				if capture.last <= cursor then table.remove(active, index)
				elseif capture.conceal ~= nil and (not conceal or capture.index < conceal.index) then conceal = capture end
			end
			if conceal then
				append(conceal.conceal)
			else
				table.sort(active, function(a, b) return a.specificity == b.specificity and a.index < b.index or a.specificity < b.specificity end)
				local groups = base and { base } or {}
				for _, capture in ipairs(active) do if capture.hl then groups[#groups + 1] = capture.hl end end
				append(source:sub(cursor + 1, finish), styles.combine(groups))
			end
			cursor = finish
			for _, capture in ipairs(endings[finish] or {}) do
				if capture.conceal ~= nil then
					local next_char = source:sub(finish + 1, finish + 1)
					if (capture.conceal_lines ~= nil and next_char == "\n")
						or (next_char == " " and (capture.conceal == " " or (capture.name == "conceal" and not capture.injection))) then
						cursor = finish + 1
					end
				end
			end
		end
	end
	return chunks, false
end

-- Table cells are rendered by Marked's inline tokens in OpenTUI, not its
-- CodeRenderable. In particular entities stay literal and escapes lose `\`.
function M.table(source, references)
	references = references or {}
	local ok, root = pcall(parse, source, "markdown_inline")
	if not ok then return { { text = source } }, true end
	local chunks, rows = {}, offsets(source)
	local function bounds(node)
		local sr, sc, er, ec = node:range()
		return rows[sr + 1] + sc, rows[er + 1] + ec
	end
	local function append(value, groups)
		if value ~= "" then chunks[#chunks + 1] = { text = value, hl = styles.combine(groups) } end
	end
	local groups_by_kind = { strong_emphasis = "markup.strong", emphasis = "markup.italic", strikethrough = "markup.strikethrough" }
	local function link(label, destination)
		append(label, { styles.capture("markup.link.label") })
		append(" (" .. destination .. ")", { styles.capture("markup.link.url") })
	end
	local function plain(value, groups)
		local cursor = 1
		while cursor <= #value do
			local first, last
			for _, pattern in ipairs({ "https?://[^%s<>]+", "ftp://[^%s<>]+", "www%.[^%s<>]+", "[%w._%%+%-]+@[%w.%-]+%.[%a]+" }) do
				local a, b = value:find(pattern, cursor)
				if a and (not first or a < first) then first, last = a, b end
			end
			if not first then append(value:sub(cursor), groups); break end
			local url = value:sub(first, last):gsub("[.,:;!?]+$", "")
			while url:sub(-1) == ")" and select(2, url:gsub("%(", "")) < select(2, url:gsub("%)", "")) do url = url:sub(1, -2) end
			append(value:sub(cursor, first - 1), groups)
			local destination = url:match("^www%.") and "http://" .. url or url
			if url:find("@", 1, true) and not url:find(":", 1, true) then destination = "mailto:" .. url end
			link(url, destination)
			cursor = first + #url
		end
	end
	local visit
	visit = function(node, inherited, in_link)
		local kind = node:type()
		local first, last = bounds(node)
		local raw = source:sub(first + 1, last)
		if kind == "emphasis_delimiter" then return end
		if kind == "backslash_escape" then append(raw:sub(2), inherited); return end
		if kind == "code_span" then
			local value = raw:gsub("^`+", ""):gsub("`+$", ""):gsub("\n", " ")
			if value:match("^ .* $", 1) and value:find("[^ ]") then value = value:sub(2, -2) end
			append(value, { styles.capture("markup.raw") }); return
		end
		local reference = kind == "shortcut_link" or kind == "full_reference_link" or kind == "collapsed_reference_link"
		if kind == "image" or kind == "inline_link" or kind == "uri_autolink" or kind == "email_autolink" or reference then
			local label, destination, label_node, reference_label = "", nil, nil, nil
			for child in node:iter_children() do
				if child:type() == "link_text" or child:type() == "image_description" then label = vim.treesitter.get_node_text(child, source); label_node = child end
				if child:type() == "link_destination" then destination = vim.treesitter.get_node_text(child, source) end
				if child:type() == "link_label" then reference_label = vim.treesitter.get_node_text(child, source):sub(2, -2) end
			end
			if reference or (kind == "image" and not destination) then
				destination = references[(reference_label or label):gsub("%s+", " "):lower()]
				if not destination then append(raw, inherited); return end
				if kind == "shortcut_link" then label = reference_label or label end
			end
			if kind == "uri_autolink" or kind == "email_autolink" then
				label = raw:sub(2, -2)
				link(label, kind == "email_autolink" and "mailto:" .. label or label)
			elseif kind == "image" then
				append(label ~= "" and label or "image", { styles.capture("markup.link.label") })
			else
				if label_node then visit(label_node, { styles.capture("markup.link.label") }, true)
				else append(label, { styles.capture("markup.link.label") }) end
				append(" (" .. destination .. ")", { styles.capture("markup.link.url") })
			end
			return
		end
		local groups = groups_by_kind[kind] and { styles.capture(groups_by_kind[kind]) } or inherited
		local cursor = first
		local text_chunk = in_link and append or plain
		for child in node:iter_children() do
			if child:named() then
				local start, finish = bounds(child)
				text_chunk(source:sub(cursor + 1, start), groups)
				visit(child, groups, in_link)
				cursor = finish
			end
		end
		text_chunk(source:sub(cursor + 1, last), groups)
	end
	visit(root, {})
	return chunks, false
end

return M
