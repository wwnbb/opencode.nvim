local M = {}

local TRUNCATED = "… truncated; open Raw for full output"
local MAX_PARSE_CHARS = 1024 * 1024
local MAX_OBJECT_FIELDS = 10000

local function utf8_prefix(value, bytes)
	bytes = math.max(0, bytes)
	if bytes >= #value then
		return value
	end
	while bytes > 0 do
		local next_byte = value:byte(bytes + 1)
		if not next_byte or next_byte < 128 or next_byte >= 192 then
			break
		end
		bytes = bytes - 1
	end
	return value:sub(1, bytes)
end

local function each_line(value, callback)
	local start = 1
	while true do
		local stop = value:find("\n", start, true)
		local line = value:sub(start, stop and stop - 1 or #value):gsub("\r$", "")
		if callback(line) == false or not stop then
			break
		end
		start = stop + 1
	end
end

local function writer(opts)
	local result = { lines = {}, chars = 0, truncated = false }
	local max_lines = math.max(1, opts.max_lines or 2000)
	local max_chars = math.max(1, opts.max_chars or 200000)
	function result.add(line)
		if result.truncated then
			return false
		end
		if #result.lines >= max_lines then
			result.truncated = true
			return false
		end
		local remaining = max_chars - result.chars
		if #line > remaining then
			line = utf8_prefix(line, remaining)
			result.truncated = true
		end
		result.lines[#result.lines + 1] = line
		result.chars = result.chars + #line
		return not result.truncated
	end
	function result.finish()
		if result.truncated then
			local marker = utf8_prefix(TRUNCATED, max_chars)
			while #result.lines >= max_lines do
				result.chars = result.chars - #table.remove(result.lines)
			end
			while #result.lines > 0 and result.chars + #marker > max_chars do
				local last = table.remove(result.lines)
				local clipped = utf8_prefix(last, #last - (result.chars + #marker - max_chars))
				result.chars = result.chars - #last + #clipped
				if clipped ~= "" then
					result.lines[#result.lines + 1] = clipped
				end
			end
			result.lines[#result.lines + 1] = marker
		end
		return result.lines
	end
	return result
end

-- Parsing is bounded independently of the preview budget. A short preview can
-- still decode a normal result, but pathological/deep results remain available
-- in Raw without expensive parsing or recursive formatting.
local function decode(value)
	if #value > MAX_PARSE_CHARS then
		return false
	end
	local first = value:match("^%s*(.)")
	if not first or not first:match('[{%["tfn%d%-]') then
		return false
	end
	local depth, quoted, escaped = 0, false, false
	for index = 1, #value do
		local byte = value:byte(index)
		if quoted then
			if escaped then
				escaped = false
			elseif byte == 92 then
				escaped = true
			elseif byte == 34 then
				quoted = false
			end
		elseif byte == 34 then
			quoted = true
		elseif byte == 123 or byte == 91 then
			depth = depth + 1
			if depth > 128 then
				return false
			end
		elseif byte == 125 or byte == 93 then
			depth = depth - 1
		end
	end
	return pcall(vim.json.decode, value)
end

-- Execute can return a JSON value followed by log text. Recognize only a
-- complete leading value with a newline boundary; the remaining text stays
-- untouched, regardless of its heading or provider.
local function decode_with_suffix(raw)
	if #raw > MAX_PARSE_CHARS then
		return false
	end
	local start = raw:find("%S")
	if not start then
		return false
	end
	local first = raw:sub(start, start)
	local stop
	if first == "{" or first == "[" or first == '"' then
		local depth, quoted, escaped = 0, false, false
		for index = start, #raw do
			local char = raw:sub(index, index)
			if quoted then
				if escaped then
					escaped = false
				elseif char == "\\" then
					escaped = true
				elseif char == '"' then
					quoted = false
				end
			elseif char == '"' then
				quoted = true
			elseif char == "{" or char == "[" then
				depth = depth + 1
				if depth > 128 then
					return false
				end
			elseif char == "}" or char == "]" then
				depth = depth - 1
			end
			if not quoted and depth == 0 then
				stop = index
				break
			end
		end
	else
		local newline = raw:find("\n", start, true)
		stop = newline and newline - 1
	end
	if not stop then
		return false
	end
	local suffix = raw:sub(stop + 1)
	if not suffix:match("^%s*\n") then
		return false
	end
	local ok, value = decode(raw:sub(1, stop))
	return ok, value, (suffix:gsub("^[ \t\r]*\n", "", 1))
end

local function is_list(value)
	return (vim.islist or vim.tbl_islist)(value)
end

local function ordered_keys(value)
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
		if #keys > MAX_OBJECT_FIELDS then
			return nil
		end
	end
	local function long(key)
		return type(value[key]) == "string" and #value[key] > 240
	end
	table.sort(keys, function(a, b)
		if long(a) ~= long(b) then
			return not long(a)
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function key_label(key)
	local text = tostring(key)
	if text:match("^[%w_.%-]+$") then
		return text
	end
	return vim.json.encode(text)
end

local function summary_line(value, opts)
	local limit = math.max(1, math.min(240, opts.max_chars or 200000))
	local start = value:find("%S")
	if not start then
		return nil
	end
	local bounded = utf8_prefix(value:sub(start), limit + 4)
	local line = vim.trim(bounded:match("^[^\r\n]*") or "")
	if #line > limit then
		return utf8_prefix(line, math.max(0, limit - #"…")) .. (limit >= #"…" and "…" or "")
	end
	return line ~= "" and line or nil
end

-- Summaries are a separate view of the data: keep wrapper text and original
-- field ordering in the readable result, but prefer a concise primitive over
-- arrays, objects, or a page-sized string when summarizing a JSON object.
local function json_summary(value, opts)
	local function primitive(item, prefix, short)
		if type(item) == "table" then
			return nil
		end
		local text = item == vim.NIL and "null" or tostring(item)
		if short and (#text > 240 or text:find("[\r\n]")) then
			return nil
		end
		local line = summary_line(text, opts)
		return line and summary_line(prefix .. line, opts) or nil
	end
	if type(value) ~= "table" then
		return primitive(value, "", false)
	end
	local list = is_list(value)
	local keys = list and nil or ordered_keys(value)
	if not list and not keys then
		return nil
	end
	local count = list and #value or #keys
	if count == 0 then
		return list and "[]" or "{}"
	end
	local fallback
	for index = 1, math.min(count, MAX_OBJECT_FIELDS) do
		local key = list and index or keys[index]
		local prefix = list and "" or (key_label(key) .. ": ")
		local short = primitive(value[key], prefix, true)
		if short then
			return short
		end
		fallback = fallback or primitive(value[key], prefix, false)
	end
	return fallback or summary_line(tostring(count) .. (list and " items" or " fields"), opts)
end

local function readable(value, out, opts)
	out.summary = out.summary or json_summary(value, opts)
	local seen = {}
	local function visit(item, indent, prefix, depth)
		if out.truncated then
			return
		end
		local padding = string.rep("  ", indent)
		if type(item) ~= "table" or item == vim.NIL then
			local text = item == vim.NIL and "null" or tostring(item)
			if type(item) == "string" then
				text = item == "" and '""' or item
			end
			if text:find("\n", 1, true) and prefix ~= "" then
				out.add(padding .. prefix:gsub("%s+$", ""))
				padding = padding .. "  "
				prefix = ""
			end
			each_line(text, function(line)
				return out.add(padding .. prefix .. line)
			end)
			return
		end
		local list = is_list(item)
		if next(item) == nil then
			out.add(padding .. prefix .. (list and "[]" or "{}"))
			return
		end
		if seen[item] or depth >= (opts.max_depth or 24) then
			out.add(padding .. prefix .. "… depth limit; open Raw for full output")
			out.omitted = true
			return
		end
		if prefix ~= "" then
			out.add(padding .. prefix:gsub("%s+$", ""))
			indent = indent + 1
		end
		seen[item] = true
		if list then
			for _, child in ipairs(item) do
				visit(child, indent, "- ", depth + 1)
				if out.truncated then
					break
				end
			end
		else
			local keys = ordered_keys(item)
			if not keys then
				out.add(padding .. "… object too large; open Raw for full output")
				out.omitted = true
			else
				for _, key in ipairs(keys) do
					visit(item[key], indent, key_label(key) .. ": ", depth + 1)
					if out.truncated then
						break
					end
				end
			end
		end
		seen[item] = nil
	end
	visit(value, 0, "", 0)
end

local function raw_string(value)
	if type(value) == "string" then
		return value
	end
	if value == nil then
		return ""
	end
	local ok, encoded = pcall(vim.json.encode, value)
	if ok then
		return encoded
	end
	return vim.inspect(value, { depth = 8 })
end

local function format_fences(raw, out, opts, format_json, scan_all)
	format_json = format_json or readable
	local block, fence, opener, literal_fence
	each_line(raw, function(line)
		if literal_fence then
			out.add(line)
			local closing = line:match("^%s*([`~]+)%s*$")
			if closing and #closing >= #literal_fence and closing:sub(1, 1) == literal_fence:sub(1, 1) then
				literal_fence = nil
			end
		elseif block then
			local closing = line:match("^%s*([`~]+)%s*$")
			if closing and #closing >= #fence and closing:sub(1, 1) == fence:sub(1, 1) then
				local ok, value = decode(table.concat(block, "\n"))
				if ok then
					format_json(value, out, opts)
				else
					out.add(opener)
					for _, original in ipairs(block) do
						if not out.add(original) then
							break
						end
					end
					out.add(line)
				end
				block, fence, opener = nil, nil, nil
			else
				block[#block + 1] = line
			end
		else
			local opening = line:match("^%s*([`~]+)[jJ][sS][oO][nN]%s*$")
			if opening and (#opening >= 3) and (opening:match("^`+$") or opening:match("^~+$")) then
				block, fence, opener = {}, opening, line
			else
				out.add(line)
				local other = line:match("^%s*([`~]+)")
				if other and #other >= 3 and (other:match("^`+$") or other:match("^~+$")) then
					literal_fence = other
				end
			end
		end
		return scan_all or not out.truncated
	end)
	if block and (scan_all or not out.truncated) then
		out.add(opener)
		for _, line in ipairs(block) do
			if not out.add(line) then
				break
			end
		end
	end
end

-- The document and inline field views share the same bounded writer. Keep the
-- original readable lines for callers that need a compact tree, while giving
-- the UI real field boundaries instead of making it parse "key: value" text.
local function presentation(raw, parsed, is_json, suffix, opts)
	local out = writer(opts)
	local objects, headings = {}, {}
	local function document(value)
		local record = { start_line = #out.lines + 1 }
		objects[#objects + 1] = record
		local keys = type(value) == "table" and not is_list(value) and ordered_keys(value) or nil
		if not keys or #keys == 0 then
			readable(value, out, opts)
		else
			record.fields, record.count = {}, #keys
			for index, key in ipairs(keys) do
				if out.truncated then
					break
				end
				if index > 1 then
					out.add("")
				end
				local label = tostring(key)
				if label:find("[%c]") then
					label = key_label(key)
				end
				local field = { key = label, heading = #out.lines + 1 }
				record.fields[#record.fields + 1] = field
				headings[#headings + 1] = field
				out.add(label)
				field.start_line = #out.lines + 1
				local child_opts = vim.tbl_extend("force", opts, { max_depth = math.max(0, (opts.max_depth or 24) - 1) })
				readable(value[key], out, child_opts)
				field.end_line = #out.lines
			end
		end
		record.end_line = #out.lines
	end
	if is_json then
		document(parsed)
		if suffix then
			each_line(suffix, out.add)
		end
	elseif #raw <= MAX_PARSE_CHARS and raw:find("[`~][`~][`~]") then
		-- Scan all fences even after the preview budget runs out. Otherwise a
		-- later JSON block could be silently misrepresented as the first object.
		format_fences(raw, out, opts, document, true)
	else
		each_line(raw, out.add)
	end
	local result = {
		document_lines = out.finish(),
		document_headings = {},
		document_truncated = out.truncated or out.omitted or false,
	}
	for _, field in ipairs(headings) do
		if result.document_lines[field.heading] == field.key then
			result.document_headings[#result.document_headings + 1] = field.heading
		end
	end
	local function slice(first, last)
		local lines = {}
		for index = first, math.min(last, #result.document_lines) do
			lines[#lines + 1] = result.document_lines[index]
		end
		return lines
	end
	if #objects == 1 and objects[1].fields then
		local record = objects[1]
		result.fields, result.field_count = {}, record.count
		result.prefix_lines = slice(1, record.start_line - 1)
		result.suffix_lines = slice(record.end_line + 1, #result.document_lines)
		for _, field in ipairs(record.fields) do
			if result.document_lines[field.heading] == field.key then
				result.fields[#result.fields + 1] = { key = field.key, lines = slice(field.start_line, field.end_line) }
			end
		end
	end
	return result
end

---Build a bounded readable result without changing the source output.
---@param value any
---@param opts? { max_lines?: integer, max_chars?: integer, max_depth?: integer }
---@return { raw: string, lines: string[], summary: string, label: string, kind: string, filetype: string, truncated: boolean, count?: integer, count_label?: string }
function M.describe(value, opts)
	opts = opts or {}
	local raw = raw_string(value)
	local out = writer(opts)
	local result = { raw = raw, label = "Text", kind = "text", filetype = "text" }
	local ok, parsed = decode(raw)
	local suffix
	if not ok then
		ok, parsed, suffix = decode_with_suffix(raw)
	end
	if ok then
		result.label, result.kind = "JSON", "json"
		if type(parsed) == "table" then
			local list = is_list(parsed)
			local keys = not list and ordered_keys(parsed) or nil
			result.count = list and #parsed or (keys and #keys or nil)
			result.count_label = list and "items" or "fields"
		end
		readable(parsed, out, opts)
		if suffix then
			each_line(suffix, out.add)
		end
	elseif #raw <= MAX_PARSE_CHARS and raw:find("[`~][`~][`~]") then
		format_fences(raw, out, opts)
		result.label, result.kind, result.filetype = "Markdown", "markdown", "markdown"
	else
		each_line(raw, out.add)
		if raw:match("^#+ ") or raw:find("\n#+ ") then
			result.label, result.kind, result.filetype = "Markdown", "markdown", "markdown"
		end
	end
	result.lines, result.truncated = out.finish(), out.truncated or out.omitted or false
	result.summary = out.summary
	if not result.summary then
		for _, line in ipairs(result.lines) do
			result.summary = summary_line(line, opts)
			if result.summary then
				break
			end
		end
	end
	result.summary = result.summary or ""
	for key, item in pairs(presentation(raw, parsed, ok, suffix, opts)) do
		result[key] = item
	end
	return result
end

return M
