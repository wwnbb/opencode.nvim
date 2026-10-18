describe("tab navigation help labels", function()
	for _, case in ipairs({
		{ layout = "tab", target = "layout", title = "OpenCode Tabs" },
		{ layout = "vertical", target = "session", title = "Sessions" },
	}) do
		it("describes " .. case.layout .. " navigation with native counts", function()
			local popup = require("opencode.ui.chat.help").show({
				layout = case.layout,
				keymaps = { next_session = "]t", select_0 = "<F10>" },
			})
			local text = table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false), "\n")
			popup:close(false)
			assert.is_truthy(text:find(case.title, 1, true))
			assert.is_truthy(text:find("Close current " .. case.target, 1, true))
			assert.is_truthy(text:find("Go to first " .. case.target, 1, true))
			assert.is_truthy(text:find("1 + ]t", 1, true))
			assert.is_nil(text:find("<F10> + ]t", 1, true))
		end)
	end
end)
