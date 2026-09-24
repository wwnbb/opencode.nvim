-- Fenced code blocks in source text, before chat decoration or wrapping.
local M = {}

function M.normalize_text(text)
	return ((text or ""):gsub("\r\n", "\n"):gsub("\r", " ↵ "):gsub("%z", "<NUL>"))
end

local function opening(line)
	local indent, fence, info = line:match("^( *)(```+)(.*)$")
	if not fence then
		indent, fence, info = line:match("^( *)(~~~+)(.*)$")
	end
	if not fence or #indent > 3 or (fence:sub(1, 1) == "`" and info:find("`", 1, true)) then
		return nil
	end
	return { indent = #indent, marker = fence:sub(1, 1), length = #fence, info = vim.trim(info) }
end

local function closing(line, block)
	local indent, fence, rest = line:match("^( *)([" .. block.marker .. "]+)(.*)$")
	return fence ~= nil and #indent <= 3 and #fence >= block.length and rest:match("^[ \t]*$") ~= nil
end

---Rows are zero-based, end-exclusive. Each body line has a source byte offset
---for the indentation removed before parsing. No UI prefixes enter the parser.
---@param text string normalized source text
---@return table[] blocks
function M.parse(text)
	local lines = vim.split(text, "\n", { plain = true })
	local blocks, active = {}, nil
	for index, line in ipairs(lines) do
		if active then
			if closing(line, active) then
				active.closed = true
				active.end_line = index - 1
				active = nil
			else
				local removed = math.min(active.indent, #(line:match("^ *")))
				active.lines[#active.lines + 1] = line:sub(removed + 1)
				active.offsets[#active.offsets + 1] = removed
			end
		else
			active = opening(line)
			if active then
				active.open_line = index - 1
				active.start_line = index
				active.end_line = #lines
				active.closed = false
				active.lines, active.offsets = {}, {}
				blocks[#blocks + 1] = active
			end
		end
	end
	return blocks
end

return M
