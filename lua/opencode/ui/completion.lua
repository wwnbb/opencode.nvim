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
	vim.api.nvim_set_hl(0, "OpenCodeCompletionDiffAdd", { link = "DiffAdd", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeCompletionDiffDelete", { link = "DiffDelete", default = true })
	vim.api.nvim_set_hl(0, "OpenCodeCompletionDiffChange", { link = "DiffChange", default = true })
end)

local function keycode(key)
	return vim.api.nvim_replace_termcodes(key, true, false, true)
end

local function install_mapping(bufnr, key, callback, description, mode)
	return keymaps.install(mode or "i", bufnr, key, callback, { silent = true, desc = description })
end

local function restore_mappings(mappings)
	for index = #(mappings or {}), 1, -1 do keymaps.restore(mappings[index]) end
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
	restore_mappings(view.mappings)
	if view.mark and vim.api.nvim_buf_is_valid(snapshot.bufnr) then
		pcall(vim.api.nvim_buf_del_extmark, snapshot.bufnr, namespace, view.mark)
	end
	local has_insertion
	for other in pairs(buffer.views) do
		if not other.selection then has_insertion = true; break end
	end
	if not has_insertion then
		restore_mappings(buffer.accept_mappings)
		buffer.accept_mappings = nil
		buffer.replaying = nil
	end
	if not next(buffer.views) then previews[snapshot.bufnr] = nil end
end

local function selection_keys()
	local accept = keymaps.keys(keymaps.get("completion", config.keymaps).accept)
	local cancel = {}
	for _, key in ipairs(keymaps.keys(keymaps.get("popup").cancel)) do
		if not keymaps.matches(accept, key) then cancel[#cancel + 1] = key end
	end
	return accept, cancel
end

local function install_selection_mappings(view)
	if view.mappings then return end
	local snapshot = view.snapshot
	local accept, cancel = selection_keys()
	view.mappings = {}
	for _, spec in ipairs({
		{ keys = accept, action = "accept_completion", desc = "Accept OpenCode edit" },
		{ keys = cancel, action = "dismiss_completion", desc = "Cancel OpenCode edit" },
	}) do
		for _, key in ipairs(keymaps.keys(spec.keys)) do
			view.mappings[#view.mappings + 1] = install_mapping(snapshot.bufnr, key, function()
				if not actions[spec.action]() then
					M.clear(snapshot)
					replay(key)
				end
			end, spec.desc, "n")
		end
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
					if not snapshot.selection and cursor[1] == snapshot.row + 1 and cursor[2] == snapshot.col then M.clear(snapshot) end
				end
				local after
				if previews[bufnr] == buffer and buffer.accept_mappings then
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

local function decorate_selection(view, text)
	local snapshot = view.snapshot
	local replacement = require("opencode.completion.selection").replacement(snapshot, text)
	local before = table.concat(snapshot.selection.source_lines, "\n") .. "\n"
	local after = #replacement > 0 and table.concat(replacement, "\n") .. "\n" or ""
	local diff = vim.diff(before, after, { result_type = "unified", ctxlen = 3 })
	local lines = {}
	for _, line in ipairs(vim.split(diff, "\n", { plain = true, trimempty = true })) do
		local highlight = "OpenCodeCompletion"
		if line:sub(1, 1) == "+" then highlight = "OpenCodeCompletionDiffAdd"
		elseif line:sub(1, 1) == "-" then highlight = "OpenCodeCompletionDiffDelete"
		elseif line:sub(1, 2) == "@@" then highlight = "OpenCodeCompletionDiffChange" end
		lines[#lines + 1] = { { line, highlight } }
	end
	local accept, cancel = selection_keys()
	lines[#lines + 1] = { { ("OpenCode edit  %s accept  %s cancel"):format(
		keymaps.label("completion", "accept", { accept = accept }), keymaps.label("popup", "cancel", { cancel = cancel })), "OpenCodeCompletionSpinner" } }
	local ok, mark = pcall(vim.api.nvim_buf_set_extmark, snapshot.bufnr, namespace, snapshot.selection.end_line - 1, 0, {
		id = view.mark, virt_lines = lines, priority = 200,
	})
	if ok then view.mark = mark end
	return ok
end

function M.pending(snapshot)
	local view, buffer = get_view(snapshot)
	stop_timer(view)
	if not decorate_pending(view) then
		M.clear(snapshot)
		return false
	end
	if snapshot.selection then install_selection_mappings(view) else install_accept_mappings(snapshot.bufnr, buffer) end
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
	if type(text) ~= "string" or (text == "" and not snapshot.selection) or not eligible(snapshot.bufnr) then M.clear(snapshot); return false end
	if snapshot.selection then
		local view = get_view(snapshot)
		stop_timer(view)
		if not decorate_selection(view, text) then M.clear(snapshot); return false end
		install_selection_mappings(view)
		return true
	end
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
	local bindings = keymaps.get("completion", config.keymaps)
	for _, spec in ipairs({
		{ key = "trigger", action = "complete", desc = "Request OpenCode completion" },
		{ key = "prompt", action = "complete_with_prompt", desc = "Prompt for OpenCode completion" },
		{ key = "prompt", action = "complete_with_prompt", desc = "Prompt for OpenCode edit", mode = "x" },
	}) do
		for _, key in ipairs(keymaps.keys(bindings[spec.key])) do
			trigger_maps[bufnr][#trigger_maps[bufnr] + 1] = install_mapping(bufnr, key, function()
				if eligible(bufnr) then
					actions[spec.action]()
				else
					restore_mappings(trigger_maps[bufnr])
					trigger_maps[bufnr] = nil
					replay(key)
				end
			end, spec.desc, spec.mode)
		end
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
