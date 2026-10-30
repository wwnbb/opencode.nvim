-- A temporary, read-only view for an editor selection explanation. Asking a
-- follow-up docks a question composer along its bottom edge.
-- Request ownership and cancellation live in opencode.explanation.
local M = {}

local actions = require("opencode.actions")
local keymaps = require("opencode.util.keymap")
local Popup = require("opencode.ui.popup")
local spinner = require("opencode.ui.spinner")

local active, group
local config = {}
local trigger_maps = {}
-- Answer rows that stay visible above a growing question composer.
local MIN_ANSWER_ROWS = 3

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
	if view.prefix then return compose(view, spinner.get_loading_text("Answering question")) end
	local close = keymaps.hint({ { keymaps.label("explanation", "close", config.keymaps), "close" } }, { omit_disabled = true })
	return spinner.get_loading_text("Explaining selection") .. (close and ("\n\n" .. close) or "")
end

-- Key hints for the frame's bottom border: the popup keys, or the composer's
-- send/back keys while asking.
local function footer(view)
	local items = view.composer and { { "input", "send", "ask" }, { "popup", "cancel", "back" } }
		or { { "explanation", "ask", "ask" }, { "explanation", "copy", "copy" }, { "explanation", "close", "close" } }
	local hints = {}
	for _, item in ipairs(items) do
		if item[2] ~= "ask" or view.on_ask then
			hints[#hints + 1] = { keymaps.label(item[1], item[2], item[1] == "explanation" and config.keymaps or nil), item[3] }
		end
	end
	local text = keymaps.hint(hints, { omit_disabled = true })
	return text and (" " .. text .. " ")
end

-- Answer rows fill the frame, except the bottom `reserved` rows held by an
-- open question composer.
local function layout(reserved)
	local width = math.min(88, math.max(1, vim.o.columns - 10))
	local height = math.min(24, math.max(3, vim.o.lines - vim.o.cmdheight - 6))
	return {
		frame = { size = { width = width, height = height } },
		content = { position = { row = 0, col = 0 }, size = { width = width, height = math.max(1, height - (reserved or 0)) } },
	}
end

local function draw_frame(view)
	local lines = {}
	for index = 1, layout().frame.size.height do lines[index] = "" end
	view.popup:render(lines, nil, "frame")
	local border = view.popup.frame.border
	if border and border.winid and vim.api.nvim_win_is_valid(border.winid) then
		border:set_text("bottom", footer(view) or "", "center")
	end
end

local function reserve(view, rows)
	if view.reserved == rows then return end
	view.reserved = rows
	view.popup:resize(layout(rows))
end

-- The composer spans the frame's width along its bottom edge and grows upward
-- with the question; the answer keeps the rows above it.
local function dock(view)
	return function(measure)
		local frame = view.popup.frame.winid
		local width, height = vim.api.nvim_win_get_width(frame), vim.api.nvim_win_get_height(frame)
		local rows = measure(math.max(1, width - 2), height - 4 - MIN_ANSWER_ROWS)
		reserve(view, rows + 4)
		return {
			relative = { type = "win", winid = frame }, zindex = 52,
			row = math.max(0, height - rows - 4), col = 0, width = math.max(1, width - 2), height = rows,
		}
	end
end

local function explanation_model()
	local global = require("opencode.state").get_config() or {}
	return (global.explanation or config).model
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

local function composer_closed(view)
	view.composer = nil
	if active ~= view then return false end
	reserve(view, 0)
	draw_frame(view)
	return true
end

-- A question typed during an answer stays in the composer until it can be
-- sent; going back keeps it for the next ask.
local function ask()
	local view = active
	if not view or not view.on_ask or view.composer then return end
	view.composer = require("opencode.ui.completion_prompt").open({
		winid = view.winid, title = "Ask", model = explanation_model(), text = view.draft,
		placement = dock(view),
		can_submit = function(value)
			if vim.trim(value) == "" then return false end
			if view.phase == "pending" or view.phase == "streaming" then
				vim.notify("OpenCode explanation: wait for the current answer", vim.log.levels.INFO)
				return false
			end
			return true
		end,
		on_submit = function(value)
			view.draft = nil
			if composer_closed(view) then view.on_ask(vim.trim(value)) end
		end,
		on_cancel = function(value)
			view.draft = value
			-- Leaving the composer for another window leaves the explanation too.
			if composer_closed(view) and vim.api.nvim_get_current_win() ~= view.winid then M.close() end
		end,
	})
	draw_frame(view)
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
	local layers = layout()
	local popup = Popup.new({
		frame = vim.tbl_extend("force", layers.frame, {
			enter = false, focusable = false, zindex = 50,
			border = { text = { top = " Explanation ", top_align = "center", bottom = footer(view), bottom_align = "center" } },
			buf_options = { filetype = "opencode_float", modifiable = false },
		}),
		content = vim.tbl_extend("force", layers.content, {
			enter = true, focusable = true, border = "none", zindex = 51,
			buf_options = { filetype = "opencode_explanation" },
		}),
		focus_restore = "previous",
		close_on_leave = true,
		on_resize = function(current)
			local saved_view = vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
			current:resize(layout(view.reserved))
			draw_frame(view)
			if view.text and view.phase ~= "pending" then render(view, view.text, saved_view) end
		end,
		on_close = function()
			stop_spinner(view)
			if active == view then active = nil end
			if view.composer then view.composer.close() end
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
	if on_ask then map("n", "ask", ask, { desc = "Ask about the explanation" }) end
	map("n", "close", M.close)
	apply()
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
