-- Temporary view for /btw side questions. The question and answer are
-- deliberately kept out of the session transcript; this module owns only the
-- view. As in the explanation popup, asking docks a question composer along
-- the bottom edge, and follow-ups append below the conversation so far.
-- Request ownership lives in opencode.btw.

local M = {}

local highlights = require("opencode.ui.highlights")
local keymaps = require("opencode.util.keymap")
local Popup = require("opencode.ui.popup")
local spinner = require("opencode.ui.spinner")

local active
local tokens = 0
-- Answer rows that stay visible above a growing question composer.
local MIN_ANSWER_ROWS = 3
local PLACEHOLDER = "Ask anything about the conversation so far"

local function setup_highlights()
	vim.api.nvim_set_hl(0, "OpenCodeBtwBackground", { link = "NormalFloat", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeBtwRaised", { link = "Pmenu", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeBtwTitle", { link = "Title", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeBtwMuted", { link = "Comment", default = true })
end

highlights.register("opencode.ui.btw", setup_highlights)

local function valid(view)
	return view and active == view and vim.api.nvim_buf_is_valid(view.bufnr)
		and vim.api.nvim_win_is_valid(view.winid)
end

local function stop_spinner(view)
	if not view or not view.timer then return end
	view.timer:stop()
	view.timer:close()
	view.timer = nil
end

local function quote(question)
	return "> " .. question:gsub("\n", "\n> ")
end

-- The conversation so far, with each question quoted.
local function transcript(view)
	local blocks = {}
	for _, turn in ipairs(view.turns) do
		blocks[#blocks + 1] = quote(turn.question)
		if turn.answer then blocks[#blocks + 1] = turn.answer end
	end
	if view.failure then
		if view.failure.question then blocks[#blocks + 1] = quote(view.failure.question) end
		blocks[#blocks + 1] = "/btw error: " .. view.failure.message
	end
	if view.phase == "pending" then blocks[#blocks + 1] = spinner.get_loading_text("Answering") end
	return table.concat(blocks, "\n\n")
end

local function render(view, saved_view)
	if not valid(view) then return false end
	saved_view = saved_view or vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
	-- A pending answer keeps the cursor at the end while it stays on the last line.
	local follow = view.follow and saved_view.lnum >= vim.api.nvim_buf_line_count(view.bufnr)
	local text = transcript(view)
	local lines, marks
	if text == "" then
		lines = { PLACEHOLDER }
		marks = { { row = 0, col = 0, opts = { end_col = #PLACEHOLDER, hl_group = "OpenCodeBtwMuted" } } }
	else
		local renderer = require("opencode.ui.chat.render")
		local rendered = renderer.render_content(text, {
			width = vim.api.nvim_win_get_width(view.winid), scope = "assistant_markdown",
		})
		lines, marks = renderer.extract_lines(rendered), rendered._opencode_highlights
		if #lines == 0 then lines = { "" } end
	end
	view.popup:render(lines, marks)
	vim.bo[view.bufnr].modified = false
	vim.api.nvim_win_call(view.winid, function()
		vim.fn.winrestview(saved_view)
		if follow then vim.api.nvim_win_set_cursor(0, { vim.api.nvim_buf_line_count(0), 0 }) end
	end)
	return true
end

local function start_spinner(view)
	stop_spinner(view)
	view.timer = vim.uv.new_timer()
	if not view.timer then return end
	local interval = spinner.get_interval_ms()
	view.timer:start(interval, interval, vim.schedule_wrap(function()
		if active == view and view.phase == "pending" then render(view) end
	end))
end

-- Key hints for the frame's bottom border: the view keys, or the composer's
-- send/back keys while asking.
local function footer(view)
	local items = view.composer and { { "input", "send", "ask" }, { "popup", "cancel", "back" } }
		or { { "btw_answer", "ask", "ask" }, { "btw_answer", "copy", "copy" }, { "btw_answer", "close", "close" } }
	local hints = {}
	for _, item in ipairs(items) do
		if item[2] ~= "ask" or view.on_ask then hints[#hints + 1] = { keymaps.label(item[1], item[2]), item[3] } end
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
			relative = { type = "win", winid = frame }, zindex = 92,
			row = math.max(0, height - rows - 4), col = 0, width = math.max(1, width - 2), height = rows,
		}
	end
end

local function session_model(view)
	local ok, selection = pcall(function()
		return require("opencode.selectors").send_selection({ session_id = view.session_id })
	end)
	return ok and selection and selection.model or nil
end

local function latest_answer(view)
	for index = #view.turns, 1, -1 do
		if view.turns[index].answer then return view.turns[index].answer end
	end
end

local function copy_answer()
	local view = active
	local answer = view and latest_answer(view)
	if not answer then return end
	vim.fn.setreg('"', answer)
	for _, register in ipairs({ "+", "*" }) do
		pcall(vim.fn.setreg, register, answer)
	end
	vim.notify("/btw answer copied", vim.log.levels.INFO)
end

local function composer_closed(view)
	view.composer = nil
	if active ~= view then return false end
	reserve(view, 0)
	draw_frame(view)
	return true
end

local function submit(view, question)
	local earlier = {}
	for index, turn in ipairs(view.turns) do
		earlier[index] = { question = turn.question, answer = turn.answer }
	end
	view.failure = nil
	view.turns[#view.turns + 1] = { question = question }
	view.phase, view.follow = "pending", true
	render(view)
	vim.api.nvim_win_set_cursor(view.winid, { vim.api.nvim_buf_line_count(view.bufnr), 0 })
	start_spinner(view)
	if view.on_ask(question, { view = view.token, turns = earlier }) == false then
		M.error(view.token, "The question was not sent")
	end
end

-- A question typed during an answer stays in the composer until it can be
-- sent; going back keeps it for the next ask. Insert-mode Escape switches the
-- composer to Normal mode, as in the chat input.
local function ask()
	local view = active
	if not view or not view.on_ask or view.composer then return end
	view.composer = require("opencode.ui.completion_prompt").open({
		winid = view.winid, title = "/btw", model = session_model(view), text = view.draft,
		placement = dock(view), normal_mode = true,
		can_submit = function(value)
			if vim.trim(value) == "" then return false end
			if view.phase == "pending" then
				vim.notify("/btw: wait for the current answer", vim.log.levels.INFO)
				return false
			end
			return true
		end,
		on_submit = function(value)
			view.draft = nil
			if composer_closed(view) then submit(view, vim.trim(value)) end
		end,
		on_cancel = function(value)
			view.draft = value
			if not composer_closed(view) then return end
			-- Nothing to read without a question, and leaving the composer for
			-- another window leaves the view too.
			if (#view.turns == 0 and not view.failure) or vim.api.nvim_get_current_win() ~= view.winid then
				M.close()
			end
		end,
	})
	draw_frame(view)
end

local function open(opts)
	M.close()
	local previous_win = vim.api.nvim_get_current_win()
	-- Close an active composer while its parent chat is still focused. Its
	-- own BufLeave teardown would otherwise race the floating chat's focus
	-- handler when the view is dismissed.
	local ok, chat_input = pcall(require, "opencode.ui.input")
	if ok and chat_input.is_visible() and chat_input.get_winids()[1] == previous_win then
		chat_input.close()
	end
	tokens = tokens + 1
	local view = {
		token = tokens, turns = opts.turns or {}, phase = "ready", on_ask = opts.on_ask,
		session_id = opts.session_id, previous_win = previous_win,
	}
	local layers = layout()
	local popup = Popup.new({
		frame = vim.tbl_extend("force", layers.frame, {
			enter = false, focusable = false, zindex = 90,
			border = { text = { top = " /btw ", top_align = "center", bottom = footer(view), bottom_align = "center" } },
			buf_options = { filetype = "opencode_float", modifiable = false },
		}),
		content = vim.tbl_extend("force", layers.content, {
			enter = true, focusable = true, border = "none", zindex = 91,
			buf_options = { filetype = "opencode_btw" },
		}),
		focus_restore = "chat",
		close_on_leave = true,
		on_resize = function(current)
			local saved_view = vim.api.nvim_win_call(view.winid, vim.fn.winsaveview)
			current:resize(layout(view.reserved))
			draw_frame(view)
			render(view, saved_view)
		end,
		on_close = function()
			stop_spinner(view)
			if active == view then active = nil end
			if view.composer then view.composer.close() end
		end,
	})
	view.popup = popup
	popup:mount()
	view.bufnr, view.winid = popup.bufnr, popup.winid
	active = view
	vim.bo[view.bufnr].modifiable = false
	vim.bo[view.bufnr].readonly = true
	vim.wo[view.winid].wrap = true
	vim.wo[view.winid].linebreak = true
	vim.wo[view.winid].number = false
	vim.wo[view.winid].relativenumber = false
	vim.wo[view.winid].signcolumn = "no"
	vim.wo[view.winid].scrolloff = 2
	local map, apply = keymaps.mapper("btw_answer", view.bufnr)
	map("n", "copy", copy_answer, { desc = "Copy /btw answer" })
	if view.on_ask then map("n", "ask", ask, { desc = "Ask a /btw question" }) end
	map("n", "close", M.close, { nowait = true })
	apply()
	draw_frame(view)
	render(view)
	return view
end

function M.is_visible()
	return active ~= nil and active.winid ~= nil and vim.api.nvim_win_is_valid(active.winid)
end

function M.close()
	local view = active
	if not view then return false end
	active = nil
	view.popup:close()
	return true
end

---Close the view when it belongs to a cleared or deleted session.
function M.close_session(session_id)
	if active and active.session_id == session_id then M.close() end
end

---Open an empty view with the question composer focused.
---@param on_submit fun(question: string, opts: table): boolean|nil Sends the
---question; `opts` carries the view token and earlier turns for opencode.btw.
---Return false when it was not sent.
---@param opts? { session_id?: string }
function M.prompt(on_submit, opts)
	opts = opts or {}
	local view = open({
		session_id = opts.session_id,
		on_ask = function(question, ask_opts)
			if type(on_submit) == "function" then return on_submit(question, ask_opts) end
		end,
	})
	ask()
	return view
end

---Show an answer. It fills the view that asked the question when that view
---is still open, and otherwise opens a new one with the earlier turns.
---@param opts? { view?: integer, turns?: table[], session_id?: string, on_ask?: function }
function M.show(question, answer, opts)
	opts = opts or {}
	question, answer = tostring(question or ""), tostring(answer or "")
	local view = active
	if not (view and opts.view and view.token == opts.view and M.is_visible()) then
		local turns = {}
		for index, turn in ipairs(opts.turns or {}) do
			turns[index] = { question = turn.question, answer = turn.answer }
		end
		turns[#turns + 1] = { question = question }
		view = open({ turns = turns, session_id = opts.session_id, on_ask = opts.on_ask })
	end
	stop_spinner(view)
	local last = view.turns[#view.turns]
	if not last or last.answer or last.question ~= question then
		last = { question = question }
		view.turns[#view.turns + 1] = last
	end
	last.answer = answer
	view.phase = "ready"
	if opts.on_ask then view.on_ask = opts.on_ask end
	if not view.composer then draw_frame(view) end
	render(view)
	return view
end

---Show a failed question in the view that asked it.
---@return boolean shown
function M.error(token, message)
	local view = active
	if not view or token == nil or view.token ~= token or not M.is_visible() then return false end
	stop_spinner(view)
	local last = view.turns[#view.turns]
	local question
	if last and not last.answer then
		question = last.question
		table.remove(view.turns)
	end
	view.failure = { question = question, message = tostring(message) }
	view.phase = "ready"
	render(view)
	return true
end

return M
