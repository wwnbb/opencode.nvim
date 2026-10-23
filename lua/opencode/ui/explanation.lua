-- A temporary, read-only view for an editor selection explanation, with a
-- question input along its bottom edge for follow-ups.
-- Request ownership and cancellation live in opencode.explanation.
local M = {}

local actions = require("opencode.actions")
local keymaps = require("opencode.util.keymap")
local Popup = require("opencode.ui.popup")
local spinner = require("opencode.ui.spinner")

local active, group
local config = {}
local trigger_maps = {}

local function restore_mappings(mappings)
	for _, mapping in ipairs(mappings or {}) do keymaps.restore(mapping) end
end

local function eligible(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return false end
	local options = vim.bo[bufnr]
	return options.buftype == "" and not options.filetype:match("^opencode")
		and not vim.api.nvim_buf_get_name(bufnr):match("^opencode://")
end

local function stop_spinner(view)
	if not view or not view.timer then return end
	view.timer:stop()
	view.timer:close()
	view.timer = nil
end

-- Earlier turns of a follow-up conversation stay above the current one.
local function compose(view, body)
	return view.prefix and (view.prefix .. "\n\n" .. body) or body
end

local function render(view, text, saved_view)
	if active ~= view or not vim.api.nvim_buf_is_valid(view.bufnr)
		or not vim.api.nvim_win_is_valid(view.winid) then return false end
	saved_view = saved_view or vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
	-- A follow-up answer keeps the cursor at the end while it stays on the last line.
	local follow = view.follow and saved_view.lnum >= vim.api.nvim_buf_line_count(view.bufnr)
	view.text = text
	local lines = vim.split(text, "\n", { plain = true, trimempty = false })
	local highlights
	if view.phase == "ready" or view.phase == "streaming" or view.prefix then
		local renderer = require("opencode.ui.chat.render")
		local rendered = renderer.render_content(text, {
			width = vim.api.nvim_win_get_width(view.winid), scope = "assistant_markdown",
		})
		lines, highlights = renderer.extract_lines(rendered), rendered._opencode_highlights
	end
	if #lines == 0 then lines = { "" } end
	view.popup:render(lines, highlights)
	vim.bo[view.bufnr].modified = false
	vim.api.nvim_win_call(view.winid, function()
		vim.fn.winrestview(saved_view)
		if follow then vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 }) end
	end)
	return true
end

local function pending_text(view)
	return compose(view, spinner.get_loading_text(view.prefix and "Answering question" or "Explaining selection"))
end

-- Answer rows fill the frame; with an input, a separator row and the input
-- take its last two rows.
local function layout(with_input)
	local width = math.min(88, math.max(1, vim.o.columns - 10))
	local height = math.min(24, math.max(with_input and 3 or 1, vim.o.lines - vim.o.cmdheight - 6))
	return {
		frame = { size = { width = width, height = height } },
		content = { position = { row = 0, col = 0 }, size = { width = width, height = with_input and height - 2 or height } },
		input = with_input and { position = { row = height - 1, col = 0 }, size = { width = width, height = 1 } } or nil,
	}
end

local function draw_frame(view)
	local size = layout(view.input_bufnr ~= nil).frame.size
	local lines = {}
	for index = 1, size.height do lines[index] = "" end
	if view.input_bufnr then lines[size.height - 1] = string.rep("─", size.width) end
	view.popup:render(lines, view.input_bufnr and {
		{ row = size.height - 2, col = 0, end_col = #lines[size.height - 1], hl_group = "FloatBorder" },
	} or nil, "frame")
end

local function input_text(view)
	return vim.trim(table.concat(vim.api.nvim_buf_get_lines(view.input_bufnr, 0, -1, false), "\n"))
end

local function update_placeholder(view)
	if active ~= view or not vim.api.nvim_buf_is_valid(view.input_bufnr) then return end
	local empty = table.concat(vim.api.nvim_buf_get_lines(view.input_bufnr, 0, -1, false), "") == ""
	view.popup:render(nil, empty and {
		{ row = 0, col = 0, opts = { virt_text = { { "Ask about the selection", "Comment" } }, virt_text_pos = "overlay" } },
	} or {}, "input")
end

local function start_spinner(view)
	stop_spinner(view)
	view.timer = vim.uv.new_timer()
	if not view.timer then return end
	local interval = spinner.get_interval_ms()
	view.timer:start(interval, interval, vim.schedule_wrap(function()
		if active == view and view.phase == "pending" then render(view, pending_text(view)) end
	end))
end

local function copy_answer()
	local view = active
	if not view or not view.answer then return end
	vim.fn.setreg('"', view.answer)
	for _, register in ipairs({ "+", "*" }) do
		pcall(vim.fn.setreg, register, view.answer)
	end
	vim.notify("Explanation copied", vim.log.levels.INFO)
end

local function focus_answer(view)
	vim.cmd("stopinsert")
	if vim.api.nvim_win_is_valid(view.winid) then vim.api.nvim_set_current_win(view.winid) end
end

local function focus_input()
	local view = active
	if not view or not view.input_winid or not vim.api.nvim_win_is_valid(view.input_winid) then return end
	vim.api.nvim_set_current_win(view.input_winid)
	vim.cmd("startinsert!")
end

-- A question typed during an answer stays in the input until it can be sent.
local function submit()
	local view = active
	if not view then return end
	local question = input_text(view)
	if question == "" then return end
	if view.phase == "pending" or view.phase == "streaming" then
		vim.notify("OpenCode explanation: wait for the current answer", vim.log.levels.INFO)
		return
	end
	view.popup:render({ "" }, nil, "input")
	update_placeholder(view)
	focus_answer(view)
	view.on_ask(question)
end

local function configure_buffer(bufnr)
	local installed = trigger_maps[bufnr]
	if not eligible(bufnr) then
		restore_mappings(installed)
		trigger_maps[bufnr] = nil
		return
	end
	if installed then return end
	trigger_maps[bufnr] = {}
	for _, key in ipairs(keymaps.keys(keymaps.get("explanation", config.keymaps).trigger)) do
		trigger_maps[bufnr][#trigger_maps[bufnr] + 1] = keymaps.install("x", bufnr, key,
			function() actions.explain_selection() end, { silent = true, desc = "Explain OpenCode visual selection" })
	end
end

function M.is_open()
	return active ~= nil and active.winid ~= nil and vim.api.nvim_win_is_valid(active.winid)
end

function M.close()
	if not active then return false end
	active.popup:close()
	return true
end

---Open immediately so the request has a visible pending state.
---@param snapshot table Captured source selection (kept for the request owner).
---@param on_close function Called once for both key and external window closes.
---@param on_ask? fun(question: string) Called with a submitted follow-up question.
---@return table|nil view
function M.open(snapshot, on_close, on_ask)
	M.close()
	local view = { snapshot = snapshot, phase = "pending", on_close = on_close, on_ask = on_ask }
	local layers = layout(on_ask ~= nil)
	local popup = Popup.new({
		frame = vim.tbl_extend("force", layers.frame, {
			enter = false, focusable = false, zindex = 50,
			border = { text = { top = " Explanation ", top_align = "center" } },
			buf_options = { filetype = "opencode_float", modifiable = false },
		}),
		content = vim.tbl_extend("force", layers.content, {
			enter = true, focusable = true, border = "none", zindex = 51,
			buf_options = { filetype = "opencode_explanation" },
		}),
		input = layers.input and vim.tbl_extend("force", layers.input, {
			kind = "popup", enter = false, focusable = true, border = "none", zindex = 52,
			buf_options = { filetype = "opencode_explanation_input", modifiable = true },
			win_options = { wrap = false, number = false, relativenumber = false, signcolumn = "no" },
		}),
		focus_restore = "previous",
		close_on_leave = true,
		on_resize = function(current)
			local saved_view = vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
			current:resize(layout(view.input_bufnr ~= nil))
			draw_frame(view)
			if view.text and view.phase ~= "pending" then render(view, view.text, saved_view) end
		end,
		on_close = function()
			stop_spinner(view)
			if active == view then active = nil end
			if view.on_close then
				local callback = view.on_close
				view.on_close = nil
				callback()
			end
		end,
	})
	view.popup = popup
	popup:mount()
	view.bufnr, view.winid = popup.bufnr, popup.winid
	view.input_bufnr, view.input_winid = popup.input_bufnr, popup.input_winid
	active = view
	local bufnr = view.bufnr
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true
	vim.wo[view.winid].wrap = true
	vim.wo[view.winid].linebreak = true
	vim.wo[view.winid].number = false
	vim.wo[view.winid].relativenumber = false
	vim.wo[view.winid].signcolumn = "no"
	vim.wo[view.winid].scrolloff = 2
	local map, apply = keymaps.mapper("explanation", bufnr, config.keymaps)
	map("n", "copy", copy_answer, { desc = "Copy explanation" })
	if on_ask then map("n", "ask", focus_input, { desc = "Ask about the explanation" }) end
	map("n", "close", M.close)
	apply()
	if view.input_bufnr then
		local input_map, input_apply = keymaps.mapper("popup", view.input_bufnr)
		input_map({ "i", "n" }, "submit", submit, { desc = "Ask about the explanation" })
		input_map({ "i", "n" }, "cancel", function() focus_answer(view) end, { desc = "Back to the explanation" })
		input_apply()
		popup:on({ "TextChanged", "TextChangedI" }, function() update_placeholder(view) end, "input")
		update_placeholder(view)
	end
	draw_frame(view)
	render(view, pending_text(view))
	start_spinner(view)
	return view
end

---Show a pending follow-up below the conversation so far.
---@param prefix string Rendered earlier turns, ending with the new question.
function M.pending(prefix)
	local view = active
	if not view or type(prefix) ~= "string" then return false end
	view.phase, view.prefix, view.follow = "pending", prefix, true
	view.answer = view.completed
	if not render(view, pending_text(view)) then return false end
	vim.api.nvim_win_set_cursor(view.winid, { vim.api.nvim_buf_line_count(view.bufnr), 0 })
	start_spinner(view)
	return true
end

function M.show(text, opts)
	local view = active
	if not view or type(text) ~= "string" then return false end
	if opts and opts.streaming and vim.trim(text) == "" then return true end
	stop_spinner(view)
	view.phase, view.answer = opts and opts.streaming and "streaming" or "ready", text
	if view.phase == "ready" then view.completed = text end
	return render(view, compose(view, text))
end

function M.error(message)
	local view = active
	if not view then return false end
	stop_spinner(view)
	-- After a failed follow-up, copy still yields the last complete answer.
	view.phase, view.answer = "error", view.prefix and view.completed or nil
	return render(view, compose(view, "Explanation error: " .. tostring(message)))
end

function M.teardown()
	M.close()
	if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
	for _, mappings in pairs(trigger_maps) do restore_mappings(mappings) end
	trigger_maps = {}
	config = {}
end

function M.setup(opts)
	M.teardown()
	config = opts or {}
	if not config.enabled then return end
	group = vim.api.nvim_create_augroup("OpenCodeExplanationKeymaps", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
		group = group, callback = function(event) configure_buffer(event.buf) end,
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group, pattern = "buftype",
		callback = function() configure_buffer(vim.api.nvim_get_current_buf()) end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group, callback = function(event) trigger_maps[event.buf] = nil end,
	})
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do configure_buffer(bufnr) end
end

return M
