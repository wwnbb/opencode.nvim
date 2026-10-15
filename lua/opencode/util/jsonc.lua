local M = {}

-- JSONC accepts comments and trailing commas, but those sequences inside a
-- quoted string (URLs, regexes, prompt text) must remain untouched.
local function strip_jsonc(input)
	local out, index, quoted = {}, 1, false
	while index <= #input do
		local char, next_char = input:sub(index, index), input:sub(index + 1, index + 1)
		if quoted then
			out[#out + 1] = char
			if char == "\\" then
				out[#out + 1] = next_char
				index = index + 1
			elseif char == '"' then
				quoted = false
			end
		elseif char == '"' then
			quoted = true
			out[#out + 1] = char
		elseif char == "/" and next_char == "/" then
			index = input:find("[\r\n]", index + 2) or (#input + 1)
			out[#out + 1] = "\n"
		elseif char == "/" and next_char == "*" then
			local last = input:find("*/", index + 2, true)
			if not last then error("Unterminated JSONC comment") end
			index = last + 1
			out[#out + 1] = " "
		else
			out[#out + 1] = char
		end
		index = index + 1
	end
	local uncommented = table.concat(out)
	out, index, quoted = {}, 1, false
	while index <= #uncommented do
		local char = uncommented:sub(index, index)
		if quoted then
			out[#out + 1] = char
			if char == "\\" then
				out[#out + 1] = uncommented:sub(index + 1, index + 1)
				index = index + 1
			elseif char == '"' then quoted = false end
		elseif char == '"' then
			quoted = true
			out[#out + 1] = char
		elseif char ~= "," or not uncommented:sub(index + 1):match("^%s*[%]}]")
			or uncommented:sub(1, index - 1):match("[{:,%[]%s*$") then
			out[#out + 1] = char
		end
		index = index + 1
	end
	return table.concat(out)
end

function M.decode(input)
	return vim.json.decode(strip_jsonc(input))
end

return M
