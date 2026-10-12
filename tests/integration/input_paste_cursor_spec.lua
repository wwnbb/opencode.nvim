describe("input paste cursor", function()
	for _, layout in ipairs({ "float", "vertical" }) do
		it("keeps the Insert-mode caret at the bottom after a large paste in " .. layout, function()
			local client = require("tests.helpers.embedded_editor").new()
			local ok, err = xpcall(function()
				client.request("nvim_ui_attach", { 120, 40, { rgb = true, ext_linegrid = true } })
				client.lua([[
					require("opencode").setup({ server = { auto_start = false },
						chat = { layout = ..., close_on_focus_lost = false },
						input = { collapse_paste_lines = false }, lualine = { enabled = false } })
					require("opencode.ui.chat").open()
				]], { layout })
				for _, last in ipairs({ "Конец 世界", string.rep("слово ", 400) .. "尾" }) do
					client.lua([[
						require("opencode.ui.input").close(false)
						require("opencode.ui.input.history").clear_pending()
						require("opencode.ui.chat").focus_input()
					]])
					assert.is_true(vim.wait(1000, function()
						return client.lua("return vim.api.nvim_get_mode().mode") == "i"
					end, 5))
					local lines = {}
					for row = 1, 51 do lines[row] = "pasted " .. row end
					lines[52] = last
					assert.is_true(client.request("nvim_paste", { table.concat(lines, "\n"), false, -1 }))
					assert.is_true(vim.wait(1000, function()
						return client.lua("return vim.api.nvim_win_get_height(0)") == 20
					end, 5))
					assert.same({ { 52, #last }, 20, "i", lines }, client.lua([[
						vim.cmd("redraw!")
						return { vim.api.nvim_win_get_cursor(0), vim.fn.winline(),
							vim.api.nvim_get_mode().mode, vim.api.nvim_buf_get_lines(0, 0, -1, false) }
					]]))
					client.feed("!")
					lines[52] = last .. "!"
					assert.is_true(vim.wait(1000, function()
						return client.lua("return vim.api.nvim_get_current_line()") == lines[52]
					end, 5))
					assert.same(lines, client.lua("return vim.api.nvim_buf_get_lines(0, 0, -1, false)"))
					client.lua("vim.cmd('stopinsert')")
					assert.is_true(vim.wait(1000, function()
						return client.lua("return vim.api.nvim_get_mode().mode") == "n"
					end, 5))
				end
			end, debug.traceback)
			client.close()
			assert.is_true(ok, err)
		end)
	end
end)
