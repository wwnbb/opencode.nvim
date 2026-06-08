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

	if schedule_resize then
		schedule_resize()
	end
	return true
end

local function count_file_parts(state, mime)
	local count = 0
	local image = type(mime) == "string" and mime:match("^image/") ~= nil

	for _, part in ipairs(state.parts or {}) do
		if part.type == "file" then
			if image and type(part.mime) == "string" and part.mime:match("^image/") then
				count = count + 1
			elseif not image and part.mime == mime then
				count = count + 1
			end
		end
	end

	return count
end

function M.add_file_part(state, content, opts, insert_text_at_cursor)
	if type(content) ~= "table" or type(content.data) ~= "string" or content.data == "" then
		return nil
	end

	opts = opts or {}
	if not state.visible and #state.parts == 0 then
		state.parts = history.get_pending_parts()
	end

	local mime = content.mime or "application/octet-stream"
	local is_image = mime:match("^image/") ~= nil
	local marker = is_image and ("[Image " .. tostring(count_file_parts(state, mime) + 1) .. "]")
		or ("[File " .. tostring(#state.parts + 1) .. "]")
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
		local marker = part._marker
		if type(marker) ~= "string" or (text or ""):find(marker, 1, true) then
			local copy = vim.deepcopy(part)
			copy._marker = nil
			table.insert(active, copy)
		end
	end

	return active
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
		"file://[^%s]+%.png",
		"file://[^%s]+%.jpg",
		"file://[^%s]+%.jpeg",
		"file://[^%s]+%.gif",
		"file://[^%s]+%.webp",
		"file://[^%s]+%.bmp",
		"file://[^%s]+%.tiff",
		"file://[^%s]+%.tif",
		"file://[^%s]+%.heic",
		"file://[^%s]+%.avif",
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
	}

	for _, pattern in ipairs(patterns) do
		local start_col, end_col = lower:find(pattern)
		if start_col then
			local candidate = line:sub(start_col, end_col)
			content = clipboard.image_from_text(candidate)
			if content then
				return start_col, end_col, content
			end
		end
	end

	return nil, nil, nil
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
		local start_col, end_col, content = find_image_path_in_line(line, clipboard)
		if start_col and end_col and content then
			local marker = M.add_file_part(state, content, { insert = false })
			if marker then
				lines[idx] = line:sub(1, start_col - 1) .. marker .. line:sub(end_col + 1)
				changed = true
			end
		end
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
