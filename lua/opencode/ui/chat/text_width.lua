-- opencode.nvim - Display width and wrapping for chat text
-- Pure helpers: callers pass a width context carrying the buffer's tabstop, so
-- nothing here reads a view or window.
local M = {}

---@param tabstop number
---@return table width_context
function M.new_context(tabstop)
	return {
		tabstop = tabstop,
		char_widths = {},
	}
end

---@param text any
---@return string
function M.sanitize_buffer_line(text)
	text = type(text) == "string" and text or tostring(text or "")
	if not text:find("[\r\n%z]") then return text end
	return (text:gsub("\r\n", " ↵ "):gsub("\n", " ↵ "):gsub("\r", " ↵ "):gsub("%z", "<NUL>"))
end

-- Neovim keeps combining marks with their base character. Index these strings
-- once; ordinary text keeps the direct UTF-8 scan.
local function character_lengths(text)
	if not text:find("[\128-\255]") or vim.fn.strchars(text) == vim.fn.strchars(text, true) then
		return nil
	end
	local lengths, byte_pos = {}, 0
	for _, ch in ipairs(vim.fn.split(text, "\\zs")) do
		if #ch > 1 then lengths[byte_pos] = #ch end
		byte_pos = byte_pos + #ch
	end
	return lengths
end

---@param text string
---@param byte_pos number 0-based byte offset
---@return number length
local function utf8_char_len_at(text, byte_pos, lengths)
	if lengths then return lengths[byte_pos] or 1 end
	local first = text:byte(byte_pos + 1)
	if not first then
		return 0
	end
	local length
	if first < 0x80 then
		length = 1
	elseif first < 0xE0 then
		length = 2
	elseif first < 0xF0 then
		length = 3
	elseif first < 0xF8 then
		length = 4
	else
		length = 1
	end
	return math.min(length, #text - byte_pos)
end

---@param width_context table
---@param ch string
---@param col number
---@return number
function M.char_width(width_context, ch, col)
	if ch == "\t" then
		return width_context.tabstop - (col % width_context.tabstop)
	end

	local cached = width_context.char_widths[ch]
	if cached ~= nil then
		return cached
	end

	local ok, measured = pcall(vim.api.nvim_strwidth, ch)
	local width = ok and type(measured) == "number" and measured or #ch
	width_context.char_widths[ch] = width
	return width
end

---@param text string
---@param initial_col number
---@param width_context table
---@return number
function M.width_from_col(text, initial_col, width_context)
	local width = 0
	local byte_pos = 0
	local lengths = character_lengths(text)
	while byte_pos < #text do
		local char_len = utf8_char_len_at(text, byte_pos, lengths)
		local ch = text:sub(byte_pos + 1, byte_pos + char_len)
		width = width + M.char_width(width_context, ch, initial_col + width)
		byte_pos = byte_pos + char_len
	end
	return width
end

---Wrap a string to fit within max_width, breaking at word boundaries.
---@param text string
---@param max_width number
---@param opts? table
---@param width_context table
---@return table[] chunks
---@return number[] widths Display width of each chunk
function M.wrap_with_ranges(text, max_width, opts, width_context)
	opts = opts or {}
	text = M.sanitize_buffer_line(text)
	local result = {}
	local widths = {}
	if max_width <= 0 then
		return {
			{
				text = text,
				byte_start = 0,
				byte_end = #text,
			},
		}, { 0 }
	end
	local initial_col = tonumber(opts.initial_col) or 0
	if #text == 0 then
		return {
			{
				text = text,
				byte_start = 0,
				byte_end = #text,
			},
		}, { 0 }
	end

	local line_start = 0
	local lengths = character_lengths(text)
	while line_start < #text do
		local byte_pos = line_start
		local line_width = 0
		local last_space_byte
		local last_space_width
		local last_space_content_width
		local last_nonspace_width = 0
		local overflow_width

		while byte_pos < #text do
			local char_len = utf8_char_len_at(text, byte_pos, lengths)
			local ch = text:sub(byte_pos + 1, byte_pos + char_len)
			local char_width = M.char_width(width_context, ch, initial_col + line_width)
			if line_width + char_width > max_width then
				overflow_width = char_width
				break
			end

			line_width = line_width + char_width
			byte_pos = byte_pos + char_len
			if ch:match("%s") then
				last_space_byte = byte_pos
				last_space_width = line_width
				last_space_content_width = last_nonspace_width
			else
				last_nonspace_width = line_width
			end
		end

		if byte_pos >= #text then
			table.insert(result, {
				text = text:sub(line_start + 1),
				byte_start = line_start,
				byte_end = #text,
			})
			table.insert(widths, line_width)
			break
		end

		local cut_at_space = last_space_byte and last_space_byte > line_start
		local cut = cut_at_space and last_space_byte or byte_pos
		if cut <= line_start then
			cut = line_start + utf8_char_len_at(text, line_start, lengths)
		end

		local raw_piece = text:sub(line_start + 1, cut)
		local piece = raw_piece:gsub("%s+$", "")
		local piece_width
		if piece == "" then
			piece = raw_piece
			piece_width = last_space_width or overflow_width or line_width
		elseif cut_at_space then
			piece_width = last_space_content_width
		else
			piece_width = byte_pos == line_start and overflow_width or line_width
		end
		local piece_end = line_start + #piece
		table.insert(result, {
			text = piece,
			byte_start = line_start,
			byte_end = piece_end,
		})
		table.insert(widths, piece_width)

		local next_start = cut
		if cut_at_space and text:sub(next_start + 1, next_start + 1):match("%s") then
			next_start = next_start + 1
		end
		line_start = next_start
	end
	return result, widths
end

return M
