-- A temporary, read-only view for an editor selection explanation.
-- Request ownership and cancellation live in opencode.explanation.
local M = {}

local actions = require("opencode.actions")
local float = require("opencode.ui.float")
local spinner = require("opencode.ui.spinner")

local active, group
local config = {}
local trigger_maps = {}

local function keycode(key)
	return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local function local_mapping(bufnr, key)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "x")) do
		if keycode(mapping.lhs) == keycode(key) then return mapping end
	end
end

local function restore_mapping(mapping)
	if not mapping or not vim.api.nvim_buf_is_valid(mapping.bufnr) then return end
	local current = local_mapping(mapping.bufnr, mapping.key)
	if not current or current.callback ~= mapping.callback then return end
	vim.keymap.del("x", mapping.key, { buffer = mapping.bufnr })
	if mapping.previous then
		vim.api.nvim_buf_call(mapping.bufnr, function()
			vim.fn.mapset("x", false, mapping.previous)
		end)
	end
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

local function render(view, text)
	if active ~= view or not vim.api.nvim_buf_is_valid(view.bufnr) then return false end
	local lines = vim.split(text, "\n", { plain = true, trimempty = false })
	if #lines == 0 then lines = { "" } end
	view.popup:render(lines)
	vim.bo[view.bufnr].modified = false
	if view.winid and vim.api.nvim_win_is_valid(view.winid) then
		vim.api.nvim_win_set_cursor(view.winid, { 1, 0 })
	end
	return true
end

local function pending_text()
	return spinner.get_loading_text("Explaining selection") .. "\n\nq / Esc close"
end

local function copy_answer()
	local view = active
	if not view or view.phase ~= "ready" then return end
	vim.fn.setreg('"', view.answer)
	for _, register in ipairs({ "+", "*" }) do
		pcall(vim.fn.setreg, register, view.answer)
	end
	vim.notify("Explanation copied", vim.log.levels.INFO)
end

local function configure_buffer(bufnr)
	local installed = trigger_maps[bufnr]
	if not eligible(bufnr) then
		restore_mapping(installed)
		trigger_maps[bufnr] = nil
		return
	end
	if installed then return end
	local key = config.keymaps and config.keymaps.trigger
	if type(key) ~= "string" or key == "" then return end
	local mapping = { bufnr = bufnr, key = key, previous = local_mapping(bufnr, key) }
	mapping.callback = function() actions.explain_selection() end
	vim.keymap.set("x", key, mapping.callback, {
		buffer = bufnr, silent = true, desc = "Explain OpenCode visual selection",
	})
	trigger_maps[bufnr] = mapping
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
---@return table|nil view
function M.open(snapshot, on_close)
	M.close()
	local view = { snapshot = snapshot, phase = "pending", on_close = on_close }
	local popup, bufnr = float.create_centered_popup({
		width = math.min(88, math.max(1, vim.o.columns - 10)),
		height = math.min(24, math.max(1, vim.o.lines - vim.o.cmdheight - 6)),
		title = "Explanation",
		close_on_leave = true,
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
	view.popup, view.bufnr = popup, bufnr
	popup:mount()
	view.winid = popup.winid
	active = view
	vim.bo[bufnr].filetype = "markdown"
	vim.bo[bufnr].modifiable = false
	vim.bo[bufnr].readonly = true
	vim.wo[view.winid].wrap = true
	vim.wo[view.winid].linebreak = true
	vim.wo[view.winid].number = false
	vim.wo[view.winid].relativenumber = false
	vim.wo[view.winid].signcolumn = "no"
	vim.wo[view.winid].scrolloff = 2
	vim.keymap.set("n", "c", copy_answer, { buffer = bufnr, silent = true, desc = "Copy explanation" })
	float.setup_close_keymaps(bufnr, M.close)
	render(view, pending_text())
	view.timer = vim.uv.new_timer()
	if view.timer then
		local interval = spinner.get_interval_ms()
		view.timer:start(interval, interval, vim.schedule_wrap(function()
			if active == view and view.phase == "pending" then render(view, pending_text()) end
		end))
	end
	return view
end

function M.show(text)
	local view = active
	if not view or type(text) ~= "string" then return false end
	stop_spinner(view)
	view.phase, view.answer = "ready", text
	return render(view, text)
end

function M.error(message)
	local view = active
	if not view then return false end
	stop_spinner(view)
	view.phase, view.answer = "error", nil
	return render(view, "Explanation error: " .. tostring(message))
end

function M.teardown()
	M.close()
	if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
	for _, mapping in pairs(trigger_maps) do restore_mapping(mapping) end
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
