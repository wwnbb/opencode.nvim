local focus = require("opencode.ui.chat.float_focus")
local state = require("opencode.ui.chat.state").state

describe("chat float focus callback ownership", function()
	local saved, schedule, queued
	local fields = { "visible", "config", "winid", "tabpage", "float_dims" }

	before_each(function()
		saved = {}
		for _, field in ipairs(fields) do saved[field] = state[field] end
		state.visible, state.config, state.winid = true, { layout = "float" }, nil
		state.tabpage, state.float_dims = vim.api.nvim_get_current_tabpage(), nil
		schedule, queued = vim.schedule, {}
		vim.schedule = function(callback) queued[#queued + 1] = callback end
	end)

	after_each(function()
		focus.clear()
		vim.schedule = schedule
		for _, field in ipairs(fields) do state[field] = saved[field] end
	end)

	it("ignores focus checks from a cleared or replaced chat while current checks still close it", function()
		for _, replace in ipairs({ false, true }) do
			queued = {}
			local old_closed, new_closed = 0, 0
			focus.setup({ close = function() old_closed = old_closed + 1 end })
			vim.api.nvim_exec_autocmds("WinEnter", { group = state.focus_augroup })
			assert.equals(1, #queued)
			focus.clear()
			if replace then
				focus.setup({ close = function() new_closed = new_closed + 1 end })
			end
			queued[1]()
			assert.equals(0, old_closed)
			assert.equals(0, new_closed)
			if replace then
				vim.api.nvim_exec_autocmds("WinEnter", { group = state.focus_augroup })
				queued[2]()
				assert.equals(1, new_closed)
			end
			focus.clear()
		end
	end)
end)
