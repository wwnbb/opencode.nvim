-- Completed /btw answer. The question and answer are deliberately kept out of
-- the session transcript; this module owns only the temporary view.

local M = {}

local highlights = require("opencode.ui.highlights")
local render = require("opencode.ui.chat.render")
local float_context = require("opencode.ui.float_context")

local ns = vim.api.nvim_create_namespace("opencode_btw")
local active
local PROMPT_WIDTH = 60
local ANSWER_WIDTH = 88
local ANSWER_CONTENT_ROWS = 18 -- 20-row TUI scrollbox minus top and bottom padding

local function setup_highlights()
	vim.api.nvim_set_hl(0, "OpenCodeBtwBackground", { link = "NormalFloat", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeBtwRaised", { link = "Pmenu", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeBtwTitle", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeBtwMuted", { link = "Comment", default = true })
end

highlights.register("opencode.ui.btw", setup_highlights)

local function dimensions(kind, question_rows)
	local is_prompt = kind == "prompt"
	local columns = math.max(1, vim.o.columns)
	local rows = math.max(1, vim.o.lines - vim.o.cmdheight)
	local width = math.max(1, math.min(is_prompt and PROMPT_WIDTH or ANSWER_WIDTH, columns - 2))
	local available_height = math.max(1, rows - 2)
	local answer_rows = 0
	local height
	if is_prompt then
		height = math.min(9, available_height)
	else
		-- Shared dialog spacing, including one row above/below the raised box.
		local overhead = 9
		answer_rows = math.max(1, math.min(ANSWER_CONTENT_ROWS, available_height - overhead - (question_rows or 1)))
		height = math.min(available_height, overhead + (question_rows or 1) + answer_rows)
	end
	return {
		width = width,
		height = height,
		row = is_prompt and math.min(math.floor(rows / 4), math.max(0, rows - height))
			or math.floor((rows - height) / 2),
		col = math.floor((columns - width) / 2),
		answer_rows = answer_rows,
		question_rows = question_rows,
	}
end

local function clip(text, width)
	if width <= 0 then return "" end
	if vim.fn.strdisplaywidth(text) <= width then return text end
	local chars = vim.fn.strchars(text)
	while chars > 0 do
		chars = chars - 1
		local candidate = vim.fn.strcharpart(text, 0, chars)
		if vim.fn.strdisplaywidth(candidate) <= width then return candidate end
	end
	return ""
end

local function header(width)
	local left, right = "  /btw", "esc  "
	local gap = width - vim.fn.strdisplaywidth(left .. right)
	return gap >= 1 and (left .. string.rep(" ", gap) .. right) or clip(left, width), gap >= 1
end

local function wrap_lines(text, width)
	local result = {}
	text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    ")
	for _, line in ipairs(vim.split(text, "\n", { plain = true, trimempty = false })) do
		for _, wrapped in ipairs(render.wrap_text(line, width)) do
			result[#result + 1] = wrapped
		end
	end
	if #result == 0 then result[1] = "" end
	return result
end

local function mark(bufnr, line, start_col, end_col, group, priority)
	local buffer_line = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1]
	if not buffer_line then return end
	start_col = math.max(0, math.min(#buffer_line, tonumber(start_col) or 0))
	end_col = math.max(0, math.min(#buffer_line, tonumber(end_col) or 0))
	if end_col > start_col then
		vim.api.nvim_buf_set_extmark(bufnr, ns, line, start_col, {
			end_col = end_col,
			hl_group = group,
			priority = priority,
		})
	end
end

local function create_buffer(filetype, readonly)
	local bufnr = vim.api.nvim_create_buf(false, true)
	local options = vim.bo[bufnr]
	options.buftype = "nofile"
	options.bufhidden = "wipe"
	options.swapfile = false
	options.filetype = filetype
	if readonly then options.modifiable = false end
	return bufnr
end

local function prompt_input_geometry(geometry)
	return {
		row = geometry.row + 3,
		col = geometry.col + 2,
		width = math.max(1, geometry.width - 4),
		height = 1,
	}
end

local function open_window(bufnr, geometry, kind)
	local winid = vim.api.nvim_open_win(bufnr, kind ~= "panel", {
		relative = "editor",
		row = geometry.row,
		col = geometry.col,
		width = geometry.width,
		height = geometry.height,
		style = "minimal",
		border = "none",
		focusable = true,
		zindex = kind == "input" and 91 or 90,
	})
	local options = vim.wo[winid]
	options.winhighlight = "Normal:OpenCodeBtwBackground,NormalNC:OpenCodeBtwBackground,NormalFloat:OpenCodeBtwBackground,EndOfBuffer:OpenCodeBtwBackground"
	if kind == "answer" then
		options.winhighlight = options.winhighlight .. ",Cursor:OpenCodeHiddenCursor,lCursor:OpenCodeHiddenCursor"
	end
	options.winblend = 0
	if kind ~= "input" then options.fillchars = "eob: " end
	if kind ~= "panel" then
		options.wrap = false
		options.number = false
		options.relativenumber = false
		options.signcolumn = "no"
	end
	if kind == "answer" then
		options.foldcolumn = "0"
		options.cursorline = false
		options.scrolloff = 0
	end
	return winid
end

local function write_panel(view, lines)
	local options = vim.bo[view.bufnr]
	options.readonly = false
	options.modifiable = true
	vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
	options.modifiable = false
	options.readonly = true
	vim.api.nvim_buf_clear_namespace(view.bufnr, ns, 0, -1)
end

local function render_answer(text, width)
	local rendered = render.render_content(text, { width = width, scope = "assistant_markdown" })
	local lines = {}
	for _, line in ipairs(rendered) do lines[#lines + 1] = line:content() end
	if #lines == 0 then lines[1] = "" end
	return lines, rendered._opencode_highlights or {}
end

local function result_dimensions(question)
	local width = math.max(1, math.min(ANSWER_WIDTH, vim.o.columns - 2))
	local text_width = math.max(1, width - 4)
	local question_count = #wrap_lines(question, text_width)
	local available_height = math.max(1, vim.o.lines - vim.o.cmdheight - 2)
	-- Reserve one answer row and the fixed dialog spacing on short screens.
	return dimensions("answer", math.min(question_count, math.max(1, available_height - 10)))
end

local function draw(view)
	if active ~= view or not vim.api.nvim_buf_is_valid(view.bufnr) then return end
	local width, height = view.geometry.width, view.geometry.height
	local text_width = math.max(1, width - 4)
	local question_lines = wrap_lines(view.question, text_width)
	local question_count = math.min(#question_lines, view.geometry.question_rows or #question_lines)
	if not view.answer_cache or view.answer_cache.width ~= text_width then
		local answer_lines, answer_highlights = render_answer(view.answer, text_width)
		view.answer_cache = { width = text_width, lines = answer_lines, highlights = answer_highlights }
	end
	local answer_lines = view.answer_cache.lines
	local answer_highlights = view.answer_cache.highlights
	local answer_rows = view.geometry.answer_rows
	view.max_scroll = math.max(0, #answer_lines - answer_rows)
	view.scroll = math.min(math.max(0, view.scroll or 0), view.max_scroll)

	local heading, has_esc = header(width)
	local lines = {}
	local function add_line(value)
		lines[#lines + 1] = value
		return #lines - 1 -- buffer row
	end
	add_line("")
	local header_row = add_line(heading)
	add_line("")
	local question_start = #lines
	for index = 1, question_count do add_line("  " .. question_lines[index]) end
	add_line("")
	local raised_start = add_line("")
	local answer_start = #lines
	for index = 1, answer_rows do
		local answer_line = answer_lines[view.scroll + index]
		add_line(answer_line and ("  " .. answer_line) or "")
	end
	local raised_end = add_line("")
	add_line("")
	local footer = clip(view.copied and "  ✓ copied   ↑/↓ scroll"
		or (view.copy_failed and "  copy failed   ↑/↓ scroll" or "  c copy   ↑/↓ scroll"), width)
	local footer_row = add_line(footer)
	add_line("")
	for index = #lines + 1, height do lines[index] = "" end
	view.footer_row = footer_row + 1 -- 1-based row for mouse hit testing

	write_panel(view, lines)
	for row = raised_start, math.min(raised_end, height - 1) do
		vim.api.nvim_buf_set_extmark(view.bufnr, ns, row, 0, {
			line_hl_group = "OpenCodeBtwRaised",
			priority = 1,
		})
	end
	mark(view.bufnr, header_row, 2, math.min(#heading, 6), "OpenCodeBtwTitle")
	if has_esc then mark(view.bufnr, header_row, #heading - 5, #heading, "OpenCodeBtwMuted") end
	for index = 1, question_count do
		local row = question_start + index - 1
		mark(view.bufnr, row, 2, #lines[row + 1], "OpenCodeBtwMuted")
	end
	for _, highlight in ipairs(answer_highlights) do
		local first_line = tonumber(highlight.line) or 0
		local last_line = tonumber(highlight.end_line) or first_line
		for source_row = first_line, last_line do
			local row = answer_start + source_row - view.scroll
			if row >= answer_start and row < answer_start + answer_rows then
				local source_text = answer_lines[source_row + 1] or ""
				local start_col = source_row == first_line and (highlight.col_start or 0) or 0
				local end_col = source_row == last_line and (highlight.end_col or highlight.col_end or #source_text)
					or #source_text
				mark(view.bufnr, row, 2 + start_col, 2 + end_col, highlight.hl_group, highlight.priority or 4100)
			end
		end
	end
	if view.copied then
		mark(view.bufnr, footer_row, 2, math.min(#footer, 5), "OpenCodeBtwTitle")
		mark(view.bufnr, footer_row, math.min(#footer, 5), #footer, "OpenCodeBtwMuted")
	elseif view.copy_failed then
		mark(view.bufnr, footer_row, 2, #footer, "OpenCodeBtwMuted")
	else
		mark(view.bufnr, footer_row, 2, math.min(#footer, 3), "OpenCodeBtwTitle")
		mark(view.bufnr, footer_row, math.min(#footer, 4), #footer, "OpenCodeBtwMuted")
	end
	if view.winid and vim.api.nvim_win_is_valid(view.winid) then
		vim.api.nvim_win_set_cursor(view.winid, { 1, 0 })
	end
end

local function scroll(delta)
	local view = active
	if not view or not vim.api.nvim_win_is_valid(view.winid) then return end
	local next_scroll = math.min(view.max_scroll, math.max(0, view.scroll + delta))
	if next_scroll ~= view.scroll then
		view.scroll = next_scroll
		draw(view)
	end
end

local function copy_answer()
	local view = active
	if not view or view.kind == "prompt" then return end
	vim.fn.setreg('"', view.answer)
	local copied = false
	for _, register in ipairs({ "+", "*" }) do
		pcall(vim.fn.setreg, register, view.answer)
		local ok, value = pcall(vim.fn.getreg, register)
		if ok and value == view.answer and view.answer ~= "" then
			copied = true
			break
		end
	end
	view.copied = copied
	view.copy_failed = not copied
	draw(view)
end

local function panel_mouse_position(view)
	local mouse = vim.fn.getmousepos()
	if not mouse or tonumber(mouse.winid) ~= view.winid then return nil, nil end
	return tonumber(mouse.winrow or mouse.line) or 0, tonumber(mouse.wincol or mouse.column) or 0
end

local function clicked_escape(view, row, col)
	return row == 2 and col >= view.geometry.width - 4 and col <= view.geometry.width - 2
end

local function answer_click()
	local view = active
	if not view or view.kind == "prompt" then return end
	local row, col = panel_mouse_position(view)
	if not row then return end
	if clicked_escape(view, row, col) then
		M.close()
	elseif row == view.footer_row and col >= 3 and col <= 8 and not view.copied then
		copy_answer()
	end
end

function M.is_visible()
	return active ~= nil and active.winid ~= nil and vim.api.nvim_win_is_valid(active.winid)
end

function M.close()
	local view = active
	if not view then return end
	active = nil
	if view.augroup then pcall(vim.api.nvim_del_augroup_by_id, view.augroup) end
	local current_win = vim.api.nvim_get_current_win()
	local focused = (view.winid and current_win == view.winid)
		or (view.input_winid and current_win == view.input_winid)
	if view.input_winid and vim.api.nvim_win_is_valid(view.input_winid) then
		if current_win == view.input_winid then pcall(vim.cmd, "stopinsert") end
		pcall(vim.api.nvim_win_close, view.input_winid, true)
	end
	if view.winid and vim.api.nvim_win_is_valid(view.winid) then
		pcall(vim.api.nvim_win_close, view.winid, true)
	end
	if view.input_bufnr and vim.api.nvim_buf_is_valid(view.input_bufnr) then
		pcall(vim.api.nvim_buf_delete, view.input_bufnr, { force = true })
	end
	if view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr) then
		pcall(vim.api.nvim_buf_delete, view.bufnr, { force = true })
	end
	if focused then
		-- Match the shared menus: return to the chat before its float focus
		-- handler can treat the underlying editor as a focus-loss close.
		if not float_context.focus_chat_if_visible()
			and view.previous_win and vim.api.nvim_win_is_valid(view.previous_win) then
			pcall(vim.api.nvim_set_current_win, view.previous_win)
		end
	end
end

local function draw_prompt(view)
	if active ~= view or not vim.api.nvim_buf_is_valid(view.bufnr) then return end
	local geometry = view.geometry
	local heading, has_esc = header(geometry.width)
	local lines = {}
	for index = 1, geometry.height do lines[index] = "" end
	lines[2] = heading
	lines[math.max(2, geometry.height - 1)] = clip("  return submit", geometry.width)
	write_panel(view, lines)
	mark(view.bufnr, 1, 2, math.min(#heading, 6), "OpenCodeBtwTitle")
	if has_esc then mark(view.bufnr, 1, #heading - 5, #heading, "OpenCodeBtwMuted") end
	local footer_row = math.max(1, geometry.height - 2)
	mark(view.bufnr, footer_row, 2, #lines[footer_row + 1], "OpenCodeBtwMuted")
	if view.input_winid and vim.api.nvim_win_is_valid(view.input_winid) then
		vim.api.nvim_win_set_config(view.input_winid,
			vim.tbl_extend("force", { relative = "editor" }, prompt_input_geometry(geometry)))
	end
end

local function prompt_click(view)
	if active ~= view then return end
	local row, col = panel_mouse_position(view)
	if not row then return end
	if clicked_escape(view, row, col) then
		M.close()
	elseif view.input_winid and vim.api.nvim_win_is_valid(view.input_winid) then
		vim.api.nvim_set_current_win(view.input_winid)
	end
end

local function install_lifecycle(view, resized_geometry, redraw)
	view.augroup = vim.api.nvim_create_augroup("OpenCodeBtw_" .. view.bufnr, { clear = true })
	vim.api.nvim_create_autocmd("VimResized", {
		group = view.augroup,
		callback = function()
			if active ~= view or not vim.api.nvim_win_is_valid(view.winid) then return end
			view.geometry = resized_geometry(view)
			vim.api.nvim_win_set_config(view.winid, {
				relative = "editor",
				row = view.geometry.row,
				col = view.geometry.col,
				width = view.geometry.width,
				height = view.geometry.height,
			})
			redraw(view)
		end,
	})
	for _, winid in ipairs({ view.winid, view.input_winid }) do
		vim.api.nvim_create_autocmd("WinClosed", {
			group = view.augroup,
			pattern = tostring(winid),
			callback = function() if active == view then M.close() end end,
		})
	end
	vim.api.nvim_create_autocmd("WinEnter", {
		group = view.augroup,
		callback = function()
			vim.schedule(function()
				if active ~= view then return end
				local current = vim.api.nvim_get_current_win()
				if current ~= view.winid and current ~= view.input_winid then M.close() end
			end)
		end,
	})
end

function M.prompt(on_submit)
	M.close()
	local geometry = dimensions("prompt")
	local previous_win = vim.api.nvim_get_current_win()
	local bufnr = create_buffer("opencode_btw", true)
	local winid = open_window(bufnr, geometry, "panel")
	local input_bufnr = create_buffer("opencode_btw_input")
	local input_winid = open_window(input_bufnr, prompt_input_geometry(geometry), "input")
	local view = {
		kind = "prompt",
		bufnr = bufnr,
		winid = winid,
		input_bufnr = input_bufnr,
		input_winid = input_winid,
		previous_win = previous_win,
		geometry = geometry,
	}
	active = view
	draw_prompt(view)
	local placeholder_ns = vim.api.nvim_create_namespace("opencode_btw_placeholder")
	local function update_placeholder()
		if active ~= view or not vim.api.nvim_buf_is_valid(input_bufnr) then return end
		local value = table.concat(vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false), "\n")
		vim.api.nvim_buf_clear_namespace(input_bufnr, placeholder_ns, 0, -1)
		if value == "" then
			vim.api.nvim_buf_set_extmark(input_bufnr, placeholder_ns, 0, 0, {
				virt_text = { { "Ask anything", "OpenCodeBtwMuted" } },
				virt_text_pos = "overlay",
			})
		end
	end
	local function submit()
		if active ~= view then return end
		local value = vim.trim(table.concat(vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false), "\n"))
		if value == "" then return end
		M.close()
		if type(on_submit) == "function" then on_submit(value) end
	end
	local keyopts = { buffer = input_bufnr, noremap = true, silent = true, nowait = true }
	vim.keymap.set({ "i", "n" }, "<Esc>", M.close, keyopts)
	vim.keymap.set({ "i", "n" }, "<C-c>", function()
		local value = table.concat(vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false), "\n")
		if value == "" then M.close(); return end
		vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, { "" })
		vim.api.nvim_win_set_cursor(input_winid, { 1, 0 })
		update_placeholder()
	end, keyopts)
	vim.keymap.set({ "i", "n" }, "<CR>", submit, keyopts)
	vim.keymap.set("n", "q", M.close, keyopts)
	vim.keymap.set("n", "<LeftMouse>", function() prompt_click(view) end,
		{ buffer = bufnr, noremap = true, silent = true, nowait = true })
	vim.keymap.set("n", "<Esc>", M.close, { buffer = bufnr, noremap = true, silent = true, nowait = true })
	install_lifecycle(view, function() return dimensions("prompt") end, draw_prompt)
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = view.augroup,
		buffer = input_bufnr,
		callback = update_placeholder,
	})
	update_placeholder()
	vim.cmd("startinsert")
	return view
end

function M.show(question, answer)
	M.close()
	question, answer = tostring(question or ""), tostring(answer or "")
	local geometry = result_dimensions(question)
	local previous_win = vim.api.nvim_get_current_win()
	local bufnr = create_buffer("opencode_btw", true)
	local winid = open_window(bufnr, geometry, "answer")
	local view = {
		bufnr = bufnr,
		winid = winid,
		previous_win = previous_win,
		question = question,
		answer = answer,
		geometry = geometry,
		scroll = 0,
		max_scroll = 0,
	}
	active = view
	draw(view)
	local keyopts = { buffer = bufnr, noremap = true, silent = true, nowait = true }
	vim.keymap.set("n", "<Esc>", M.close, keyopts)
	vim.keymap.set("n", "<C-c>", M.close, keyopts)
	vim.keymap.set("n", "q", M.close, keyopts)
	vim.keymap.set("n", "c", copy_answer, keyopts)
	vim.keymap.set("n", "<LeftMouse>", answer_click, keyopts)
	vim.keymap.set("n", "<Down>", function() scroll(1) end, keyopts)
	vim.keymap.set("n", "<Up>", function() scroll(-1) end, keyopts)
	vim.keymap.set("n", "j", function() scroll(1) end, keyopts)
	vim.keymap.set("n", "k", function() scroll(-1) end, keyopts)
	vim.keymap.set("n", "<C-d>", function() scroll(20) end, keyopts)
	vim.keymap.set("n", "<C-u>", function() scroll(-20) end, keyopts)
	vim.keymap.set("n", "<PageDown>", function() scroll(20) end, keyopts)
	vim.keymap.set("n", "<PageUp>", function() scroll(-20) end, keyopts)
	vim.keymap.set("n", "<End>", function() scroll(view.max_scroll) end, keyopts)
	vim.keymap.set("n", "<Home>", function() scroll(-view.max_scroll) end, keyopts)
	vim.keymap.set("n", "G", function() scroll(view.max_scroll) end, keyopts)
	vim.keymap.set("n", "gg", function() scroll(-view.max_scroll) end, keyopts)
	install_lifecycle(view, function(current) return result_dimensions(current.question) end, draw)
	return view
end

return M
