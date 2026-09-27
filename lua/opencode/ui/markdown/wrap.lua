-- OpenTUI word wrapping: punctuation breaks, whole grapheme widths, fixed tabs.
-- Keep this local to assistant text; widget/panel wrapping has a different contract.
local M = {}
local cache = require("opencode.util.memo").new("markdown_wrap", { max_entries = 1000 })
local breaks = {}
for char in (" \t-/\\.,;:!?()[]{}"):gmatch(".") do breaks[char] = true end
local ascii_breaks = {}
for char in (" -/\\.,;:!?()[]{}"):gmatch(".") do ascii_breaks[char:byte()] = true end
for _, cp in ipairs({ 0xA0, 0x1680, 0x202F, 0x205F, 0x3000, 0x200B, 0xAD,
	0x2010, 0x3001, 0x3002, 0xFF01, 0xFF0C, 0xFF1A, 0xFF1F }) do breaks[vim.fn.nr2char(cp)] = true end
for cp = 0x2000, 0x200A do breaks[vim.fn.nr2char(cp)] = true end

local function word_class(char)
	if char:match("^[%w_]$") then return "ascii" end
	local cp = vim.fn.char2nr(char)
	if (cp >= 0x3400 and cp <= 0x4DBF) or (cp >= 0x4E00 and cp <= 0x9FFF)
		or (cp >= 0xF900 and cp <= 0xFAFF) or (cp >= 0x20000 and cp <= 0x2A6DF)
		or (cp >= 0x2A700 and cp <= 0x2EE5D) or (cp >= 0x2F800 and cp <= 0x2FA1F)
		or (cp >= 0x3040 and cp <= 0x30FF) or (cp >= 0x31F0 and cp <= 0x31FF)
		or (cp >= 0xFF66 and cp <= 0xFF9D) or (cp >= 0x1100 and cp <= 0x11FF)
		or (cp >= 0x3130 and cp <= 0x318F) or (cp >= 0xA960 and cp <= 0xA97F)
		or (cp >= 0xAC00 and cp <= 0xD7FF) then return "cjk" end
end

local function unicode_ranges(text, width)
	local chars, byte = {}, 0
	for _, char in ipairs(vim.fn.split(text, "\\zs")) do
		local class = word_class(char)
		local previous = chars[#chars]
		if previous and class and previous.class and class ~= previous.class then previous.break_after = true end
		chars[#chars + 1] = { first = byte, last = byte + #char, width = vim.fn.strdisplaywidth(char),
			class = class, break_after = breaks[char] == true, space = char:match("^%s$") ~= nil }
		byte = byte + #char
	end
	local result, first = {}, 1
	while first <= #chars do
		local last, used, boundary, nonspace = first - 1, 0, nil, false
		while last < #chars and used + chars[last + 1].width <= width do
			last = last + 1
			used = used + chars[last].width
			nonspace = nonspace or not chars[last].space
			if chars[last].break_after and nonspace then boundary = last end
		end
		if last < #chars and boundary then last = boundary end
		last = math.max(first, last)
		local finish = last
		while finish > first and chars[finish].space do finish = finish - 1 end
		local start_byte, end_byte = chars[first].first, chars[finish].last
		result[#result + 1] = { text = text:sub(start_byte + 1, end_byte), byte_start = start_byte, byte_end = end_byte }
		first = last + 1
		while chars[first] and chars[first].space do first = first + 1 end
	end
	if #result == 0 then result[1] = { text = "", byte_start = 0, byte_end = 0 } end
	return result
end

-- Printable ASCII has one cell per byte and no CJK class transitions. Preserve
-- the exact boundary/trimming algorithm while avoiding one table per character.
local function ascii_ranges(text, width)
	local result, first, length = {}, 1, #text
	while first <= length do
		local last = math.min(length, first + math.floor(width) - 1)
		local boundary, nonspace
		for index = first, last do
			local byte = text:byte(index)
			nonspace = nonspace or byte ~= 32
			if ascii_breaks[byte] and nonspace then boundary = index end
		end
		if last < length and boundary then last = boundary end
		local finish = last
		while finish > first and text:byte(finish) == 32 do finish = finish - 1 end
		result[#result + 1] = { text = text:sub(first, finish), byte_start = first - 1, byte_end = finish }
		first = last + 1
		while text:byte(first) == 32 do first = first + 1 end
	end
	if #result == 0 then result[1] = { text = "", byte_start = 0, byte_end = 0 } end
	return result
end

local function copy_ranges(ranges)
	local result = {}
	for index, range in ipairs(ranges) do
		result[index] = { text = range.text, byte_start = range.byte_start, byte_end = range.byte_end }
	end
	return result
end

function M.clear_cache()
	cache:clear()
end

function M.ranges(text, width)
	width = math.max(1, width)
	local ascii = not text:find("[^ -~]")
	local signature = tostring(width)
	if not ascii then
		-- strdisplaywidth uses the current window's display rules. setcellwidths
		-- can change without an OptionSet event; include its full current value.
		signature = signature .. ":" .. vim.inspect({ vim.o.ambiwidth, vim.o.emoji,
			vim.o.display, vim.bo.tabstop, vim.bo.vartabstop, vim.fn.getcellwidths() })
	end
	local cached = cache:get(text, signature)
	if cached then return copy_ranges(cached) end
	local ranges = ascii and ascii_ranges(text, width) or unicode_ranges(text, width)
	cache:put(text, signature, ranges)
	return copy_ranges(ranges)
end

return M
