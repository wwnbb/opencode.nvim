-- opencode.nvim - Input area facade

local M = {}

local attachments = require("opencode.ui.input.attachments")
local autocmds = require("opencode.ui.input.autocmds")
local history = require("opencode.ui.input.history")
local info_bar = require("opencode.ui.input.info_bar")
local keymaps = require("opencode.ui.input.keymaps")
local layout = require("opencode.ui.input.layout")
local mentions = require("opencode.ui.input.mentions")
local popups = require("opencode.ui.input.popups")

local state = {
	bufnr = nil,
	winid = nil,
	parent_winid = nil,
	popup = nil,
	info_popup = nil,
	info_bufnr = nil,
	visible = false,
	on_send = nil,
	on_cancel = nil,
	close_on_send = true,
	persist_pending = true,
	add_history = true,
	config = nil,
	layout = nil,
	parts = {},
	mentions = nil,
	normalizing_paste = false,
	resize_scheduled = false,
}

local function copy_parts(parts)
	return history.copy_parts(parts)
end

local function get_input_text()
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return ""
	end

	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	return table.concat(lines, "\n")
end

local function resize_input()
	layout.resize(state)
end

local function schedule_resize_input()
	layout.schedule_resize(state)
end

local function set_input_text(text)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local content = text or ""
	local lines = vim.split(content, "\n", { plain = true })
	if #lines == 0 then
		lines = { "" }
	end

	vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		vim.api.nvim_win_set_cursor(state.winid, { #lines, #lines[#lines] })
	end
	resize_input()
end

local function clear_input()
	state.parts = {}
	mentions.reset(state)
	set_input_text("")
end

local function focus_parent_before_unmount()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end
	if vim.api.nvim_get_current_win() ~= state.winid then
		return
	end
	if state.parent_winid and vim.api.nvim_win_is_valid(state.parent_winid) then
		pcall(vim.api.nvim_set_current_win, state.parent_winid)
	end
end

local function resolve_config()
	local config_defaults = require("opencode.config").defaults.input
	local app_state = require("opencode.state")
	local full_config = app_state.get_config() or {}

	return vim.tbl_deep_extend("force", vim.deepcopy(config_defaults), full_config.input or {})
end

local function send_message()
	local text = get_input_text()
	if attachments.has_image_file_hint(text) then
		attachments.normalize_pasted_image_paths(state, resize_input)
		text = get_input_text()
	end

	local parts = attachments.active_parts_for_text(state, text)
	for _, part in ipairs(mentions.active_parts(state)) do
		table.insert(parts, part)
	end
	if text == "" and #parts == 0 then
		return
	end

	if state.add_history then
		history.add(text)
	end
	if state.persist_pending then
		history.clear_pending()
	end

	clear_input()

	if state.on_send then
		state.on_send(text, parts)
	end
	if state.close_on_send then
		M.close(false)
	end
end

local function cancel_input()
	local text = get_input_text()
	if state.on_cancel then
		state.on_cancel(text)
	end
	M.close()
end

local function history_prev()
	local text = history.previous()
	if text == nil then
		return
	end
	state.parts = {}
	mentions.reset(state)
	set_input_text(text)
end

local function history_next()
	local text = history.next()
	if text == nil then
		return
	end
	state.parts = {}
	mentions.reset(state)
	set_input_text(text)
end

local function stash_input()
	local text = get_input_text()
	if text == "" and #state.parts == 0 then
		return
	end

	history.set_stash(text, state.parts)
	clear_input()
	vim.notify("Input stashed (restore with <C-r>)", vim.log.levels.INFO)
end

local function restore_input()
	local text, parts = history.take_stash()
	if text == nil then
		vim.notify("No stashed input", vim.log.levels.WARN)
		return
	end

	state.parts = parts
	mentions.reset(state)
	set_input_text(text)
end

local function insert_text_at_cursor(text)
	return attachments.insert_text_at_cursor(state, text, schedule_resize_input)
end

local function mount_input(chat_winid, float_dims, cfg)
	local frame = layout.build(chat_winid, float_dims, cfg)
	state.layout = frame.layout
	state.popup, state.info_popup = popups.mount(frame)
	state.bufnr = state.popup.bufnr
	state.winid = state.popup.winid
	state.info_bufnr = state.info_popup.bufnr
	state.visible = true
	state.mentions = {
		parts = {},
	}
	mentions.enable_native_complete(state)

	vim.api.nvim_buf_set_var(state.bufnr, "completion", false)
end

function M.show(opts)
	opts = opts or {}

	if state.visible then
		return
	end

	local cfg = resolve_config()
	state.config = cfg
	state.on_send = opts.on_send
	state.on_cancel = opts.on_cancel or function() end
	state.close_on_send = opts.close_on_send ~= false
	state.persist_pending = opts.persist_pending ~= false
	state.add_history = opts.add_history ~= false
	state.parts = opts.text ~= nil and copy_parts(opts.parts) or history.get_pending_parts()

	history.configure(cfg)
	history.load()
	info_bar.setup_highlights()
	mentions.setup_highlights()

	local chat_winid = opts.winid
	if not chat_winid or not vim.api.nvim_win_is_valid(chat_winid) then
		chat_winid = vim.api.nvim_get_current_win()
	end
	state.parent_winid = chat_winid

	mount_input(chat_winid, opts.float_dims, cfg)

	autocmds.setup(state, {
		schedule_resize = schedule_resize_input,
		input_changed = function()
			mentions.refresh(state)
		end,
		cursor_moved = function()
			mentions.refresh(state)
		end,
		complete_done = function()
			mentions.complete_done(state)
		end,
		insert_leave = function()
			mentions.close_completion(state)
		end,
		lock_scroll = function()
			layout.lock_scroll(state)
		end,
		close = function()
			M.close()
		end,
	})

	keymaps.setup(state.bufnr, cfg, {
		send = send_message,
		cancel = cancel_input,
		history_prev = history_prev,
		history_next = history_next,
		paste = function()
			M.paste_clipboard()
		end,
		stash = stash_input,
		restore = restore_input,
		cycle_variant = function()
			info_bar.cycle_variant(state)
		end,
		cycle_agent = function()
			info_bar.cycle_agent(state)
		end,
		cycle_model = function()
			info_bar.cycle_model(state)
		end,
	})

	info_bar.update(state)

	local text = opts.text
	if text == nil then
		text = history.get_pending()
	end
	if text and text ~= "" then
		set_input_text(text)
		mentions.refresh(state)
	end

	vim.cmd("startinsert!")
end

function M.close(save_draft)
	if not state.visible then
		return
	end

	if save_draft ~= false and state.persist_pending then
		history.set_pending(get_input_text(), state.parts)
	end

	mentions.clear(state)
	focus_parent_before_unmount()
	popups.unmount(state)

	state.visible = false
	state.winid = nil
	state.parent_winid = nil
	state.bufnr = nil
	state.popup = nil
	state.info_popup = nil
	state.info_bufnr = nil
	state.layout = nil
	state.parts = {}
	state.mentions = nil
	state.on_send = nil
	state.on_cancel = nil
	state.close_on_send = true
	state.persist_pending = true
	state.add_history = true
	state.normalizing_paste = false
	state.resize_scheduled = false

	vim.cmd("stopinsert")
end

function M.is_visible()
	return state.visible
end

---@return number[]
function M.get_winids()
	if not state.visible then
		return {}
	end

	local wins = {}
	if state.winid and vim.api.nvim_win_is_valid(state.winid) then
		table.insert(wins, state.winid)
	end

	if state.info_popup and state.info_popup.winid and vim.api.nvim_win_is_valid(state.info_popup.winid) then
		table.insert(wins, state.info_popup.winid)
	end

	return wins
end

function M.clear_history()
	history.clear()
	state.parts = {}
	mentions.reset(state)
end

function M.get_history()
	return history.entries()
end

---@return string
function M.get_pending_text()
	if state.visible then
		return get_input_text()
	end
	return history.get_pending()
end

---@param text string
function M.set_pending_text(text)
	local content = text or ""
	history.set_pending(content, content == "" and {} or nil)
	if content == "" then
		state.parts = {}
	end

	if state.visible then
		mentions.reset(state)
		set_input_text(content)
	end
end

---@return boolean success
function M.paste_clipboard()
	return attachments.paste_clipboard(state, {
		insert_text_at_cursor = insert_text_at_cursor,
		normalize_pasted_image_paths = function()
			attachments.normalize_pasted_image_paths(state, resize_input)
		end,
		add_file_part = function(content)
			return attachments.add_file_part(state, content, nil, insert_text_at_cursor)
		end,
	})
end

---@param text string
---@param opts? { separator?: string }
---@return string
function M.append_pending_text(text, opts)
	local extra = text or ""
	if extra == "" then
		return M.get_pending_text()
	end

	opts = opts or {}
	local separator = opts.separator or "\n"
	local current = M.get_pending_text()
	local next_text

	if current == "" then
		next_text = extra
	elseif separator == "" then
		next_text = current .. extra
	elseif current:sub(- #separator) == separator then
		next_text = current .. extra
	else
		next_text = current .. separator .. extra
	end

	M.set_pending_text(next_text)
	return next_text
end

function M.update_info_bar()
	info_bar.update(state)
end

function M.cycle_variant()
	info_bar.cycle_variant(state)
end

function M.cycle_agent()
	info_bar.cycle_agent(state)
end

function M.cycle_model()
	info_bar.cycle_model(state)
end

return M
