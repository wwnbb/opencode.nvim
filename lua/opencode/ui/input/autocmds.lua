-- opencode.nvim - Input autocmd wiring

local M = {}

local event = require("nui.utils.autocmd").event

function M.setup(state, callbacks)
	callbacks = callbacks or {}
	local resize_group = vim.api.nvim_create_augroup("OpenCodeInputResize", { clear = true })
	if callbacks.reflow then
		local scheduled = false
		vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
			group = resize_group,
			callback = function()
				if scheduled then return end
				scheduled = true
				vim.schedule(function() scheduled = false; callbacks.reflow() end)
			end,
		})
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = state.bufnr, once = true,
			callback = function() vim.api.nvim_clear_autocmds({ group = resize_group }) end,
		})
	end

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = state.bufnr,
		callback = function()
			if callbacks.schedule_resize then
				callbacks.schedule_resize()
			end
			if callbacks.input_changed then
				callbacks.input_changed()
			end
		end,
	})

	if callbacks.cursor_moved then
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
			buffer = state.bufnr,
			callback = callbacks.cursor_moved,
		})
	end

	if callbacks.complete_done then
		vim.api.nvim_create_autocmd("CompleteDone", {
			buffer = state.bufnr,
			callback = callbacks.complete_done,
		})
	end

	if callbacks.insert_leave then
		vim.api.nvim_create_autocmd("InsertLeave", {
			buffer = state.bufnr,
			callback = callbacks.insert_leave,
		})
	end

	vim.api.nvim_create_autocmd("WinScrolled", {
		buffer = state.bufnr,
		callback = callbacks.lock_scroll,
	})

	local bufnr = state.bufnr
	state.popup:on(event.BufLeave, function()
		vim.schedule(function()
			if not state.visible or state.bufnr ~= bufnr then
				return
			end
			local ok, native_diff = pcall(require, "opencode.ui.native_diff")
			if ok and native_diff.is_active and native_diff.is_active() then
				return
			end
			if callbacks.close then
				callbacks.close()
			end
		end)
	end)
end

return M
