-- opencode.nvim - Input autocmd wiring

local M = {}

local event = require("nui.utils.autocmd").event

function M.setup(state, callbacks)
	callbacks = callbacks or {}

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

	state.popup:on(event.BufLeave, function()
		vim.schedule(function()
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
