-- opencode.nvim - Context attachment module
-- Attach files, buffers, and selections to messages

local M = {}

local Popup = require("nui.popup")
local event = require("nui.utils.autocmd").event

-- State
local state = {
	attachments = {},
	preview_popup = nil,
}

-- Default configuration
local defaults = {
	max_attachments = 10,
	max_file_size = 1024 * 1024, -- 1MB
	include_line_numbers = true,
	supported_filetypes = nil, -- nil = all filetypes
	excluded_patterns = {
		"%.git/",
		"node_modules/",
		"%.lock$",
		"%-lock%.",
	},
	preview = {
		enabled = true,
		height = 10,
		width = 60,
		border = "rounded",
	},
}

-- Check if file should be excluded
local function is_excluded(filepath)
	for _, pattern in ipairs(defaults.excluded_patterns) do
		if filepath:match(pattern) then
			return true
		end
	end
	return false
end

-- Check if file type is supported
local function is_supported_filetype(filetype)
	if not defaults.supported_filetypes then
		return true
	end
	for _, ft in ipairs(defaults.supported_filetypes) do
		if ft == filetype then
			return true
		end
	end
	return false
end

-- Get current buffer content
function M.get_buffer_content(bufnr, opts)
	opts = opts or {}
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if not vim.api.nvim_buf_is_valid(bufnr) then
		return nil, "Invalid buffer"
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local filetype = vim.bo[bufnr].filetype

	-- Check file size
	local content = table.concat(lines, "\n")
	if #content > defaults.max_file_size then
		return nil, "File too large (max " .. defaults.max_file_size .. " bytes)"
	end

	local attachment = {
		type = "buffer",
		filename = filename,
		filetype = filetype,
		content = content,
		line_count = #lines,
		start_line = 1,
		end_line = #lines,
	}

	return attachment
end

-- Get visual selection content
function M.get_visual_selection()
	local bufnr = vim.api.nvim_get_current_buf()

	-- Get visual selection marks
	local start_pos = vim.fn.getpos("'<")
	local end_pos = vim.fn.getpos("'>")

	if start_pos[2] == 0 or end_pos[2] == 0 then
		return nil, "No visual selection"
	end

	local start_line = start_pos[2]
	local start_col = start_pos[3]
	local end_line = end_pos[2]
	local end_col = end_pos[3]

	-- Get lines in selection
	local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

	if #lines == 0 then
		return nil, "Empty selection"
	end

	-- Handle partial first and last lines
	if #lines == 1 then
		lines[1] = lines[1]:sub(start_col, end_col)
	else
		lines[1] = lines[1]:sub(start_col)
		lines[#lines] = lines[#lines]:sub(1, end_col)
	end

	local filename = vim.api.nvim_buf_get_name(bufnr)
	local filetype = vim.bo[bufnr].filetype
	local content = table.concat(lines, "\n")

	if #content > defaults.max_file_size then
		return nil, "Selection too large (max " .. defaults.max_file_size .. " bytes)"
	end

	local attachment = {
		type = "selection",
		filename = filename,
		filetype = filetype,
		content = content,
		line_count = #lines,
		start_line = start_line,
		end_line = end_line,
		start_col = start_col,
		end_col = end_col,
	}

	return attachment
end

-- Read file content
function M.read_file(filepath)
	if is_excluded(filepath) then
		return nil, "File type excluded"
	end

	local file = io.open(filepath, "r")
	if not file then
		return nil, "Cannot read file"
	end

	local content = file:read("*all")
	file:close()

	if #content > defaults.max_file_size then
		return nil, "File too large"
	end

	-- Detect filetype
	local filetype = vim.filetype.match({ filename = filepath }) or "text"

	if not is_supported_filetype(filetype) then
		return nil, "Filetype not supported"
	end

	local lines = vim.split(content, "\n", { plain = true })

	local attachment = {
		type = "file",
		filename = filepath,
		filetype = filetype,
		content = content,
		line_count = #lines,
		start_line = 1,
		end_line = #lines,
	}

	return attachment
end

-- Add attachment
function M.add(attachment)
	if not attachment then
		return false, "Invalid attachment"
	end

	-- Check max attachments
	if #state.attachments >= defaults.max_attachments then
		return false, "Max attachments reached"
	end

	-- Check for duplicates
	for _, existing in ipairs(state.attachments) do
		if existing.filename == attachment.filename and
		   existing.start_line == attachment.start_line and
		   existing.end_line == attachment.end_line then
			return false, "Attachment already exists"
		end
	end

	-- Add timestamp
	attachment.timestamp = os.time()
	attachment.id = tostring(os.time()) .. "_" .. #state.attachments

	table.insert(state.attachments, attachment)
	return true, attachment.id
end

-- Remove attachment
function M.remove(id)
	for i, attachment in ipairs(state.attachments) do
		if attachment.id == id then
			table.remove(state.attachments, i)
			return true
		end
	end
	return false
end

-- Clear all attachments
function M.clear()
	state.attachments = {}
	return true
end

-- Get all attachments
function M.get_all()
	return vim.deepcopy(state.attachments)
end

-- Get attachment by id
function M.get(id)
	for _, attachment in ipairs(state.attachments) do
		if attachment.id == id then
			return vim.deepcopy(attachment)
		end
	end
	return nil
end

-- Count attachments
function M.count()
	return #state.attachments
end

-- Format attachment for display
function M.format_display(attachment)
	if not attachment then
		return ""
	end

	local display_name = vim.fn.fnamemodify(attachment.filename, ":t")
	local prefix = ""

	if attachment.type == "buffer" then
		prefix = "[B] "
	elseif attachment.type == "selection" then
		prefix = "[S] "
		display_name = display_name .. string.format(":%d-%d", attachment.start_line, attachment.end_line)
	elseif attachment.type == "file" then
		prefix = "[F] "
	end

	return prefix .. display_name .. string.format(" (%d lines)", attachment.line_count)
end

-- Preview attachment popup
function M.preview(attachment_id, opts)
	opts = opts or {}

	local attachment = M.get(attachment_id)
	if not attachment then
		vim.notify("Attachment not found", vim.log.levels.WARN)
		return
	end

	if state.preview_popup then
		state.preview_popup:unmount()
	end

	local cfg = defaults.preview
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }

	local width = cfg.width
	local height = cfg.height
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

	-- Create preview lines
	local lines = {
		" File: " .. vim.fn.fnamemodify(attachment.filename, ":~:.") .. " ",
		" Type: " .. attachment.type .. " | Lines: " .. attachment.line_count .. " | FT: " .. attachment.filetype,
		string.rep("─", width - 2),
	}

	-- Add content (truncated if needed)
	local content_lines = vim.split(attachment.content, "\n", { plain = true })
	local max_display_lines = height - #lines - 2

	for i = 1, math.min(#content_lines, max_display_lines) do
		local line = content_lines[i]
		if #line > width - 4 then
			line = line:sub(1, width - 7) .. "..."
		end
		table.insert(lines, line)
	end

	if #content_lines > max_display_lines then
		table.insert(lines, "")
		table.insert(lines, string.format("... (%d more lines)", #content_lines - max_display_lines))
	end

	state.preview_popup = Popup({
		enter = true,
		focusable = true,
		border = {
			style = cfg.border,
			text = {
				top = " Preview ",
				top_align = "center",
			},
		},
		position = { row = row, col = col },
		size = { width = width, height = height },
	})

	state.preview_popup:mount()
	vim.api.nvim_buf_set_lines(state.preview_popup.bufnr, 0, -1, false, lines)

	-- Close on q or Esc
	vim.keymap.set("n", "q", function()
		state.preview_popup:unmount()
		state.preview_popup = nil
	end, { buffer = state.preview_popup.bufnr, noremap = true, silent = true })

	vim.keymap.set("n", "<Esc>", function()
		state.preview_popup:unmount()
		state.preview_popup = nil
	end, { buffer = state.preview_popup.bufnr, noremap = true, silent = true })
end

-- Quick attach current buffer
function M.attach_buffer(bufnr)
	local attachment, err = M.get_buffer_content(bufnr)
	if not attachment then
		vim.notify("Failed to attach buffer: " .. (err or "unknown error"), vim.log.levels.WARN)
		return nil
	end

	local ok, id = M.add(attachment)
	if not ok then
		vim.notify("Failed to add attachment: " .. id, vim.log.levels.WARN)
		return nil
	end

	vim.notify("Attached: " .. M.format_display(attachment), vim.log.levels.INFO)
	return id
end

-- Quick attach visual selection
function M.attach_selection()
	local attachment, err = M.get_visual_selection()
	if not attachment then
		vim.notify("Failed to attach selection: " .. (err or "unknown error"), vim.log.levels.WARN)
		return nil
	end

	local ok, id = M.add(attachment)
	if not ok then
		vim.notify("Failed to add attachment: " .. id, vim.log.levels.WARN)
		return nil
	end

	vim.notify("Attached: " .. M.format_display(attachment), vim.log.levels.INFO)
	return id
end

-- Quick attach file
function M.attach_file(filepath)
	local attachment, err = M.read_file(filepath)
	if not attachment then
		vim.notify("Failed to attach file: " .. (err or "unknown error"), vim.log.levels.WARN)
		return nil
	end

	local ok, id = M.add(attachment)
	if not ok then
		vim.notify("Failed to add attachment: " .. id, vim.log.levels.WARN)
		return nil
	end

	vim.notify("Attached: " .. M.format_display(attachment), vim.log.levels.INFO)
	return id
end

-- Compile all attachments into message context
function M.compile_for_message()
	if #state.attachments == 0 then
		return ""
	end

	local parts = { "<context>" }

	for _, attachment in ipairs(state.attachments) do
		table.insert(parts, string.format("<file name=\"%s\" type=\"%s\" lines=\"%d-%d\">",
			vim.fn.fnamemodify(attachment.filename, ":~:."),
			attachment.filetype,
			attachment.start_line,
			attachment.end_line))
		table.insert(parts, attachment.content)
		table.insert(parts, "</file>")
	end

	table.insert(parts, "</context>")

	return table.concat(parts, "\n")
end

-- Format attachments for display in chat
function M.format_for_chat()
	if #state.attachments == 0 then
		return nil
	end

	local lines = { " Attached Context:", "" }
	for _, attachment in ipairs(state.attachments) do
		table.insert(lines, "  " .. M.format_display(attachment))
	end
	table.insert(lines, "")

	return lines
end

-- Setup function
function M.setup(opts)
	if opts then
		if opts.max_attachments then
			defaults.max_attachments = opts.max_attachments
		end
		if opts.max_file_size then
			defaults.max_file_size = opts.max_file_size
		end
		if opts.excluded_patterns then
			defaults.excluded_patterns = opts.excluded_patterns
		end
		if opts.supported_filetypes then
			defaults.supported_filetypes = opts.supported_filetypes
		end
		if opts.preview then
			defaults.preview = vim.tbl_extend("force", defaults.preview, opts.preview)
		end
	end
end

return M
