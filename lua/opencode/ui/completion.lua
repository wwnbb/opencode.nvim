-- Ghost completion decorations and editor keymaps. Request state lives in the
-- completion controller; this module never changes source buffer contents.
local M = {}

local actions = require("opencode.actions")
local keymaps = require("opencode.util.keymap")
local spinner = require("opencode.ui.spinner")
local namespace = vim.api.nvim_create_namespace("OpenCodeCompletion")
local config = {}
local group, next_buffer_id
local previews = {}
local trigger_maps = {}

require("opencode.ui.highlights").register("opencode.ui.completion", function()
	vim.api.nvim_set_hl(0, "OpenCodeCompletion", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeCompletionSpinner", { link = "DiagnosticInfo", default = true })
end)

local function keycode(key)
	return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local function install_mapping(bufnr, key, callback, description)
	return keymaps.install("i", bufnr, key, callback, { silent = true, desc = description })
end

local function restore_mappings(mappings)
	for _, mapping in ipairs(mappings or {}) do keymaps.restore(mapping) end
end

local function current_mapping(mapping)
	for _, current in ipairs(vim.api.nvim_buf_get_keymap(mapping.bufnr, mapping.mode)) do
		if keymaps.code(current.lhs) == mapping.key then return current end
	end
end

local function replay(key, after)
	-- The temporary map has already been restored. Let Neovim execute the
	-- original mapping, including expression callbacks, exactly as usual.
	vim.api.nvim_feedkeys(keycode(key .. (after or "")), "mi", false)
end

local function eligible(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return false end
	local options = vim.bo[bufnr]
	return options.buftype == "" and options.modifiable and not options.readonly
		and not options.filetype:match("^opencode")
		and not vim.api.nvim_buf_get_name(bufnr):match("^opencode://")
end

local function stop_timer(view)
	if not view.timer then return end
	if not view.timer:is_closing() then
		view.timer:stop()
		view.timer:close()
	end
	view.timer = nil
end

local function clear_buffer(bufnr)
	local buffer = previews[bufnr]
	if not buffer then return end
	for snapshot in pairs(buffer.views) do M.clear(snapshot) end
end

function M.clear(snapshot)
	if not snapshot then
		for bufnr in pairs(previews) do clear_buffer(bufnr) end
		return
	end
	local buffer = previews[snapshot.bufnr]
	local view = buffer and buffer.views[snapshot]
	if not view then return end
	stop_timer(view)
	buffer.views[snapshot] = nil
	if view.mark and vim.api.nvim_buf_is_valid(snapshot.bufnr) then
		pcall(vim.api.nvim_buf_del_extmark, snapshot.bufnr, namespace, view.mark)
	end
	if not next(buffer.views) then
		previews[snapshot.bufnr] = nil
		restore_mappings(buffer.accept_mappings)
	end
end

local function install_accept_mappings(bufnr, buffer)
	if buffer.accept_mappings or buffer.replaying then return end
	buffer.accept_mappings = {}
	for _, key in ipairs(keymaps.keys(keymaps.get("completion", config.keymaps).accept)) do
		buffer.accept_mappings[#buffer.accept_mappings + 1] = install_mapping(bufnr, key, function()
			local accepted = previews[bufnr] == buffer and actions.accept_completion()
			if not accepted then
				local cursor = vim.api.nvim_win_get_cursor(0)
				for snapshot in pairs(buffer.views) do
					if cursor[1] == snapshot.row + 1 and cursor[2] == snapshot.col then M.clear(snapshot) end
				end
				local after
				if previews[bufnr] == buffer then
					buffer.replaying = {}
					for _, mapping in ipairs(buffer.accept_mappings) do
						if vim.deep_equal(current_mapping(mapping), mapping.installed) then
							buffer.replaying[#buffer.replaying + 1] = mapping
							keymaps.restore(mapping)
						end
					end
					-- Restore acceptance only after the original mapping has executed.
					after = ("<Cmd>lua require('opencode.ui.completion')._resume_accept(%d, %d)<CR>"):format(bufnr, buffer.id)
				end
				replay(key, after)
			end
		end, "Accept OpenCode completion")
	end
end

function M._resume_accept(bufnr, id)
	local buffer = previews[bufnr]
	if not buffer or buffer.id ~= id then return end
	for _, mapping in ipairs(buffer.replaying or {}) do
		-- A fallback callback may install a new owner while our maps are suspended.
		if vim.deep_equal(current_mapping(mapping), mapping.previous) then
			vim.api.nvim_buf_call(bufnr, function() vim.fn.mapset(mapping.mode, false, mapping.installed) end)
		end
	end
	buffer.replaying = nil
end

local function get_view(snapshot)
	local buffer = previews[snapshot.bufnr]
	if not buffer then
		next_buffer_id = (next_buffer_id or 0) + 1
		buffer = { id = next_buffer_id, views = {} }
		previews[snapshot.bufnr] = buffer
	end
	local view = buffer.views[snapshot]
	if not view then
		view = { snapshot = snapshot }
		buffer.views[snapshot] = view
	end
	return view, buffer
end

local function decorate(view, first, remaining, highlight)
	local snapshot = view.snapshot
	if not vim.api.nvim_buf_is_valid(snapshot.bufnr) then return false end
	local options = {
		id = view.mark,
		virt_text = { { first, highlight } },
		virt_text_pos = "inline",
		hl_mode = "combine",
		-- Keep inline decorations to the right of the Insert-mode cursor.
		right_gravity = true,
		priority = 200,
	}
	if remaining and #remaining > 0 then
		options.virt_lines = {}
		for _, line in ipairs(remaining) do
			options.virt_lines[#options.virt_lines + 1] = { { line, highlight } }
		end
	end
	local ok, mark = pcall(vim.api.nvim_buf_set_extmark, snapshot.bufnr, namespace, snapshot.row, snapshot.col, options)
	if ok then view.mark = mark end
	return ok
end

local function decorate_pending(view)
	return decorate(view, spinner.get_frame(), nil, "OpenCodeCompletionSpinner")
end

function M.pending(snapshot)
	local view, buffer = get_view(snapshot)
	stop_timer(view)
	if not decorate_pending(view) then
		M.clear(snapshot)
		return false
	end
	install_accept_mappings(snapshot.bufnr, buffer)
	view.timer = vim.uv.new_timer()
	if view.timer then
		local interval = spinner.get_interval_ms()
		view.timer:start(interval, interval, vim.schedule_wrap(function()
			if buffer.views[snapshot] ~= view or not view.timer then return end
			if not decorate_pending(view) then M.clear(snapshot) end
		end))
	end
	return true
end

function M.show(snapshot, text)
	if type(text) ~= "string" or text == "" or not eligible(snapshot.bufnr) then M.clear(snapshot); return false end
	local lines = vim.split(text, "\n", { plain = true, trimempty = false })
	local source = vim.api.nvim_buf_get_lines(snapshot.bufnr, snapshot.row, snapshot.row + 1, false)[1]
	-- Inline virtual text cannot move the real suffix to the last virtual line.
	-- The controller requests a single-line completion whenever a suffix exists.
	if not source or (#lines > 1 and snapshot.col < #source) then M.clear(snapshot); return false end
	local first = table.remove(lines, 1)
	local view, buffer = get_view(snapshot)
	stop_timer(view)
	if not decorate(view, first, lines, "OpenCodeCompletion") then
		M.clear(snapshot)
		return false
	end
	install_accept_mappings(snapshot.bufnr, buffer)
	return true
end

local function configure_buffer(bufnr)
	local installed = trigger_maps[bufnr]
	if not eligible(bufnr) then
		clear_buffer(bufnr)
		restore_mappings(installed)
		trigger_maps[bufnr] = nil
		return
	end
	-- Do not reinstall over a later mapping from the user or another plugin.
	if installed then return end
	trigger_maps[bufnr] = {}
	for _, key in ipairs(keymaps.keys(keymaps.get("completion", config.keymaps).trigger)) do
		trigger_maps[bufnr][#trigger_maps[bufnr] + 1] = install_mapping(bufnr, key, function()
			if eligible(bufnr) then
				actions.complete()
			else
				restore_mappings(trigger_maps[bufnr])
				trigger_maps[bufnr] = nil
				replay(key)
			end
		end, "Request OpenCode completion")
	end
end

function M.teardown()
	M.clear()
	if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
	for _, mappings in pairs(trigger_maps) do restore_mappings(mappings) end
	trigger_maps = {}
	config = {}
end

function M.setup(opts)
	M.teardown()
	config = opts or {}
	if not config.enabled then return end
	group = vim.api.nvim_create_augroup("OpenCodeCompletionKeymaps", { clear = true })
	vim.api.nvim_create_autocmd({ "BufEnter", "FileType" }, {
		group = group,
		callback = function(event) configure_buffer(event.buf) end,
	})
	vim.api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = { "buftype", "modifiable", "readonly" },
		callback = function() configure_buffer(vim.api.nvim_get_current_buf()) end,
	})
	vim.api.nvim_create_autocmd("BufWipeout", {
		group = group,
		callback = function(event)
			clear_buffer(event.buf)
			trigger_maps[event.buf] = nil
		end,
	})
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do configure_buffer(bufnr) end
end

return M
