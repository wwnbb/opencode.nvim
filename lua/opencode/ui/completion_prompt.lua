-- Completion instructions use the composer surfaces without its session or draft state.
local M = {}

local popups = require("opencode.ui.input.popups")
local layout = require("opencode.ui.input.layout")
local keymaps = require("opencode.util.keymap")
local NuiLine = require("nui.line")
local namespace = vim.api.nvim_create_namespace("OpenCodeCompletionPrompt")

function M.open(opts)
	local config = (require("opencode.state").get_config() or {}).input or {}
	local state = { visible = true, config = {} }
	local cursor = vim.api.nvim_win_get_cursor(opts.winid)
	local anchor = vim.fn.screenpos(opts.winid, cursor[1], cursor[2] + 1)
	local function placement()
		local position = vim.fn.screenpos(opts.winid, cursor[1], cursor[2] + 1)
		if position.row > 0 then anchor = position end
		local screen_height = vim.o.lines - vim.o.cmdheight
		local width = math.max(1, math.min(72, vim.o.columns - 2, vim.api.nvim_win_get_width(opts.winid) - 2))
		local max_height = math.min(config.max_height or 20, math.max(1, screen_height - 4))
		state.config.min_height = math.min(config.min_height or 1, max_height)
		state.config.max_height = max_height
		local height = state.bufnr and layout.measure_height(state, width) or state.config.min_height
		local above = math.max(0, anchor.row - 1)
		local below = math.max(0, screen_height - anchor.row)
		local place_below = below >= height + 4 or below >= above
		state.config.max_height = math.min(max_height, math.max(1, (place_below and below or above) - 4))
		height = math.min(height, state.config.max_height)
		-- The shared composer surfaces add four rows of padding and footer.
		local top = place_below and anchor.row or anchor.row - height - 5
		top = math.max(0, math.min(top, screen_height - height - 4))
		local col = math.max(1, math.min(anchor.col, vim.o.columns - width - 1))
		return {
			popup = { relative = "editor", position = { row = top + 1, col = col },
				size = { width = width, height = height }, zindex = 80 },
			info = { relative = "editor", position = { row = top + height + 2, col = col },
				size = { width = width, height = 1 }, zindex = 80 },
		}
	end
	require("opencode.ui.input.info_bar").setup_highlights()
	local frame = placement()
	state.layout = { current_height = frame.popup.size.height }
	state.popup, state.info_popup = popups.mount(frame)
	state.bufnr, state.winid = state.popup.bufnr, state.popup.winid
	vim.b[state.bufnr].completion = false
	local group = vim.api.nvim_create_augroup("OpenCodeCompletionPrompt_" .. state.bufnr, { clear = true })

	local function close(callback)
		if not state.visible then return end
		state.visible = false
		vim.api.nvim_del_augroup_by_id(group)
		local function finish()
			if vim.api.nvim_get_current_win() == state.winid and vim.api.nvim_win_is_valid(opts.winid) then
				vim.api.nvim_set_current_win(opts.winid)
			end
			popups.unmount(state)
			if callback then callback() end
		end
		if vim.api.nvim_get_current_win() == state.winid and vim.api.nvim_get_mode().mode:sub(1, 1) == "i" then
			-- Finish Insert mode in the prompt before native autoindent cleanup can touch the source.
			vim.api.nvim_create_autocmd("InsertLeave", {
				buffer = state.bufnr, once = true, callback = function() vim.schedule(finish) end,
			})
			vim.cmd("stopinsert")
		else
			finish()
		end
	end
	local function cancel()
		if not state.visible then return end
		close(opts.on_cancel)
	end
	local function submit()
		if not state.visible then return end
		local value = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
		close(function() opts.on_submit(value) end)
	end
	local map, apply = keymaps.mapper("input", state.bufnr)
	for _, action in ipairs({ "send", "send_alt" }) do
		map({ "i", "n" }, action, submit)
	end
	map({ "i", "n" }, "send_steer", submit, { filter = function(key)
		return not keymaps.matches(keymaps.get("input").send_alt, key)
	end })
	map({ "i", "n" }, "cancel", cancel, { scope = "popup" })
	apply()

	local function footer()
		if not state.visible then return end
		local width = vim.api.nvim_win_get_width(state.info_popup.winid)
		local truncate = require("opencode.util.text").truncate
		local line = NuiLine()
		local title = truncate(vim.trim(opts.title) .. " ", width, "…")
		line:append(title, "OpenCodeInputInfo")
		local room = width - vim.fn.strdisplaywidth(title)
		local model = opts.model or {}
		local name = model.modelID or model.id or ""
		line:append(truncate(name, room, "…"), "OpenCodeInputModel")
		vim.api.nvim_buf_clear_namespace(state.info_popup.bufnr, namespace, 0, -1)
		line:render(state.info_popup.bufnr, namespace, 1)
	end
	footer()
	local reflow_scheduled = false
	local function reflow()
		if reflow_scheduled then return end
		reflow_scheduled = true
		vim.schedule(function()
			reflow_scheduled = false
			if not state.visible or not vim.api.nvim_win_is_valid(opts.winid) then return end
			local previous_height = state.layout.current_height
			local next_frame = placement()
			state.layout.current_height = next_frame.popup.size.height
			if not vim.deep_equal(frame, next_frame) then
				state.popup:update_layout(next_frame.popup)
				state.info_popup:update_layout(next_frame.info)
				frame = next_frame
			end
			layout.restore_view(state, previous_height)
			footer()
		end)
	end
	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		group = group, buffer = state.bufnr, callback = reflow,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
		group = group, callback = reflow,
	})
	vim.api.nvim_create_autocmd("WinScrolled", {
		group = group, buffer = state.bufnr, callback = function() layout.lock_scroll(state) end,
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "BufWipeout" }, {
		group = group, buffer = state.bufnr, callback = function() vim.schedule(cancel) end,
	})
	vim.api.nvim_create_autocmd("WinClosed", {
		group = group, pattern = { tostring(state.winid), tostring(opts.winid) },
		callback = function() vim.schedule(cancel) end,
	})
	vim.cmd("startinsert!")
	return { close = close, input = state.popup }
end

return M
