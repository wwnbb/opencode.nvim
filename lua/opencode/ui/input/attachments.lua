-- opencode.nvim - Input clipboard and file attachments

local M = {}

local history = require("opencode.ui.input.history")

local IMAGE_FILE_HINT_PATTERNS = {
	"%.[Aa][Vv][Ii][Ff]",
	"%.[Bb][Mm][Pp]",
	"%.[Gg][Ii][Ff]",
	"%.[Hh][Ee][Ii][Cc]",
	"%.[Jj][Pp][Ee][Gg]",
	"%.[Jj][Pp][Gg]",
	"%.[Pp][Nn][Gg]",
	"%.[Tt][Ii][Ff]",
	"%.[Tt][Ii][Ff][Ff]",
	"%.[Ww][Ee][Bb][Pp]",
	"%.[Ss][Vv][Gg]",
	"%.[Pp][Dd][Ff]",
}

function M.has_image_file_hint(text)
	if type(text) ~= "string" or text == "" then
		return false
	end

	for _, pattern in ipairs(IMAGE_FILE_HINT_PATTERNS) do
		if text:find(pattern) then
			return true
		end
	end
	return false
end

local function is_single_text_value(text)
	return type(text) == "string" and text ~= "" and not text:find("\n", 1, true)
end

function M.insert_text_at_cursor(state, text, schedule_resize)
	if not state.visible or not state.bufnr or not state.winid then
		return false
	end
	if not vim.api.nvim_buf_is_valid(state.bufnr) or not vim.api.nvim_win_is_valid(state.winid) then
		return false
	end

	local content = text or ""
	if content == "" then
		return true
	end

	local lines = vim.split(content, "\n", { plain = true })
	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local row = cursor[1] - 1
	local col = cursor[2]

	vim.api.nvim_buf_set_text(state.bufnr, row, col, row, col, lines)

	local new_row = row + #lines
	local new_col = #lines == 1 and (col + #lines[1]) or #lines[#lines]
	vim.api.nvim_win_set_cursor(state.winid, { new_row, new_col })
	local threshold = (state.config or {}).collapse_paste_lines
	if type(threshold) == "number" and threshold > 1 and #lines >= threshold then
		vim.api.nvim_win_call(state.winid, function()
			vim.wo.foldmethod, vim.wo.foldenable = "manual", true
			vim.cmd((row + 1) .. "," .. new_row .. "fold")
		end)
		state.paste_folds = true
	end

	if schedule_resize then
		schedule_resize()
	end
	return true
end

local function part_marker(part)
	local source = part.type == "file" and type(part.source) == "table" and (part.source.text or part.source)
	return part._marker or type(source) == "table" and source.value or nil
end

local function next_file_marker(state, label)
	local index = 0
	for _, part in ipairs(state.parts or {}) do
		local marker = part_marker(part)
		local number = type(marker) == "string" and tonumber(marker:match("^%[" .. label .. " (%d+)%]$"))
		index = math.max(index, number or 0)
	end
	return "[" .. label .. " " .. (index + 1) .. "]"
end

function M.add_file_part(state, content, opts, insert_text_at_cursor)
	if type(content) ~= "table" or type(content.data) ~= "string" or content.data == "" then
		return nil
	end

	opts = opts or {}
	if not state.visible then
		state.parts = history.get_pending_parts()
	end

	local mime = content.mime or "application/octet-stream"
	local is_image = mime:match("^image/") ~= nil
	local marker = next_file_marker(state, is_image and "Image" or "File")
	local filename = content.filename
	if not filename or filename == "" then
		filename = is_image and "clipboard.png" or "clipboard"
	end

	table.insert(state.parts, {
		type = "file",
		mime = mime,
		filename = filename,
		url = "data:" .. mime .. ";base64," .. content.data,
		source = {
			type = "file",
			path = content.filepath or filename,
			text = {
				start = 0,
				["end"] = #marker,
				value = marker,
			},
		},
		_marker = marker,
	})

	if opts.insert == false then
		return marker
	end

	if state.visible then
		insert_text_at_cursor(marker .. " ")
	else
		history.append_pending(marker .. " ")
		history.set_pending_parts(state.parts)
	end

	return marker
end

function M.active_parts_for_text(state, text)
	local active = {}

	for _, part in ipairs(state.parts or {}) do
		local marker = part_marker(part)
		if type(marker) ~= "string" or (text or ""):find(marker, 1, true) then
			local copy = vim.deepcopy(part)
			copy._marker = nil
			table.insert(active, copy)
		end
	end

	return active
end

-- Merge recalled/queued drafts without colliding their attachment markers.
function M.merge_drafts(current, incoming)
	local parts, text = history.copy_parts(current.parts), incoming.text or ""
	-- Reserve the incoming markers too, so replacements cannot rewrite a later
	-- attachment's original marker (or cascade an earlier replacement).
	local reserved = vim.list_extend({}, parts)
	vim.list_extend(reserved, incoming.parts or {})
	for _, original in ipairs(incoming.parts or {}) do
		local part = vim.deepcopy(original)
		part._mention = nil
		local marker = part_marker(part)
		if part.type == "file" and type(marker) == "string" then
			local collision = false
			for _, existing in ipairs(parts) do if part_marker(existing) == marker then collision = true end end
			if collision then
				local replacement = next_file_marker({ parts = reserved }, (part.mime or ""):match("^image/") and "Image" or "File")
				text = text:gsub(marker:gsub("(%W)", "%%%1"), function() return replacement end)
				part._marker = replacement
				local source = type(part.source) == "table" and (part.source.text or part.source)
				if type(source) == "table" then source.value, source.start, source["end"] = replacement, -1, -1 end
			end
		end
		parts[#parts + 1] = part
		reserved[#reserved + 1] = part
	end
	local prefix = current.text or ""
	return (prefix ~= "" and text ~= "") and (prefix .. "\n\n" .. text) or prefix .. text, parts
end

local function find_image_path_in_line(line, clipboard)
	local trimmed = vim.trim(line or "")
	if trimmed == "" or not M.has_image_file_hint(trimmed) then
		return nil, nil, nil
	end

	local content = clipboard.image_from_text(trimmed)
	if content then
		local start_col = line:find(trimmed, 1, true) or 1
		return start_col, start_col + #trimmed - 1, content
	end

	local lower = string.lower(line)
	local patterns = {
		"file:/+[^%s]+%.png",
		"file:/+[^%s]+%.jpg",
		"file:/+[^%s]+%.jpeg",
		"file:/+[^%s]+%.gif",
		"file:/+[^%s]+%.webp",
		"file:/+[^%s]+%.bmp",
		"file:/+[^%s]+%.tiff",
		"file:/+[^%s]+%.tif",
		"file:/+[^%s]+%.heic",
		"file:/+[^%s]+%.avif",
		"file:/+[^%s]+%.svg",
		"file:/+[^%s]+%.pdf",
		"/.*%.png",
		"/.*%.jpg",
		"/.*%.jpeg",
		"/.*%.gif",
		"/.*%.webp",
		"/.*%.bmp",
		"/.*%.tiff",
		"/.*%.tif",
		"/.*%.heic",
		"/.*%.avif",
		"/.*%.svg",
		"/.*%.pdf",
	}

	for _, pattern in ipairs(patterns) do
		-- Match a complete filename, never the image prefix of ".png.bak".
		local start_col, end_col = lower:find(pattern .. "%f[%s'\"%)%]%}%z]")
		-- Never retry a rejected URI as a plain filesystem path.
		if start_col and (pattern:sub(1, 1) ~= "/" or line:sub(start_col - 1, start_col - 1) ~= ":") then
			local candidate = line:sub(start_col, end_col)
			content = clipboard.image_from_text(candidate)
			if content then
				return start_col, end_col, content
			end
		end
	end

	return nil, nil, nil
end

-- Tokenize paths without invoking a shell. Retain byte ranges and outer quotes.
local function file_paths_in_line(line, clipboard)
	local trimmed = vim.trim(line)
	if M.has_image_file_hint(trimmed) then
		local exact = clipboard.image_from_text(trimmed)
		if exact then local first = line:find(trimmed, 1, true); return { { first, first + #trimmed - 1, exact } } end
	end
	local matches, i = {}, 1
	while i <= #line do
		if line:sub(i, i):match("%s") then i = i + 1
		else
			local quote = line:sub(i, i)
			if quote ~= "'" and quote ~= '"' then quote = nil end
			local first = i + (quote and 1 or 0)
			local last = first
			while last <= #line do
				local char = line:sub(last, last)
				if char == "\\" and last < #line then last = last + 2
				elseif (quote and char == quote) or (not quote and char:match("%s")) then break
				else last = last + 1 end
			end
			local candidate = line:sub(first, last - 1)
			if M.has_image_file_hint(candidate) then
				local content = clipboard.image_from_text(candidate)
				if content then matches[#matches + 1] = { first, last - 1, content } end
			end
			i = math.max(i + 1, last + (quote and 1 or 0))
		end
	end
	-- A single unquoted filename can contain spaces. Keep the established exact
	-- path fallback, without guessing boundaries between several such filenames.
	if #matches == 0 then
		local first, last, content = find_image_path_in_line(line, clipboard)
		if content then matches[1] = { first, last, content } end
	end
	return matches
end

function M.normalize_pasted_image_paths(state, resize)
	if state.normalizing_paste or not state.visible or not state.bufnr then
		return
	end
	if not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local ok, clipboard = pcall(require, "opencode.clipboard")
	if not ok then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local changed = false

	for idx, line in ipairs(lines) do
		local pieces, offset = {}, 1
		for _, match in ipairs(file_paths_in_line(line, clipboard)) do
			local start_col, end_col, content = unpack(match)
			local marker = M.add_file_part(state, content, { insert = false })
			if marker then
				pieces[#pieces + 1] = line:sub(offset, start_col - 1) .. marker
				offset = end_col + 1
				changed = true
			end
		end
		if offset > 1 then pieces[#pieces + 1] = line:sub(offset); lines[idx] = table.concat(pieces) end
	end

	if not changed then
		return
	end

	state.normalizing_paste = true
	local cursor = state.winid and vim.api.nvim_win_is_valid(state.winid) and vim.api.nvim_win_get_cursor(state.winid)
		or nil
	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
	if cursor then
		local row = math.min(cursor[1], #lines)
		local col = math.min(cursor[2], #(lines[row] or ""))
		pcall(vim.api.nvim_win_set_cursor, state.winid, { row, col })
	end
	state.normalizing_paste = false

	if resize then
		resize()
	end
end

function M.paste_clipboard(state, handlers)
	local ok, clipboard = pcall(require, "opencode.clipboard")
	if not ok then
		vim.notify("Failed to load clipboard helper: " .. tostring(clipboard), vim.log.levels.ERROR)
		return false
	end

	local content = clipboard.read()
	-- Clipboard subprocess waits can dispatch events that switch the composer.
	if handlers.is_current and not handlers.is_current() then return false end
	if not content then
		vim.notify("Clipboard is empty or unsupported", vim.log.levels.WARN)
		return false
	end

	if type(content.mime) == "string" and content.mime:match("^image/") then
		handlers.add_file_part(content)
		return true
	end

	if content.mime == "text/plain" then
		if is_single_text_value(content.data) and M.has_image_file_hint(content.data) then
			local image = clipboard.image_from_text(content.data)
			if handlers.is_current and not handlers.is_current() then return false end
			if image then
				handlers.add_file_part(image)
				return true
			end
		end

		if state.visible then
			handlers.insert_text_at_cursor(content.data)
			if M.has_image_file_hint(content.data) then
				handlers.normalize_pasted_image_paths()
			end
		else
			history.append_pending(content.data)
		end
		return true
	end

	vim.notify("Unsupported clipboard content: " .. tostring(content.mime), vim.log.levels.WARN)
	return false
end

return M
