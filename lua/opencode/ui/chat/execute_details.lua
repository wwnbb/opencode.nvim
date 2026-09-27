-- Read-only inspector for execute results, original output, code, and MCP calls.
local M = {}

local float = require("opencode.ui.float")
local output = require("opencode.ui.chat.execute_output")
local ns = vim.api.nvim_create_namespace("opencode_execute_details")
local active
local views = { "result", "raw", "code", "calls" }
local labels = { result = "Result", raw = "Raw", code = "Code", calls = "Calls" }

require("opencode.ui.highlights").register("opencode.ui.chat.execute_details", function()
	local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
	for name, source in pairs({ Normal = "Normal", Muted = "Comment", Accent = "String", Active = "String" }) do
		local color = vim.api.nvim_get_hl(0, { name = source, link = false })
		vim.api.nvim_set_hl(0, "OpenCodeExecuteDetails" .. name, {
			fg = color.fg or normal.fg, bg = normal.bg,
			bold = false, italic = false, underline = name == "Active",
		})
	end
end)


local function tool_data(part)
	local state = type(part.state) == "table" and part.state or {}
	local metadata = vim.tbl_extend("force", {}, type(part.metadata) == "table" and part.metadata or {},
		type(state.metadata) == "table" and state.metadata or {})
	return state, metadata
end

local function code_text(part, state)
	local input = state.input or part.input
	if type(input) == "string" then
		local ok, decoded = pcall(vim.json.decode, input)
		input = ok and decoded or nil
	end
	if type(input) == "table" and type(input.code) == "string" then
		return input.code
	end
	return nil
end

local function status_label(state, metadata)
	if state.status == "cancelled" or state.status == "canceled"
		or (metadata.error == true and state.output == "Execution cancelled.") then
		return "Cancelled"
	end
	if state.status == "error" or metadata.error == true then
		return "Error"
	end
	if state.status == "streaming" or state.status == "pending" then
		return "Preparing"
	end
	if state.status == "running" then
		return "Running"
	end
	return nil
end

local function append_attachments(lines, state)
	local function append(text)
		vim.list_extend(lines, vim.split(text, "\n", { plain = true }))
	end
	local attachments = {}
	for _, file in ipairs(type(state.files) == "table" and state.files or {}) do
		attachments[#attachments + 1] = file
	end
	if #attachments == 0 then
		for _, content in ipairs(type(state.content) == "table" and state.content or {}) do
			if type(content) == "table" and content.type ~= "text" then
				attachments[#attachments + 1] = content
			end
		end
	end
	if #attachments == 0 then
		return
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Attachments"
	for index, file in ipairs(attachments) do
		if type(file) == "table" then
			local resource = type(file.resource) == "table" and file.resource or {}
			local name = file.filename or file.name or file.title or ("Attachment " .. index)
			local mime = file.mime or file.mimeType or resource.mimeType or file.type or "file"
			append(tostring(name) .. " (" .. tostring(mime) .. ")")
			local uri = file.uri or file.url or resource.uri
			if type(uri) == "string" then
				append(vim.trim(uri):lower():match("^data:") and "  [inline data omitted]" or ("  " .. uri))
			elseif file.data or file.blob or resource.blob then
				lines[#lines + 1] = "  [inline data omitted]"
			end
		end
	end
end

function M.is_open()
	return active ~= nil and active.winid ~= nil and vim.api.nvim_win_is_valid(active.winid)
end

function M.get_winids()
	if not M.is_open() then
		return {}
	end
	return { active.winid }
end

---Close the inspector. Cleanup callers may opt out of restoring focus.
function M.close(restore_focus)
	if active then
		active.close(restore_focus)
	end
end

---@param tool_part table
---@param opts? {view?: "result"|"raw"|"code"|"calls"}
---@return table|nil popup
function M.open(tool_part, opts)
	if type(tool_part) ~= "table" then
		return nil
	end
	M.close()
	if vim.o.columns < 12 or vim.o.lines - vim.o.cmdheight < 6 then
		vim.notify("Not enough room to show execute details", vim.log.levels.WARN)
		return nil
	end
	opts = opts or {}
	local state, metadata = tool_data(tool_part)
	local pending = state.status == "pending" or state.status == "running" or state.status == "streaming"
	local error_value = state.error ~= vim.NIL and state.error or nil
	local result_value = state.output
	if result_value == vim.NIL then
		result_value = nil
	end
	if result_value == nil or (result_value == "" and error_value ~= nil) then
		result_value = error_value
	end
	local result = output.describe(result_value)
	result.lines = vim.list_extend({}, result.document_lines or result.lines)
	if result.raw == "" then
		result.lines = { pending and "No output yet." or "No output." }
	end
	if error_value ~= nil and error_value ~= "" then
		local err = output.describe(error_value)
		if err.raw ~= result.raw then
			local lines = vim.list_extend({ "Error" }, err.document_lines or err.lines)
			result.document_headings = nil
			vim.list_extend(lines, { "", "Output" })
			result.lines = vim.list_extend(lines, result.lines)
		end
	end
	append_attachments(result.lines, state)
	local code = code_text(tool_part, state)
	local status = status_label(state, metadata)
	local previous_win = vim.api.nvim_get_current_win()
	local chat_state = require("opencode.ui.chat.state").state
	local winid = chat_state.visible and chat_state.winid or previous_win
	if not winid or not vim.api.nvim_win_is_valid(winid) then return nil end
	local previous_buf = vim.api.nvim_win_get_buf(winid)
	local saved_view = vim.api.nvim_win_call(winid, vim.fn.winsaveview)
	local saved_options, saved_bufhidden = {}, vim.bo[previous_buf].bufhidden
	local options = {
		wrap = true, linebreak = true, breakindent = true, conceallevel = 0,
		number = false, relativenumber = false, signcolumn = "no", foldenable = false,
		cursorline = false, cursorcolumn = false, colorcolumn = "", list = false,
		winhighlight = "Normal:OpenCodeExecuteDetailsNormal,NormalFloat:OpenCodeExecuteDetailsNormal,WinBar:OpenCodeExecuteDetailsNormal,WinBarNC:OpenCodeExecuteDetailsNormal",
		fillchars = "eob: ", scrolloff = 2, winbar = "",
	}
	for name in pairs(options) do saved_options[name] = vim.wo[winid][name] end
	local popup = { winid = winid, bufnr = vim.api.nvim_create_buf(false, true) }
	local closed, group
	local cursors = {}
	local cache = { result = result }
	for name, value in pairs({ filetype = "opencode_execute_details", buftype = "nofile",
		bufhidden = "wipe", swapfile = false, undolevels = -1 }) do vim.bo[popup.bufnr][name] = value end
	-- Reuse the content window itself. Additional borderless floats still cast
	-- shadows in GUI clients, so they cannot represent a page of the same chat.
	vim.bo[previous_buf].bufhidden = "hide"
	vim.api.nvim_win_set_buf(winid, popup.bufnr)
	for name, value in pairs(options) do vim.wo[winid][name] = value end
	vim.api.nvim_set_current_win(winid)
	active = popup

	function popup.close(restore_focus)
		if closed then return end
		closed = true
		if active == popup then active = nil end
		if group then pcall(vim.api.nvim_del_augroup_by_id, group) end
		if vim.api.nvim_win_is_valid(winid) then
			local showing_details = vim.api.nvim_win_get_buf(winid) == popup.bufnr
			if showing_details and vim.api.nvim_buf_is_valid(previous_buf) then
				vim.api.nvim_win_set_buf(winid, previous_buf)
			end
			for name, value in pairs(saved_options) do vim.wo[winid][name] = value end
			if showing_details then vim.api.nvim_win_call(winid, function() vim.fn.winrestview(saved_view) end) end
		end
		if vim.api.nvim_buf_is_valid(previous_buf) then vim.bo[previous_buf].bufhidden = saved_bufhidden end
		if vim.api.nvim_buf_is_valid(popup.bufnr) then pcall(vim.api.nvim_buf_delete, popup.bufnr, { force = true }) end
		if chat_state.winid == winid and chat_state.bufnr == previous_buf then
			local ok, tabs = pcall(require, "opencode.ui.chat.session_tabs")
			if ok then tabs.update_winbar() end
		end
		if type(restore_focus) == "table" then restore_focus = restore_focus.restore_focus end
		if restore_focus ~= false and vim.api.nvim_win_is_valid(previous_win) then
			vim.api.nvim_set_current_win(previous_win)
		end
	end
	function popup:unmount() self.close() end

	local function view_content(view)
		if cache[view] then return cache[view] end
		local content
		if view == "raw" then
			content = { lines = vim.split(result.raw, "\n", { plain = true }), filetype = "text" }
		elseif view == "code" then
			content = { lines = vim.split(code or (pending and "Code is still being received." or "No code available."),
				"\n", { plain = true }), filetype = code and "javascript" or "text" }
		else
			content = { lines = {}, document_headings = {}, filetype = "text" }
			for _, call in ipairs(type(metadata.toolCalls) == "table" and metadata.toolCalls or {}) do
				if type(call) == "table" then
					if #content.lines > 0 then vim.list_extend(content.lines, { "", "" }) end
					local icon = call.status == "completed" and "✓" or call.status == "error" and "✗" or "○"
					content.document_headings[#content.document_headings + 1] = #content.lines + 1
					content.lines[#content.lines + 1] = icon .. " " .. tostring(call.tool or "MCP call")
					content.lines[#content.lines + 1] = tostring(call.status or "pending")
					if call.input ~= nil and call.input ~= vim.NIL then
						vim.list_extend(content.lines, { "", "Input", "" })
						local input = output.describe(call.input, { max_lines = math.huge, max_chars = math.huge })
						vim.list_extend(content.lines, input.document_lines or input.lines)
					end
				end
			end
			if #content.lines == 0 then
				content.lines = { pending and "No MCP calls recorded yet." or "No MCP calls recorded." }
			end
		end
		cache[view] = content
		return content
	end

	local function toolbar()
		local width = vim.api.nvim_win_get_width(winid)
		local compact = width < 40
		local parts = {}
		local function append(label, action, highlight)
			parts[#parts + 1] = "%#" .. highlight .. "#"
			if action then
				parts[#parts + 1] = "%" .. (popup.bufnr * 10 + action) .. "@v:lua.require'opencode.ui.chat.execute_details'.click_tab@"
			end
			parts[#parts + 1] = label:gsub("%%", "%%%%")
			if action then parts[#parts + 1] = "%X" end
		end
		append(compact and "←" or "← Back", 0, "OpenCodeExecuteDetailsNormal")
		append(width >= 57 and "   execute /   " or "  ", nil, "OpenCodeExecuteDetailsMuted")
		for index, view in ipairs(views) do
			local label = width < 24 and ({ "R", "Raw", "C", "MCP" })[index] or labels[view]
			append(label, index, view == popup.view and "OpenCodeExecuteDetailsActive" or "OpenCodeExecuteDetailsNormal")
			if index < #views then append(compact and " " or "  ", nil, "OpenCodeExecuteDetailsNormal") end
		end
		parts[#parts + 1] = "%#OpenCodeExecuteDetailsNormal#%="
		if status then append(status .. " ", nil, "OpenCodeExecuteDetailsMuted") end
		vim.wo[winid].winbar = table.concat(parts)
		vim.cmd("redrawstatus")
	end

	function popup.set_view(view)
		if closed or not labels[view] then return end
		if popup.view then cursors[popup.view] = vim.api.nvim_win_get_cursor(popup.winid) end
		popup.view = view
		local content = view_content(view)
		local lines, headings = {}, {}
		local source_headings = {}
		for _, row in ipairs(content.document_headings or {}) do source_headings[row] = true end
		for row, line in ipairs(content.lines) do
			-- Raw and Code retain CRLF and trailing newlines; NUL is made visible.
			line = line:gsub("%z", "<NUL>")
			if source_headings[row] then headings[#headings + 1] = #lines + 1 end
			if view == "result" then
				local width = math.max(1, math.min(100, vim.api.nvim_win_get_width(winid)))
				local wrapped = require("opencode.ui.chat.render").wrap_text_with_ranges(line, width)
				for _, part in ipairs(wrapped) do lines[#lines + 1] = part.text end
			else
				lines[#lines + 1] = line
			end
		end
		if #lines == 0 then lines[1] = "" end
		vim.bo[popup.bufnr].modifiable = true
		vim.bo[popup.bufnr].readonly = false
		vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
		vim.bo[popup.bufnr].modified = false
		vim.bo[popup.bufnr].modifiable = false
		vim.bo[popup.bufnr].readonly = true
		vim.api.nvim_buf_clear_namespace(popup.bufnr, ns, 0, -1)
		-- Separate the fixed navigation from the document without adding bytes
		-- to Raw/Code or creating another floating surface.
		vim.api.nvim_buf_set_extmark(popup.bufnr, ns, 0, 0, {
			virt_lines = { { { "", "OpenCodeExecuteDetailsNormal" } } }, virt_lines_above = true,
		})
		if content.filetype and content.filetype ~= "text" then
			local ok, syntax = pcall(require, "opencode.ui.syntax")
			if ok then
				local highlighted = {}
				syntax.add_highlights(highlighted, table.concat(lines, "\n"), content.filetype, { scope = "tools", min_bytes = 0 })
				require("opencode.ui.chat.highlights").apply_extmark_highlights(popup.bufnr, ns, highlighted.highlights, 0)
			end
		end
		for _, row in ipairs(headings) do
			if lines[row] then
				vim.api.nvim_buf_set_extmark(popup.bufnr, ns, row - 1, 0, {
					end_col = #lines[row], hl_group = "OpenCodeExecuteDetailsAccent", priority = 200,
				})
			end
		end
		vim.api.nvim_win_set_cursor(popup.winid, cursors[view] or { 1, 0 })
		toolbar()
	end
	popup.set_view(labels[opts.view] and opts.view or "result")

	float.setup_close_keymaps(popup.bufnr, popup.close)
	local function map(key, fn)
		vim.keymap.set("n", key, fn, { buffer = popup.bufnr, noremap = true, silent = true })
	end
	map("<BS>", popup.close)
	for index, view in ipairs(views) do map(tostring(index), function() popup.set_view(view) end) end
	local function cycle(delta)
		for index, view in ipairs(views) do
			if view == popup.view then popup.set_view(views[(index - 1 + delta) % #views + 1]); return end
		end
	end
	map("<Tab>", function() cycle(1) end)
	map("<S-Tab>", function() cycle(-1) end)

	group = vim.api.nvim_create_augroup("OpenCodeExecuteDetails_" .. popup.bufnr, { clear = true })
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, { group = group, callback = function()
		if not closed and vim.api.nvim_win_is_valid(winid) then popup.set_view(popup.view) end
	end })
	vim.api.nvim_create_autocmd("BufLeave", { group = group, buffer = popup.bufnr, callback = function()
		vim.schedule(function()
			if closed then return end
			if vim.api.nvim_get_current_win() ~= winid or vim.api.nvim_win_get_buf(winid) ~= popup.bufnr then
				popup.close(false)
			end
		end)
	end })
	vim.api.nvim_create_autocmd("WinClosed", { group = group, pattern = tostring(winid), callback = function()
		vim.schedule(function() popup.close(false) end)
	end })
	return popup
end

-- The buffer id in minwid prevents a delayed click from targeting a new page.
-- Clearing the page's native winbar unregisters all of its click regions.
function M.click_tab(minwid, _, button)
	if button ~= "l" or not M.is_open() then return end
	if math.floor(minwid / 10) ~= active.bufnr then return end
	local index = minwid % 10
	if index == 0 then active.close() elseif views[index] then active.set_view(views[index]) end
end

return M
