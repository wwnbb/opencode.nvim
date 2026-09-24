describe("integration forms", function()
	it("renders the shared form widget and submits typed false/number/hidden values", function()
		local result, count = nil, 0
		local dialog = require("opencode.ui.form").open({
			{ key = "hidden", type = "string", hidden = true, default = "kept" },
			{ key = "enabled", type = "boolean", required = true, title = "Enabled" },
			{ key = "count", type = "integer", required = true, default = 2, minimum = 1 },
		}, { title = "Integration setup" }, function(answer) result = answer; count = count + 1 end)
		local bufnr = vim.api.nvim_get_current_buf()
		local keys = {}
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do keys[map.lhs] = map.callback end
		keys["2"]()
		keys["<C-G>"]()
		assert.same({ hidden = "kept", enabled = false, count = 2 }, result)
		dialog.close()
		assert.equals(1, count)
	end)
end)

describe("integration form layout", function()
	it("wraps for the popup width and keeps keyboard focus on wrapped options", function()
		local chat_state = require("opencode.ui.chat.state").state
		local old_config = chat_state.config
		chat_state.config = vim.tbl_deep_extend("force", chat_state.config or {}, { width = 120 })
		local dialog = require("opencode.ui.form").open({
			{ key = "choice", type = "string", title = "Region", options = {
				{ label = string.rep("Long option ", 20), value = "one" }, { label = "SECOND_OPTION", value = "two" },
			} },
		}, { title = "Popup width" }, function() end)
		local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		local width = vim.api.nvim_win_get_width(win)
		for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do assert.is_true(vim.fn.strdisplaywidth(line) <= width) end
		vim.fn.maparg("j", "n", false, true).callback()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		assert.is_truthy(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]:find("SECOND_OPTION", 1, true))
		dialog.close(); chat_state.config = old_config
	end)
end)
