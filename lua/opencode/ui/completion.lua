-- Ghost completion decorations and editor keymaps. Request state lives in the
-- completion controller; this module never changes source buffer contents.
local M = {}

local actions = require("opencode.actions")
local spinner = require("opencode.ui.spinner")
local namespace = vim.api.nvim_create_namespace("OpenCodeCompletion")
local config = {}
local preview, timer, group
local trigger_maps = {}

require("opencode.ui.highlights").register("opencode.ui.completion", function()
	vim.api.nvim_set_hl(0, "OpenCodeCompletion", { link = "Comment", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeCompletionSpinner", { link = "DiagnosticInfo", default = true })
end)

local function keycode(key)
	return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local function local_mapping(bufnr, key)
	for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "i")) do
		if keycode(mapping.lhs) == keycode(key) then return mapping end
	end
end

local function restore_mapping(mapping)
	if not mapping or not vim.api.nvim_buf_is_valid(mapping.bufnr) then return end
	local current = local_mapping(mapping.bufnr, mapping.key)
	-- A subsequently installed user/plugin mapping belongs to its new owner.
	if not current or current.callback ~= mapping.callback then return end
	vim.keymap.del("i", mapping.key, { buffer = mapping.bufnr })
	if mapping.previous then
		vim.api.nvim_buf_call(mapping.bufnr, function()
			vim.fn.mapset("i", false, mapping.previous)
		end)
	end
end

local function install_mapping(bufnr, key, callback, description)
	local mapping = { bufnr = bufnr, key = key, callback = callback, previous = local_mapping(bufnr, key) }
	vim.keymap.set("i", key, callback, { buffer = bufnr, silent = true, desc = description })
	return mapping
end

local function replay(key)
	-- The temporary map has already been restored. Let Neovim execute the
	-- original mapping, including expression callbacks, exactly as usual.
	vim.api.nvim_feedkeys(keycode(key), "mi", false)
end

local function eligible(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then return false end
	local options = vim.bo[bufnr]
	return options.buftype == "" and options.modifiable and not options.readonly
		and not options.filetype:match("^opencode")
		and not vim.api.nvim_buf_get_name(bufnr):match("^opencode://")
end

local function stop_timer()
	if not timer then return end
	if not timer:is_closing() then
		timer:stop()
		timer:close()
	end
	timer = nil
end

function M.clear()
	stop_timer()
	local previous = preview
	preview = nil
	if not previous then return end
	restore_mapping(previous.accept_mapping)
	if vim.api.nvim_buf_is_valid(previous.snapshot.bufnr) then
		vim.api.nvim_buf_clear_namespace(previous.snapshot.bufnr, namespace, 0, -1)
	end
end

local function decorate(view, first, remaining, highlight)
	local snapshot = view.snapshot
	if not vim.api.nvim_buf_is_valid(snapshot.bufnr) then return false end
	local options = {
		id = view.mark,
		virt_text = { { first, highlight } },
		virt_text_pos = "inline",
		hl_mode = "combine",
		right_gravity = false,
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

function M.pending(snapshot)
	M.clear()
	local view = { snapshot = snapshot }
	preview = view
	if not decorate(view, spinner.get_frame(), nil, "OpenCodeCompletionSpinner") then
		M.clear()
		return false
	end
	timer = vim.uv.new_timer()
	if timer then
		local interval = spinner.get_interval_ms()
		timer:start(interval, interval, vim.schedule_wrap(function()
			if preview ~= view then return end
			if not decorate(view, spinner.get_frame(), nil, "OpenCodeCompletionSpinner") then M.clear() end
		end))
	end
	return true
end

function M.show(snapshot, text)
	M.clear()
	if type(text) ~= "string" or text == "" or not eligible(snapshot.bufnr) then return false end
	local lines = vim.split(text, "\n", { plain = true, trimempty = false })
	local source = vim.api.nvim_buf_get_lines(snapshot.bufnr, snapshot.row, snapshot.row + 1, false)[1]
	-- Inline virtual text cannot move the real suffix to the last virtual line.
	-- The controller requests a single-line completion whenever a suffix exists.
	if not source or (#lines > 1 and snapshot.col < #source) then return false end
	local first = table.remove(lines, 1)
	local view = { snapshot = snapshot }
	preview = view
	if not decorate(view, first, lines, "OpenCodeCompletion") then
		M.clear()
		return false
	end
	local key = config.keymaps and config.keymaps.accept
	if type(key) == "string" and key ~= "" then
		view.accept_mapping = install_mapping(snapshot.bufnr, key, function()
			local accepted = preview == view and actions.accept_completion()
			if preview == view then M.clear() end
			if not accepted then replay(key) end
		end, "Accept OpenCode completion")
	end
	return true
end

local function configure_buffer(bufnr)
	local installed = trigger_maps[bufnr]
	if not eligible(bufnr) then
		if preview and preview.snapshot.bufnr == bufnr then M.clear() end
		restore_mapping(installed)
		trigger_maps[bufnr] = nil
		return
	end
	-- Do not reinstall over a later mapping from the user or another plugin.
	if installed then return end
	local key = config.keymaps and config.keymaps.trigger
	if type(key) ~= "string" or key == "" then return end
	trigger_maps[bufnr] = install_mapping(bufnr, key, function()
		if eligible(bufnr) then
			actions.complete()
		else
			restore_mapping(trigger_maps[bufnr])
			trigger_maps[bufnr] = nil
			replay(key)
		end
	end, "Request OpenCode completion")
end

function M.teardown()
	M.clear()
	if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
	for _, mapping in pairs(trigger_maps) do restore_mapping(mapping) end
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
			if preview and preview.snapshot.bufnr == event.buf then M.clear() end
			trigger_maps[event.buf] = nil
		end,
	})
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do configure_buffer(bufnr) end
end

return M
